# Design

## Command parser state table

The FSM in [rtl/Command_Parser.v](../rtl/Command_Parser.v) has four states and
six classes of input byte. Every cell below says two things: the next state, and
what happens to the cursor and to the write port.

### Input classes

| Class | Bytes | Meaning |
| --- | --- | --- |
| Printable | `0x20`–`0x7E` | character to display |
| Line Feed (LF) | `0x0A` (`\n`) | next row |
| Carriage Return (CR) | `0x0D` (`\r`) | start of row |
| Form Feed (FF) | `0x0C` | clear |
| Escape (ESC) | `0x1B` | position |
| Other | everything else | no meaning |

`∅` means unchanged — no write, no cursor movement.

### IDLE

The only state whose behavior depends on which byte arrived.

| | Printable | LF | CR | FF | ESC | Other |
| --- | --- | --- | --- | --- | --- | --- |
| **Next state** | `IDLE` | `IDLE` | `IDLE` | `CLEAR` | `ESC_COL` | `IDLE` |
| **Cursor** | advance 1, wrap to (0,0) | row + 1, col ∅; `addr += c_COL` | row ∅, col 0; `addr -= r_COL` | reset clear counter, `o_Busy = 1` | ∅ | ∅ |
| **Write** | `o_Wr_En = 1`, `addr = cursor`, `data = i_RX_Byte` | N/A | N/A | N/A this cycle | N/A | N/A |

### ESC_COL, ESC_ROW, CLEAR

In these three states the input class doesn't matter; every byte is a
coordinate, or ignored outright.

| State | Next state | Cursor | Write |
| --- | --- | --- | --- |
| `ESC_COL` | `ESC_ROW` | ∅ | N/A; `r_ESC_COL <= i_RX_Byte` |
| `ESC_ROW` | `IDLE` | `r_COL <= r_ESC_COL` (clamped to `c_COL-1`), `r_ROW <= i_RX_Byte` (clamped to `c_ROW-1`); `addr = r_ROW * c_COL + r_COL` | N/A |
| `CLEAR` | `CLEAR` while counting; `IDLE` in the final cycle | ∅; (0,0) on exit | `o_Wr_En = 1`, `addr = counter`, `data = 0x20`; input ignored |

## The byte-alignment invariant

**The escape states consume exactly two bytes, whatever those bytes are.** Once
`ESC` moves the FSM out of `IDLE`, the next byte is a column and the one after it
is a row — no byte is ever re-examined, rejected, or pushed back. Every path
through `ESC_COL` and `ESC_ROW` is the same length.

This is what makes the rest of the parser easy to reason about. Validity is
handled by clamping the value, never by refusing the byte, so there is no path
where a malformed sequence consumes one byte instead of two and leaves the parser
reading the host's next character as a coordinate forever after. Byte alignment
is a property of the state machine's shape, not of the data flowing through it.

