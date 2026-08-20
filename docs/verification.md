# Verification

This document records the tests done for the modules and files written, ensuring that implementation matches [design.md](design.md). 

## Command_Parser

```
make sim TB=tb_Command_Parser              # prints PASS or FAIL
make wave TB=tb_Command_Parser WAVE=gtkwave
gtkwave build/dump.vcd sim/tb_Command_Parser.gtkw   # with the saved signal set
```

### The harness

[sim/tb_Command_Parser.v](../sim/tb_Command_Parser.v) instantiates `UART_TX`
feeding `UART_RX` feeding the parser, so every test drives the real receive path
rather than a model of it. The grid is shrunk to 4×3 (12 cells) so that a wrap
happens after four characters and a clear walk is twelve cycles, which can be easily counted.

Checks run against a **scoreboard**: a testbench-side array mirroring every write
the parser issues, so tests assert on the resulting screen contents rather than
on cycle-by-cycle behavior. Changing the parser's internal timing does not break
the tests; changing its behavior does.

Two counters back that up. `r_Writes` catches a write-enable that plateaus
instead of pulsing; a character that writes once is asserted as *exactly* one
write. `r_Busy_Cycles` asserts the clear walk is exactly `c_COLS * c_ROWS` cycles
long.

### Coverage

| # | Test | What it proves |
| --- | --- | --- |
| 1 | One character | Lands at cell 0; exactly one write pulse |
| 2 | Short string | Consecutive cells, cursor advances |
| 3 | Fifth character | Column wrap onto the next row |
| 4 | `FF` | All cells blank, `o_Busy` high exactly 12 cycles, cursor *and* column counter reset |
| 5 | `LF` | Row advances, column preserved |
| 5b | `LF` on the last row | Wraps to row 0, keeps the column |
| 6 | `CR` | Column 0, same row, earlier cells untouched |
| 7 | `CR LF` | The sequence a real host sends |
| 8 | `ESC 2 1` | Cursor positioning; the sequence itself writes nothing |
| 9 | `ESC 200 200` | Clamps to the last cell; writing there wraps to the origin |
| 10 | `0x00`, `0x7F`, `0x80` | Ignored; the cursor does not move |
| 11 | `ESC "A" "B"` | Printables after `ESC` are coordinates, not characters |
| 12 | Byte during `CLEAR` | Dropped; the parser still works afterwards |

Tests 9, 10, 11 and 12 all test malformed inputs, cases a host bug or a dropped
byte would produce.

### Testing a case the hardware cannot reach

