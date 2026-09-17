#!/usr/bin/env python3
"""Fake WLED receiver: listens for DDP on UDP 4048, validates each packet and draws the strip as
colored blocks in the terminal (24-bit ANSI). Usage: ddp-fake.py [--port 4048] [--leds N] [--width 80]"""
import argparse, socket, struct, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=4048)
ap.add_argument("--leds", type=int, default=0, help="expected LED count (warn on mismatch)")
ap.add_argument("--width", type=int, default=80, help="max blocks per line (LEDs are subsampled beyond this)")
a = ap.parse_args()

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", a.port))
print(f"listening on udp/{a.port}", flush=True)
last = None; frame = {}   # offset -> bytes, assembled until a push packet arrives
n = 0
while True:
    data, peer = s.recvfrom(65535)
    now = time.time(); n += 1
    if len(data) < 10:
        print(f"#{n} short packet ({len(data)} bytes) from {peer}", flush=True); continue
    flags, seq, dtype, dest, off, length = struct.unpack(">BBBBIH", data[:10])
    warn = []
    if flags & 0xC0 != 0x40: warn.append(f"version {flags >> 6} (expected 1)")
    if dtype not in (0x0B, 0x01): warn.append(f"data type 0x{dtype:02x} (expected 0x0b RGB8)")
    if dest != 1: warn.append(f"destination {dest} (expected 1)")
    if length != len(data) - 10: warn.append(f"length {length} but {len(data) - 10} data bytes")
    if off % 3 or length % 3: warn.append("offset/length not a multiple of 3")
    frame[off] = data[10:10 + length]
    if not flags & 0x01:   # not push: wait for the rest of the frame
        continue
    buf = b"".join(frame[k] for k in sorted(frame)); frame = {}
    leds = len(buf) // 3
    if a.leds and leds != a.leds: warn.append(f"{leds} LEDs (expected {a.leds})")
    step = max(1, -(-leds // a.width))
    blocks = "".join(f"\x1b[48;2;{buf[i*3]};{buf[i*3+1]};{buf[i*3+2]}m " for i in range(0, leds, step)) + "\x1b[0m"
    dt = f"{(now - last) * 1000:5.0f} ms" if last else "  first"
    last = now
    print(f"#{n:4d} seq {seq:2d} {leds:3d} LEDs {dt} {blocks}" + (f"  WARN: {'; '.join(warn)}" if warn else ""), flush=True)
