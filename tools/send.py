#!/usr/bin/env python3
"""Send text to the serial VGA display.

The display's protocol treats CR and LF as separate primitives: CR returns the
cursor to column 0, LF moves it down a row without changing the column. That is
what the control codes actually mean, and it is what real terminals implement --
but it means a Unix text file, which contains bare LF, would march diagonally
down the screen. Translating "\\n" to CR LF is this script's main job, and it is
why `send.py --file notes.txt` renders correctly where
`cat notes.txt > /dev/cu.usbserial-*` does not.

    tools/send.py                        # the built-in demo screen
    tools/send.py --text 'HELLO'         # send a string
    tools/send.py --file notes.txt       # send a file
    echo HELLO | tools/send.py           # or pipe it
    tools/send.py --clear                # clear and stop
    tools/send.py --at 10 5 --text 'X'   # position the cursor first

Standard library only, so it runs on a fresh clone with no pip install.
"""

import argparse
import glob
import os
import sys
import termios

FF = b"\x0c"   # form feed: clear the screen
ESC = b"\x1b"  # escape: the next two bytes are column, then row

COLS, ROWS = 40, 30

DEMO = """HELLO FROM THE GO BOARD

TYPED IN A TERMINAL, RENDERED BY
AN FPGA WITH NO FRAMEBUFFER.

1200 CELLS, 6 OF 16 BLOCK RAMS.

:P
"""


def find_port():
    """Channel B of the Go Board's FTDI chip.

    Channel A is the JTAG/configuration port iceprog uses; channel B is the
    UART. The digits come from the USB location ID and change whenever the
    board is plugged into a different port, so this globs rather than hardcodes.
    """
    ports = sorted(glob.glob("/dev/cu.usbserial-*1"))
    if not ports:
        sys.exit("send.py: no /dev/cu.usbserial-*1 found. Is the board plugged in?")
    return ports[-1]


def open_port(dev, baud):
    """Open and configure in one go.

    Opening a tty resets its termios settings, so configuring with a separate
    `stty` invocation and then writing through a shell redirect loses the baud
    rate -- the bytes go out at the default and the FPGA sees noise. Holding one
    descriptor across both steps is the whole trick.
    """
    try:
        fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
    except OSError as exc:
        sys.exit(f"send.py: cannot open {dev}: {exc}")

    speed = getattr(termios, f"B{baud}", None)
    if speed is None:
        sys.exit(f"send.py: unsupported baud rate {baud}")

    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                            # iflag: no input mapping
    attrs[1] = 0                                            # oflag: no LF -> CRLF mangling
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # 8 data bits, no flow control
    attrs[3] = 0                                            # lflag: raw, no echo
    attrs[4] = speed                                        # ispeed
    attrs[5] = speed                                        # ospeed
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def encode(text):
    """Text to protocol bytes.

    Newlines become CR LF, since the display needs both to reach the start of
    the next line. Bytes outside 0x20..0x7E are dropped rather than sent: the
    parser ignores them anyway, and dropping them here means what is sent is
    exactly what should appear.
    """
    out = bytearray()
    for ch in text:
        if ch == "\n":
            out += b"\r\n"
        elif 0x20 <= ord(ch) <= 0x7E:
            out.append(ord(ch))
    return bytes(out)


def warn_long_lines(text):
    for n, line in enumerate(text.split("\n")):
        if len(line) > COLS:
            print(f"send.py: line {n + 1} is {len(line)} chars and will wrap "
                  f"at {COLS}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="Send text to the serial VGA display.")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--text", help="string to send")
    src.add_argument("--file", help="file to send")
    ap.add_argument("--clear", action="store_true",
                    help="clear the screen first (form feed)")
    ap.add_argument("--at", nargs=2, type=int, metavar=("COL", "ROW"),
                    help="position the cursor before sending")
    ap.add_argument("--dev", help="serial device (default: autodetect)")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    if args.text is not None:
        text = args.text
    elif args.file:
        with open(args.file) as fh:
            text = fh.read()
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
    elif args.clear or args.at:
        text = ""                      # --clear on its own is a valid thing to want
    else:
        text = DEMO
        args.clear = True              # the demo owns the whole screen

    warn_long_lines(text)

    payload = b""
    if args.clear:
        payload += FF
    if args.at:
        col, row = args.at
        if not (0 <= col < COLS and 0 <= row < ROWS):
            print(f"send.py: ({col}, {row}) is outside the {COLS}x{ROWS} grid; "
                  f"the parser will clamp it", file=sys.stderr)
        payload += ESC + bytes([min(col, 255), min(row, 255)])
    payload += encode(text)

    dev = args.dev or find_port()
    fd = open_port(dev, args.baud)
    try:
        os.write(fd, payload)
        termios.tcdrain(fd)            # do not close until the last bit is out
    finally:
        os.close(fd)

    print(f"send.py: {len(payload)} bytes to {dev} at {args.baud}", file=sys.stderr)


if __name__ == "__main__":
    main()