Test 12 needs a byte to arrive *inside* the clear walk. The serial path cannot
stage that: a byte occupies 2170 clocks and the walk is 12, which is exactly the
timing margin argued in [design.md](design.md#a-byte-arriving-during-clear-drop-it).
The condition the FSM defines is, by construction, one the wire cannot deliver.

As such, the parser's `i_RX_DV` is muxed in the testbench, and `INJECT_BYTE` presents a
byte with a one-clock pulse exactly as `UART_RX` would. The tradeoff is explicit:
injected bytes exercise the parser's contract, not the receive path. That is
acceptable only because the other 12 tests all run through the real
`UART_TX` → `UART_RX` chain.

### Waveforms

![ESC positioning](waves/esc-positioning.png)

`ESC 02 01` on the 4×3 test grid. The FSM steps `IDLE → ESC_COL → ESC_ROW →
IDLE`, `r_ESC_Col` latches the column byte between the two, and `o_Wr_En` stays
low for all three bytes of the sequence. The next printable byte, `58` (`"X"`),
writes at address 6 = row 1 × 4 + column 2.

![Malformed escape sequence](waves/malformed-esc.png)

`ESC "A" "B"`, the two printable bytes are consumed as coordinates, not
displayed: `o_Wr_En` never rises while they arrive. 65 and 66 clamp to the last
column and row, so the cursor lands at (3, 2) and `r_Addr` at 11. `"C"` then
writes there, wrapping the cursor back to (0, 0).

Noting that:
- `r_ESC_Col` shows `C8` on entry, using a value from the previous test still in the register until the new sequence overwrites it.
- `w_Wr_Addr` does not transition at the `"C"` write, because the clear walk's last cell was also address 11.

In both cases, `r_Addr` going
`B → 0` and `w_Wr_Data → 43` under the `o_Wr_En` pulse are what show the write
landing, not the address trace.

In both shots `w_RX_Byte` churns through intermediate values between bytes, showing `UART_RX` shifting bits into `r_RX_Byte` in place; only its value at the
`o_RX_DV` pulse is meaningful. `r_TX_Byte`, on the top row, shows the byte
actually being sent.

### Trusting the tests

A testbench that passes the first time it runs has not yet demonstrated it can
fail. Each of these bugs was introduced into a scratch copy of the parser, and
each was caught:

| Mutation | |
| --- | --- |
| ESC coordinates not clamped | caught |
| `o_Wr_En` default assignment removed, so writes plateau | caught |
| Clear walk stops one cell short | caught |
| Clear resets the address but not the column counter | caught |
| `CR` resets the column but not the address | caught |
| `LF` does not wrap from the last row | caught |
| `ESC_ROW` rebuilds the address from the pre-update cursor | caught |
| No wrap past the last cell of the screen | caught |
| `CLEAR` acts on a byte instead of ignoring it | caught |

**This found a real hole.** On the first pass the `LF`-no-row-wrap mutation
*passed*, because no test ever sent `LF` from the bottom row, and as such test 5b 
was appended to the testing suite.

It also showed why the redundant-state warning in
[design.md](design.md#address-arithmetic) matters. Deleting the column reset from
`CLEAR` did not fail at the obvious check: the address still reset correctly, so
the next character still landed at cell 0. The stale column only surfaced three
tests later as a wrap firing one cell early. Test 4 now forces a wrap immediately
after the clear, so that inconsistency fails at its cause rather than somewhere
unrelated.

### Not covered

- The parser has no reset input; registers rely on initialization at
  configuration, which is normal for iCE40 but means power-on behavior is
  untested by simulation.
- Only the 4×3 grid is simulated. The 40×30 parameterization is exercised by
  synthesis, not by any test.
- No test drives two bytes closer together than the UART allows, other than the
  injected pair in test 12.

## Font_ROM

```
make sim TB=tb_Font_ROM                    # prints four glyphs, then PASS or FAIL
```

### The harness

[sim/tb_Font_ROM.v](../sim/tb_Font_ROM.v) reads glyph rows out of the ROM and
prints each as eight characters, `#` for a set pixel and `.` for a clear one; in this case, the simulation log is the artifact, as a malformed character can be easily discerned.

The one-clock read latency is confined to a single `READ` task: it sets the
address, waits for the edge, steps past it so the nonblocking update has landed,
and copies the byte out. Everything above that task works on a value already in
hand, so no other line in the file has to know the ROM has latency at all; this cycle also used for `Char_Generator`.
### Bit order

`font8x8` stores each row with **bit 0 as the leftmost pixel**, the reverse of
the obvious guess. Indexing `[7-col]` rather than `[col]` renders every glyph
mirrored. The printing loop counts `col` up from zero, which states the
convention in the same direction the hardware will read it.

### Coverage

| # | Glyph | What it proves |
| --- | --- | --- |
| 1 | `F` | Asymmetric, so a reversed bit order draws a mirror image and fails by eye |
| 2 | `L` | A second asymmetric glyph, in case `F` alone happened to be right |
| 3 | `p` | One of only eight printable glyphs with a non-blank row 7 |
| 4 | space (`0x20`) | Renders entirely blank, so a cleared screen really is empty |
| 5 | `F` row 0 `=== 8'h7F` | An assertion, so a run cannot pass without checking anything |

While most of the tests are 'eyeball tests', Test 5 checks to make sure a run cannot pass without checking values.

### The expected output is in the source

`tools/gen_font_rom.py` emits the same ASCII art as a comment beside every byte
it writes, so the eight lines printed for a glyph compare directly against the
eight `r_Mem[...]` lines in [rtl/Font_ROM.v](../rtl/Font_ROM.v). Those comments
are anchored to specific addresses, so a one-row shift breaks the correspondence
immediately rather than looking plausible.

### Synthesis

Synthesized standalone, the ROM maps to two `SB_RAM40_4K`, eight `SB_LUT4` and
one `SB_DFF`. The two block RAMs are the 8 Kbit of glyph data: an EBR holds
4 Kbit, so in 512×8 mode a 1024×8 ROM spans two of them. The eight LUTs are a
2:1 mux per output bit choosing which half the address landed in, and the
flip-flop delays the selecting address bit so it arrives alongside the
registered read data.

This depends entirely on the read being synchronous. An asynchronous read cannot
map to an EBR, and yosys would build 8192 bits of ROM out of a part with 1280
LUTs. The check is the reason the generator emits an initialized array rather
than a `case` statement. Full utilization for the assembled design is recorded
in [design.md](design.md) once `Char_RAM` exists.

### Not covered

- Four of 128 glyphs are inspected and one byte is asserted. The other 124 are
  covered only by the generator's checks on the source file (glyph count, bytes
  per glyph, entries emitted), not by any test.
- Nothing compares the ROM against the original header byte for byte. The
  generator is trusted to have transcribed it, and the four glyphs are the
  sample that would catch a systematic transcription error.

## Char_Generator

```
make sim TB=tb_Char_Generator              # prints PASS or FAIL
make sim TB=tb_Render_Frame                # renders one full frame to build/frame.pgm
```

### The property that needs a testbench

Char_Generator is a three-stage pipeline (the character RAM read register, the
font ROM read register, and the output register) so HSync and VSync have to be
delayed by three clocks to stay with the video they describe; every module in
the video chain honours this rule. Because an error to this delay is invisible on a monitor, the testbench below was created to catch any errors in simulation instead. 

### The harness

[sim/tb_Char_Generator.v](../sim/tb_Char_Generator.v) shrinks the frame to
64×40 total and 48×32 active, giving a 3×2 character grid and a 2560-clock
frame instead of 420,000; cells stay 16 pixels, so the generator's bit slices
are untouched.

`VGA_Sync_Porch` is deliberately not instantiated. Its porch constants are
hardcoded at 18/50/10/33, larger than the whole shrunken frame, and it is not
what is under test.

Char_RAM is stood in for by a plain array with the same one-clock read latency,
sized to the full address space because addresses computed during blanking run
past the six live cells.

The testbench captures the frame into an array and compares **every pixel**
against a value computed from first principles: which cell, which glyph row,
which glyph column, look up the bitmap. One comparison therefore covers glyph
shape, cell position, blank cells and cell boundaries at once.

The expected bitmaps are hardcoded rather than read from `Font_ROM`. A test that
fetches its expectations from the thing under test proves the two agree, not
that either is right.

### Positioning the capture

The capture counter is anchored **only** at the frame boundary, the rising edge
of the DUT's VSync, and free-runs from there. HSync positions nothing; it is
asserted against the counter instead:

```verilog
if (w_HSync_CG !== (r_Cap_Col < c_ACTIVE_COLS)) → FAIL
```

The first version of this testbench did the opposite, advancing the column counter on HSync with the reasoning that poistion should come from the module's own syncs exactly as the porch derives it downstream. However, a skewed HSync drags the capture along with it, so the bug moves its own detector. See the mutation table below.

### Coverage

| # | Test | What it proves |
| --- | --- | --- |
| 1 | Empty screen | Every cell blank; nothing painted from stale pipeline state |
| 2 | One glyph in cell 0 | Glyph shape, position, and the cell/glyph bit slices |
| 3 | Glyph in the last cell | The end of the address arithmetic |
| 4 | Two different glyphs, adjacent | No character latched across a cell boundary |
| 5 | Every cell filled, edges lit | Glyphs against all three blanking boundaries |
| 6 | The next frame | Identical, so the generator holds no frame state |
| — | Continuous | Nothing painted outside the live area |
| — | Continuous | Syncs agree with the free-running position counter |
| — | Continuous | Each channel fully on or fully off, all three agreeing |

### Choosing glyphs that can fail

`F` and `L` are used because they are left–right asymmetric. `A`, `H`, `I`, `M`,
`O`, `T` and `X` render identically under a reversed bit order and would pass a
mirrored implementation. Test 5 adds `*` and `_`, as there are the only two printable glyphs to use a cell's outermost pixels.

### Trusting the tests

| Mutation | |
| --- | --- |
| HSync delayed 2 stages instead of 3 | caught |
| Both syncs delayed 2 stages instead of 3 | caught |
| Blanking flag delayed once instead of twice | caught |
| Blanking removed entirely | caught |
| Glyph column delayed once instead of twice | caught |
| Glyph bit order reversed | caught |
| Cell address off by one | caught |
| 2× scaler dropped | caught |
| Cell slice `/32` instead of `/16` | caught |
| Video not replicated across the channel width | caught |

**Two of these passed on the first attempt**, and both were failures of the
testbench, rather than gaps in the module.

`HSync delayed 2 instead of 3` passed because the capture was positioned by
HSync, so the window moved with the bug. Re-anchoring the counter to the frame
boundary and asserting HSync separately fixed it.

`Blanking delayed once instead of twice` passed because no glyph on screen lit a
pixel adjacent to a blanking edge, for the font reason above. Test 5's `*` and
`_` fixed this issue.

`Video not replicated across the channel width` passed until a continuous check
was added that every channel is fully on or fully off. Only bit 0 of red is
captured into the frame, and `3'b001` has that bit set, and as such the symptom would have been a dim grey image, which would have been easy to blame on the cable.

### Rendered figures

[sim/tb_Render_Frame.v](../sim/tb_Render_Frame.v) asserts nothing. It runs the
same capture at the real 640×480 geometry and writes `build/frame.pgm`, so the
figures in this repo are generated by the design rather than photographed:

```
make sim TB=tb_Render_Frame
ffmpeg -y -i build/frame.pgm docs/images/render.png
```

A rendered frame is evidence about the RTL. A photograph of the board is
evidence that the hardware works. They are captioned accordingly.

### Not covered

- Only the 3×2 grid is simulated. The 40×30 parameterization is exercised by
  `tb_Render_Frame` and by synthesis, neither of which asserts anything.
- The frame is captured from `o_Red_Video[0]`. The other channels are checked
  only for agreeing with red and for being fully on or off.
- `VGA_Sync_Porch` is not in the loop, so the porch alignment downstream of this
  module is covered by the hardware bring-up rather than by simulation.

## Bring-up designs

`UART_Loopback_Top` and `VGA_Test_Patterns_Top` were confirmed on real hardware
(Go Board, iCE40-HX1K): characters echo back over the serial port with their hex
on the seven-segment displays, and the pattern designs sync on a monitor with the
pattern selected by the low nibble of a received byte. Their testbenches,
[tb_UART_Loopback.v](../sim/tb_UART_Loopback.v) and
[tb_VGA_Test_Patterns.v](../sim/tb_VGA_Test_Patterns.v), came with the book
projects and are not self-checking.
