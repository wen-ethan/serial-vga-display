# serial-vga-display

UART-controlled VGA character display on a Lattice iCE40 FPGA, written in Verilog.

A host PC sends bytes over a serial port; the FPGA parses them and renders text
to a VGA monitor as a 40x30 grid of characters, each cell an ASCII code drawn
through a font ROM. Target board is the Nandland Go Board (iCE40-HX1K, VQ100,
25 MHz), built with the open-source toolchain: Yosys, nextpnr-ice40, IceStorm
(`icepack`, `icetime`, `iceprog`), and Icarus Verilog for simulation.

**Status: in progress.** The build flow is proven on hardware, and the command
parser is complete and passing a self-checking testbench in simulation. The
render path — character RAM, font ROM, and the character generator that scans
them out — is not written yet.

## Docs

- [docs/design.md](docs/design.md) — the parser's state table, the byte-alignment
  invariant, the four protocol decisions and the reasoning behind each, and why
  the cell address is a running counter rather than a multiply.
- [docs/verification.md](docs/verification.md) — how each module is tested, what
  the tests cover, waveform captures, and what is deliberately not covered.

## Build

    make TOP=UART_Loopback_Top          # synthesize, place and route, pack
    make TOP=UART_Loopback_Top prog     # flash the board over USB
    make TOP=UART_Loopback_Top timing   # icetime timing report
    make clean                          # remove build/

`TOP` picks which design to build, and each one names its own file list in the
Makefile. Nothing is globbed — yosys only sees the files it is handed, so every
module a design instantiates has to be listed there.

Generated files all land in `build/`, which is gitignored.

## Simulate

    make sim TB=tb_Command_Parser       # compile with iverilog, run under vvp
    make wave TB=tb_Command_Parser      # same, then open the VCD

`sim` runs `vvp` from inside `build/`, so the relative `$dumpfile` in each
testbench puts `dump.vcd` there rather than in the source tree. `wave` opens it
with `code` for WaveTrace; override with `WAVE=gtkwave`.

`tb_Command_Parser` is self-checking and prints `PASS` or `FAIL`, along with the
simulation time each test starts at, so the log doubles as an index into
`dump.vcd`. To open the waves with its signals already chosen and grouped:

    gtkwave build/dump.vcd sim/tb_Command_Parser.gtkw

## Layout

    Makefile                 build and simulation targets, variables inline
    constraints/             Go Board pin constraints, provided by Nandland
    common/                  reusable modules, copied verbatim from go-board-fpga
    bringup/                 book designs rebuilt here to prove the build flow
    rtl/                     new RTL for this project
    sim/                     testbenches and saved waveform signal sets
    docs/                    design rationale and verification record
    build/                   generated, gitignored

`bringup/` holds the UART loopback and VGA test-pattern designs from the
tutorial series. They are here so a build or programming failure can be told
apart from a bug in new RTL, and they come out once the real design is running
on hardware.

## Serial

Connect at 115200 baud, 8N1:

    screen $(ls /dev/cu.usbserial-*1 | tail -1) 115200

Quit with `Ctrl-A` `K`, then `y`. Run it from Terminal.app or iTerm rather than
the VS Code integrated terminal, which swallows `Ctrl-A`.

The Go Board's FTDI chip exposes two channels: channel A is the JTAG/config
port `iceprog` uses, channel B is the UART. The glob picks channel B, whose
digits come from the USB location ID and change whenever the board is plugged
into a different port.

## Scope

The design, protocol, and RTL are my own. The modules in `common/`, the designs
in `bringup/`, and the Go Board pin constraints all come from Russell Merrick's
[Nandland](https://nandland.com/project-1-your-first-go-board-project/) (the Go
Board tutorial series and *Getting Started with FPGAs*), carried over from
[go-board-fpga](https://github.com/ethanwen/go-board-fpga).

## License

MIT. See [LICENSE](LICENSE).
