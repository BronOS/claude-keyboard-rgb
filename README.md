# claude-keyboard

Use an AULA F87 Pro keyboard (Bluetooth) as a Claude Code status light, agterm-style:
the F-row + Esc pulse blue while Claude works, turn solid green when it stops, and pulse
orange when it is waiting for a permission decision.

## Layout

| Path | Purpose |
|------|---------|
| `kbstatus/kbstatus.swift` | daemon + hook client (single binary, IOKit HID, no dependencies) |
| `probe/kbtest.swift` | protocol experiment tool (`read`, `experiment`, `perkey`, `effect`, `stream`) |
| `probe/hidprobe2.swift` | first minimal probe |
| `docs/research/` | protocol findings for the F87 Pro over BLE, with links to the upstream research |

## Install (any Mac)

```sh
git clone https://github.com/BronOS/claude-keyboard-rgb.git ~/Projects/claude-keyboard && cd ~/Projects/claude-keyboard
./install.sh              # builds, installs ~/.local/bin/kbstatus, adds the hooks
./install.sh --uninstall  # removes hooks and binary
```

Needs Xcode Command Line Tools (`xcode-select --install`). Manual build, if you prefer:

```sh
cd kbstatus
xcrun swiftc -O -o kbstatus kbstatus.swift
cp kbstatus ~/.local/bin/kbstatus.new && mv -f ~/.local/bin/kbstatus.new ~/.local/bin/kbstatus
kbstatus stop   # the next hook call starts the new daemon
```

Replace the binary by rename, never `cp` over it in place: macOS invalidates the code
signature of an overwritten executable and silently kills every new invocation.

macOS asks for **Input Monitoring** permission for the terminal the first time the HID
device is opened.

## Hooks (in `~/.claude/settings.json`)

| Event | Command |
|-------|---------|
| UserPromptSubmit, PostToolUse | `kbstatus working` |
| Stop | `kbstatus done` |
| Notification (matcher `permission_prompt`) | `kbstatus attention` |
| PreToolUse (matcher `AskUserQuestion`) | `kbstatus attention` |
| SessionEnd | `kbstatus end` |

The client reads `session_id` from the hook JSON on stdin, so several Claude sessions are
tracked independently. Priority: attention > working > done > idle. `done` fades to idle
after 90 s; a silent `working` session is dropped after 20 min.

The first client call spawns the daemon (`kbstatus daemon`, detached). Useful commands:

```sh
kbstatus status                 # daemon state and tracked sessions
kbstatus working --session x    # manual test
kbstatus stop                   # stop daemon, board goes to idle colors
kbstatus restore                # stop daemon and write the keyboard's original config back
tail -f ~/.cache/kbstatus/daemon.log
```

## Configuration (optional): `~/.config/kbstatus/config.json`

```json
{
  "indicatorKeys": ["esc","f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12"],
  "working":   [0, 90, 255],
  "done":      [0, 255, 40],
  "attention": [255, 0, 0],
  "rest":      [0, 0, 0],
  "idle":      [0, 0, 0],
  "doneHoldSeconds": 90,
  "workingTimeoutMinutes": 20,
  "pulseFloor": 0.25,
  "attentionStyle": "pulse",
  "productID": 64007,
  "skipConfigWrite": false,
  "echoWaitMs": 0
}
```

Per-machine notes: the same keyboard paired as `AULA-F87Pro 3.0` (PID `0xFA08`, `"productID": 64008`)
drops off Bluetooth on every config write and loses per-key fragments at the default pacing. On that
link use `"skipConfigWrite": true` (the keyboard is already in effect 21) and `"echoWaitMs": 60`
(wait for the keyboard's echo after each report). `kbstatus restore` also does a config write, so
don't run it there. On a new machine run `kbstatus read-config` once (repeat until all 10 fragments
arrive) so `config.hex` holds that keyboard's own config.

Key names are the lowercase labels from the key map in `kbstatus.swift` (`keyLED`)
(`esc`, `f1`…`f12`, `w`, `a`, `s`, `d`, `space`, `enter`, `up`, …). Restart the daemon
(`kbstatus stop`) after editing.

## How it works (Bluetooth specifics)

- All traffic is 20-byte HID output reports, report ID 0x13, on the BLE keyboard device
  (VID 0x3554, PID 0xFA07). Each report costs ~50 ms over BLE.
- The daemon writes the config once to switch to per-key mode (effect 21) **without saving
  to flash**; the keyboard reverts to its saved effect when it reboots.
- Solid states are 28-fragment per-key color maps (~1.4 s).
- Pulses use the `0x88` color stream. Its data is a sequence of groups
  `R G B count idx1..idxN`, packed 14 bytes per fragment (subcmd = fragment count, byte 4 =
  `0x1E` on full fragments, `0x10+len` on the last). 13 indicator keys fit in 2 fragments,
  so a frame costs ~100 ms and pulses run at ~10 fps in any color. The idle frame (payload
  `0x23`) hands the keys back to the per-key map. (The encoding was decoded by the
  [Aula-F87-Controller](https://github.com/marcoslor/Aula-F87-Controller) project's `stream.py`;
  an older description as `(brightness, led)` pairs is wrong.)
- `attentionStyle`: `pulse` (default, red 0x88 stream) | `blink` (alternate color maps, ~3 s) | `static`.
- **Never switch built-in effects over BLE**: writing effect 2 made the keyboard drop off
  Bluetooth entirely. `kbstatus restore` writes back the exact original config and is the
  only place this is attempted.
- Reading the config over BLE loses fragments and goes quiet after ~2 reads per connection;
  `kbstatus read-config` reopens the device between attempts and caches the result in
  `~/.config/kbstatus/config.hex`.
- On keyboard sleep/reconnect the daemon re-applies per-key mode and the current state.

## Credits

Protocol knowledge comes from [marcoslor/Aula-F87-Controller](https://github.com/marcoslor/Aula-F87-Controller)
and [NollieL/SignalRgb_CN_Key](https://github.com/NollieL/SignalRgb_CN_Key); see `docs/research/README.md`.
