#!/usr/bin/env python3
"""Agent-like TUI output. storm: a block of N lines repainted at FPS inside a
synchronized update (cursor up, erase, colored text with box glyphs), the way
an Ink-style renderer streams a reply. flood: log lines as fast as possible."""
import os, sys, time

mode, n, fps, secs = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
out = os.fdopen(sys.stdout.fileno(), "wb", buffering=0)
words = "the parser now handles nested quotes and escapes before tokenizing input".split()
spin = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
end = time.time() + secs
f = 0
if mode == "flood":
    line = ("\x1b[32mINFO\x1b[0m compiling crate fleet_tmux v0.1.0 (" + "x" * 50 + ")\r\n").encode()
    blk = line * 200
    while time.time() < end:
        out.write(blk)
    sys.exit(0)
while time.time() < end:
    t = time.time()
    buf = ["\x1b[?2026h"]
    if f:
        buf.append(f"\x1b[{n}A")
    for i in range(n):
        w = " ".join(words[(f + i + j) % len(words)] for j in range(11))
        if i == 0:
            buf.append(f"\r\x1b[2K\x1b[38;5;174m{spin[f % 10]}\x1b[0m Thinking… \x1b[2m({f // 30}s · esc to interrupt)\x1b[0m\r\n")
        elif i == n - 3:
            buf.append("\r\x1b[2K\x1b[38;5;244m╭" + "─" * 96 + "╮\x1b[0m\r\n")
        elif i == n - 2:
            buf.append("\r\x1b[2K\x1b[38;5;244m│\x1b[0m ❯ " + " " * 93 + "\x1b[38;5;244m│\x1b[0m\r\n")
        elif i == n - 1:
            buf.append("\r\x1b[2K\x1b[38;5;244m╰" + "─" * 96 + "╯\x1b[0m\r\n")
        else:
            buf.append(f"\r\x1b[2K  \x1b[1m⏺\x1b[0m \x1b[38;2;220;220;170m{w[:90]}\x1b[0m\r\n")
    buf.append("\x1b[?2026l")
    out.write("".join(buf).encode())
    f += 1
    d = 1 / fps - (time.time() - t)
    if d > 0:
        time.sleep(d)
