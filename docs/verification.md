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

There is, however, deliberately no waveform capture of the character-fetch pipeline here, as a VCD would show the three registers in the right order and prove nothing about whether the right pixel came out the end. As such, the evidence is the glyph dumps of `tb_Font_ROM` and the whole-frame pixel comparison below instead.

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

## Serial_Display_Top

```
make sim TB=tb_Serial_Display_Top          # prints PASS or FAIL
```

### The failures only integration can produce

Every module below has its own testbench and every one passes. This testbench
exists for what those cannot see:

**`Command_Parser` and `Char_Generator` both compute `row * c_COLS + col`.**
In this way, if they disagreed by one, every unit test in the project would still pass, because neither module would be wrong technically; test 4 catches this.

The same goes for the three parameters that have to agree across parser, memory
and generator. A mismatched `c_ADDR_BITS` truncates addresses silently; a
mismatched `c_COLS` puts text in the wrong cell with no error anywhere.

### The harness

[sim/tb_Serial_Display_Top.v](../sim/tb_Serial_Display_Top.v) instantiates the
real `Serial_Display_Top` and drives its serial input from a real `UART_TX`, so
bytes travel the path they travel on hardware.

Three things are shrunk so a run takes seconds rather than minutes:

| Parameter | Hardware | Simulation |
| --- | --- | --- |
| grid | 40 × 30 | 3 × 2 |
| frame | 800 × 525 | 64 × 40 |
| `c_CLKS_PER_BIT` | 217 | 16 |

`c_CLKS_PER_BIT` shrinking allows for the testbench speedup, as at 217, a single character occupies 2170 clocks, more than a whole shrunken frame; at 16, a character only takes 160 clocks, which is much more reasonable.

However, this cannot test the clear-walk timing margin, as the margin is an argument from two datasheet numbers and nothing in this repo can reasonably measure it.

