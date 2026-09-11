# Protocol research notes

This project builds on protocol work by others; their files are not redistributed here
because they carry no license. Read them at the source:

- [marcoslor/Aula-F87-Controller](https://github.com/marcoslor/Aula-F87-Controller) —
  reverse-engineered AULA F87 HID protocol (`docs/PROTOCOL.md`), Python CLI, and the
  `python-cli/aula/stream.py` decoder of the `0x88` color stream.
- [NollieL/SignalRgb_CN_Key](https://github.com/NollieL/SignalRgb_CN_Key) — SignalRGB plugin
  with the LED index map for the F87 / F87 Pro (wired 520-byte direct mode).
- [OpenRGB Sinowealth controller](https://gitlab.com/CalcProgrammer1/OpenRGB/-/tree/master/Controllers/SinowealthController)
  — wired direct-RGB protocol.

## Facts established on the F87 Pro over Bluetooth LE (2026-09)

- Device: `AULA-F87Pro 5.0`, VID `0x3554`, PID `0xFA07`, one HID collection, 20-byte reports,
  report ID `0x13`, checksum = sum of bytes 0–18 mod 256. ~50 ms per report over BLE.
- Config read (`0x44 0x01`) loses fragments and goes quiet after ~2 requests per connection;
  close/reopen the HID device between attempts and accumulate the 10 fragments.
- Config write (`0x04`) to effect 21 with confirm flag (byte 8) = 1 and apply flag (byte 14) = 0
  applies immediately without `SAVE`; the keyboard reverts to its saved effect on reboot.
- Writing a *built-in* effect over BLE (effect 2 / colorMode 3) disconnected the keyboard from
  Bluetooth. Not repeated.
- Per-key map (`0x02 0x1C`, 28 fragments: R, G, B planes × 9, trailer `06 00 00 5A A5`) applies
  live in effect 21. Solid red/green/blue verified.
- `0x88` stream data is `R G B count idx…` groups (not brightness pairs), 14 data bytes per
  fragment, subcmd = fragment count, byte 4 = `0x1E` or `0x10+len` on the last fragment; idle
  frame payload `0x23`. Unmentioned keys keep their per-key color. Verified: red and blue pulses.
- LED indices used here: Esc 0, F1–F12 = 12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72, 78.