The invariant under test, with `ESC` followed by two printable bytes:
[verification.md](verification.md#waveforms).

## The four decisions

Each of these is a fork with no universally right answer; instead, I have chosen a design implementation, with my thoughts behind it:

### Out-of-range coordinates: clamp

`ESC 200 200` on a 40×30 grid sets the cursor to (39, 29) rather than being
ignored.

Clamping preserves an invariant the whole design leans on: **the cursor is always
a real cell**. Nothing downstream ever needs a range check or a defined behavior for an out-of-bounds address, because an out-of-bounds cursor cannot exist. Ignoring the
sequence instead would push that burden outward: some other module would have to
decide what a cursor pointing off-screen means. The cost, however, is that a host bug producing garbage coordinates is silently absorbed instead of being made visible.

Tested by `ESC 200 200` on the 4×3 simulation grid, which clamps to (3, 2) —
see [verification.md](verification.md#coverage).

### End of screen: wrap

Advancing past the last cell returns the cursor to (0,0) rather than sticking at
the last cell or stopping.

Same invariant, extended in time: the cursor stays a real position no matter how
many characters arrive. The practical version of the argument is `cat`ting a long
file at the display. With wrap, the screen keeps painting, even if what you're reading scrolls past. With a sticky cursor, output
piles into one cell and the system looks hung, which is indistinguishable from an
actual hang at the moment you most want to tell them apart.

Wrapping to (0,0) rather than scrolling is the cheap choice: scrolling means
moving 1200 cells of RAM per line, and there is no budget for that.

### A byte arriving during `CLEAR`: drop it

Bytes received while `o_Busy` is high are discarded, not queued.

The timing says this never happens. At 115200 baud and 25 MHz a byte occupies
217 × 10 = 2170 clocks, and the clear walk is `c_COL * c_ROW` = 1200 clocks — the
walk finishes with 970 clocks to spare before the next byte can complete. The
margin is 1.8×, and it comes from the two datasheet numbers rather than from
measurement.

So the decision is really about what to do in a case the timing analysis says is
unreachable. Dropping is one line and cannot fail. Queueing means a holding
register, plus an answer for what happens to the *second* byte, plus a way to
test a path that normal operation never enters. `o_Busy` exists to make the claim
checkable, not because anything is expected to act on it.

### `ESC` inside an escape sequence: it's column 27

`ESC 0x1B ...` sets the column to 27. `ESC` is not special once the FSM has left
`IDLE`.

The alternative is treating `ESC` as a restart — abandon the partial sequence and
begin a new one. That is friendlier to a host that changes its mind mid-sequence,
but it breaks the invariant above: a sequence would then consume two bytes
normally and one byte on restart, and the parser would need a resync rule. One
uniform rule ("in the escape states, every byte is a coordinate") is smaller in
hardware and shorter to state than any rule with an exception in it.

**The limitation being accepted:** there is no way to abort a partial escape
sequence, and no timeout on one. If the host sends `0x1B` and then dies, the
parser waits in `ESC_COL` indefinitely, and the next byte to arrive — a minute
later, from an unrelated write — is eaten as a column. Host and parser can
desynchronize, and nothing recovers them automatically.

This is bounded, which is why it's acceptable: at most two bytes are ever
misread, the FSM always returns to `IDLE`, and the display keeps refreshing
throughout, so the system does not lock up under any input.

## Address arithmetic

The cell address is `r_ROW * c_COL + r_COL`. Written that way it is also built
that way: the iCE40-HX1K has no hard multipliers, so yosys would build one out of
LUTs, and there are only 1280 LUTs in the whole part.

**A running address register is the primary representation.** `o_Wr_Addr` is a
counter, and each cursor motion is an increment or a constant offset:

| Motion | Address update |
| --- | --- |
| printable character | `r_Addr <= r_Addr + 1` |
| wrap at end of screen | `r_Addr <= 0` |
| LF | `r_Addr <= r_Addr + c_COL` |
| CR | `r_Addr <= r_Addr - r_COL` |
| `CLEAR` walk | the walk counter itself |

Every one of those is an adder. Nothing on the per-character path multiplies, and
the per-character path is the one that runs constantly.

**`ESC_ROW` is the single exception.** The escape sequence delivers a (col, row)
pair directly, so the address has to be reconstructed from it — this is the one
place the multiply is unavoidable. It costs nothing anyway, because `c_COL` is a
constant: `r_ROW * 40` is `r_ROW * 32 + r_ROW * 8`, two shifts and an add, and
yosys does that reduction without being asked. A constant multiply is not a
multiplier.

The consequence is that the address and the (col, row) pair are two
representations of the same state, and they must be kept consistent — `ESC_ROW`
writes all three registers together, and every other path updates all three in
step. That duplication is deliberate. Keeping (col, row) alongside the address is
what makes wrap and CR detectable at all: `r_COL == c_COL-1` is a comparison
against a constant, whereas recomputing "am I at the end of a row?" from the
address alone would mean a divide.

Recomputing `r_ROW * c_COL + r_COL` on every character would put that constant
multiply — small as it is — plus its adder on the critical path of the common
case, to produce a number an increment already had. The running register makes
the frequent operation free and pays for the rare one once.