Assertions are taken at `Char_Generator`'s outputs, reached hierarchically,
reusing the frame capture from [tb_Char_Generator](#char_generator).
`VGA_Sync_Porch` is skipped: its porch constants are larger than this whole
frame, and it is unchanged and hardware-proven.

Expected contents are held in a testbench-side model of the screen that the
tests update as they send, so every check is against what the protocol says
should be there rather than against a handful of spot values.

### Coverage

| # | Test | What it proves |
| --- | --- | --- |
| 1 | An untouched screen | Blank at power-up, with no clear command |
| 2 | `"FL"` | Two glyphs in cells 0 and 1 — the whole system in one test |
| 3 | `FF` | Every cell blank |
| 4 | `ESC 2 1` then `"F"` | Parser and generator agree on the cell address |
| 5 | `0x00`, `0x7F` | Ignored; the frame is unchanged |
| 6 | `CR` then a character | Column 0, same row, overwriting what was there |

### Trusting the tests

| Mutation | |
| --- | --- |
| Parser: `ESC` address off by one row | caught |
| Generator: read address off by one row | caught |
| Generator uses a different `c_COLS` than the parser | caught |
| Top level passes the parser the wrong grid width | caught |
| Parser drops the printable-range check | caught |
| Parser: `FF` no longer clears | caught |

The first four are all forms of the same failure (some form of two modules disagreeing about where a cell lives), which shows the importance of this testbench.

### What writing it changed

`Char_RAM` gained an `initial` block zeroing its contents. In simulation the
array previously started as `X`, while on hardware the bitstream loads zeros, so
test 1 could not check the power-up behaviour that
[design.md](design.md#power-up-no-clear-and-none-needed) depends on. Declaring
it in RTL makes the model match the device and makes the power-up state a
property of the design rather than of the toolchain's default. The bitstream is
unchanged, as the cells were already all-zero `.ram_data` blocks.

Test 6 was also wrong on first writing: it expected `CR` to return the cursor to
row 1, forgetting that writing the last cell in test 4 wraps to (0, 0) —
[the wrap decision](design.md#end-of-screen-wrap), working exactly as documented.
The test was wrong, not the design.

### Not covered

- Only the 3×2 grid and the shrunken frame are simulated.
- `VGA_Sync_Porch` is outside the loop, so the final sync alignment is covered
  by hardware bring-up rather than by simulation.
- No test sends bytes closer together than the shrunken UART allows, so
  back-to-back arrival at the real baud rate is untested.

## Bring-up designs

`UART_Loopback_Top` and `VGA_Test_Patterns_Top` were confirmed on real hardware
(Go Board, iCE40-HX1K): characters echo back over the serial port with their hex
on the seven-segment displays, and the pattern designs sync on a monitor with the
pattern selected by the low nibble of a received byte. Their testbenches,
[tb_UART_Loopback.v](../sim/tb_UART_Loopback.v) and
[tb_VGA_Test_Patterns.v](../sim/tb_VGA_Test_Patterns.v), came with the book
projects and are not self-checking.

`Static_Display_Top` joins them: `Char_Generator` reading the real `Char_RAM`,
filled once at power-up by `Test_Writer`, with no UART or protocol in the loop.
It exists so that a pixel bug and a protocol bug cannot be confused, and it
comes out once `Serial_Display_Top` runs.

### Block RAM writes are lost in a window after configuration

`Test_Writer` originally began walking the memory on the first clock edge after
configuration. On hardware the first ~50 cells never took their data: the screen
came up with row 0 blank and row 1 starting about ten cells in, everything after
that correct. Simulation never showed it, because simulation has no
configuration phase. Holding the walk off for 4096 clocks fixes it completely.

The likely mechanism comes from Lattice's own documentation. EBR contents are
*"preserved (write protected) during configuration"*, and configuration is not
finished at the moment the design starts running: the Programming and
Configuration technical note states that after CDONE goes high, *"at least 49
additional dummy bits (49 additional SPI_SCK clock cycles) should be sent before
the SPI interface pins become available to the user-application."* A design on a
free-running oscillator therefore begins executing while the memory is still
write-protected, and writes issued in that window are dropped silently.

The ~50 cells lost and the 49 documented clocks agree closely, but they are
counted on different clocks — SPI configuration clock versus the 25 MHz user
clock — so the correspondence is suggestive rather than proven. An analogous
read-side anomaly is recorded in
[icestorm issue #76](https://github.com/YosysHQ/icestorm/issues/76): block RAM
reads within ~36 cycles of reset return zero, but only on the first reset after
reconfiguration.

**The real design is not exposed to this.** `Command_Parser` cannot write until
a UART byte arrives, and a byte occupies 2170 clocks, so the earliest possible
write is far outside the window. `Test_Writer` is unusual precisely because it
starts on clock one, and the startup hold stays in it for that reason.

### The false trail, and what made it survive

The same symptom was first attributed to the monitor clipping the top character
row, and that explanation lasted several rounds of debugging before it broke.
Recording why is more useful than quietly deleting it.

The measurement that seemed to support it was real and still stands: capturing
the whole 800×525 frame at the `VGA_Sync_Porch` outputs and positioning it from
the VSync pulse, active video begins at line **35** — the 2-line sync pulse plus
the 33-line back porch that 640×480@60 specifies — with row 0's glyphs present.
The render path was never at fault. But "the signal is correct" was then treated
as evidence for "therefore the display is clipping", which does not follow.

Two things finally distinguished them. First, the shape of what was missing:
losing all of row 0 *and the first ten cells of row 1* is a raster-linear loss,
whereas a display clips a rectangle and would have taken the same columns off
every row. Second, filling every cell on screen with a single character, so the
missing region had a visible outline — a notch at the top-left rather than a
straight edge. That test took one flash and should have come first.

**Test patterns 4, 5 and 6 do not blank outside the active area.** They were
used as a calibration target, on the assumption that a full-screen image would
let the monitor's auto-adjust find the real frame boundaries. It cannot, because
those three patterns have no active-area gate:

```verilog
// Test_Pattern_Gen.v, pattern 6
assign Pattern_Red[6] = (w_Row_Count <= 1 || w_Row_Count >= ACTIVE_ROWS-1-1 ||
                         w_Col_Count <= 1 || w_Col_Count >= ACTIVE_COLS-1-1) ? ...
```

`w_Row_Count >= 478` holds for rows 478 through 524 — the last two active rows
*and all 45 blanking rows* — so the pattern floods the vertical blanking with
white, and columns 638–799 do the same horizontally. What looks like a border
around the image is partly video sitting in the porches, and a monitor adjusting
to it is adjusting to the wrong rectangle.

Patterns 1, 2 and 3 gate correctly on
`(w_Col_Count < ACTIVE_COLS && w_Row_Count < ACTIVE_ROWS)` and are the only ones
usable for calibration. These modules came from the book projects and are used
unmodified; the defect is noted rather than fixed, because they are scaffolding
and `Char_Generator` blanks correctly on its own account —
[tb_Char_Generator](#char_generator) asserts it continuously.

## Malformed input on hardware

Every case below is already covered by [tb_Command_Parser](#command_parser); running them on the board tests the claim that the hardware system can survive malformed inputs, rather than relying on simulation.

Run on the Go Board at 115200, against `Serial_Display_Top`.

| # | Provoked | Documented behaviour | Result |
| --- | --- | --- | --- |
| 1 | `printf '\x00\x01\x7f\x80\xff'` | Ignored; cursor does not move | Matched |
| 2 | Lone `ESC`, then `AB` a minute later | `A` consumed as column, `B` as row; at most two bytes misread | Matched |
| 3 | `printf '\x1b\xc8\xc8X'` | Clamps to (39, 29) | Matched |
| 4 | `printf '\x1b\x1b\x00Y'` | The second `ESC` is column 27, not a restart | Matched |
| 5 | More than 1200 characters | Wraps to (0, 0) and keeps painting | Matched |
| 6 | Reconnect at 9600, mash keys | *Junk characters* | **Contradicted**: see below |
| 7 | Reconnect at 57600, mash keys | Junk characters, no lock-up | Matched; printable bytes landed on screen, the rest were discarded |
| 8 | [`send.py --file test-page.txt`](../tools/send.py) | Every line of [tools/test-page.txt](../tools/test-page.txt) renders; nothing drops | Matched; the column-38 rule was unbroken across all 30 rows |

No case required a power cycle, and no case left the display frozen or the sync
dropped.

### A baud mismatch is not a framing error

Test 6 was documented as producing junk characters; however, hardware produced a blank screen instead.

A baud mismatch does not cause a framing error here: `RX_STOP_BIT` in
[UART_RX.v](../common/UART_RX.v) waits out one bit period and asserts `o_RX_DV`
without checking that the stop bit is high; as such, nothing is rejected, and as such we must see what byte arrives. At 9600 baud, a bit lasts 2604 clocks; the receiver, configured for 115200 baud, samples its eight data bits at offsets 325 through 1844, all still inside the 9600 start bit. In this way, the board reads `0x00`, returns to idle, finds the line still low, and takes that as another start bit. Each bogus frame spans only ~0.7 of a real 9600 bit, so its eight samples cross at most one edge of the actual signal; every byte comes out as zeros followed by ones, which end up forming `0x00`, `0xC0`, `0xF0`, `0xFC`, and `0xFE`. Given all input outside `0x20`-`0x7E` are discarded by the parser's `default` branch, the hardware rightfully shows a blank screen.

To see 'junk' data, the baud needs to be a *near* miss, which is case 7: at 57600 the sampling window straddles data-bit boundaries rather than sitting inside one, so the bytes vary and some land printable.

### Not covered

- The bytes the receiver produces under a baud mismatch were not captured on
  hardware; only their effect on the display was observed.
- Case 7 was not run long enough to establish whether a corrupted `0x0C` ever
  arrives and clears the screen. It is reachable in principle and would be
  correct behaviour if it happened.
- Both baud cases were driven by hand from a terminal, so the input is
  whatever was typed rather than a fixed vector; neither is reproducible as a
  regression test.
