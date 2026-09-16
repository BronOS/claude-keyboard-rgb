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
after 90 s, or as soon as you press a key on the keyboard (`doneClearsOnTyping`, agterm-style);
a silent `working` session is dropped after 20 min.

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
  "solidKeys": "all",
  "working":   [0, 90, 255],
  "done":      [0, 255, 40],
  "attention": [255, 0, 0],
  "idle":      [0, 0, 0],
  "doneHoldSeconds": 90,
  "doneClearsOnTyping": true,
  "workingTimeoutMinutes": 20,
  "pulseFloor": 0.25,
  "attentionStyle": "pulse",
  "workingStyle": "pulse",
  "streamFps": 5,
  "overlayRefreshSeconds": 1.5,
  "typingHoldSeconds": 1,
  "mapQuietSeconds": 10,
  "skipBackgroundMap": false,
  "agtermBadge": false,
  "productID": 64007,
  "skipConfigWrite": false,
  "echoWaitMs": 0
}
```

Only `0x88` stream frames are used for status colors; they never block key input. The one per-key
map write (all keys `idle` color, once per connection) freezes key scanning for ~1.4 s, so the
daemon waits for `mapQuietSeconds` (default 10) without a keystroke before sending it. If the
keyboard's own saved per-key map is already dark, set `"skipBackgroundMap": true` and no map is
ever written.

- `workingStyle` / `attentionStyle`: `pulse` (frames at `streamFps`) | `static` (one overlay,
  re-sent every `overlayRefreshSeconds`) | `blink` (attention only). `workingStyle` unset defaults
  to `static` on the BT-classic link (`productID` 64008) and `pulse` elsewhere.
- `streamFps`: pulse frame rate; 2 typed fine on BT classic and still looks smooth (the keyboard
  fades between frames).

`kbstatus bench <fps> <secs>` streams steady green at a given rate for testing (pause the daemon
first with `kbstatus pause`).

Per-machine notes: the same keyboard paired as `AULA-F87Pro 3.0` (PID `0xFA08`, `"productID": 64008`)
drops off Bluetooth on every config write and loses per-key fragments at the default pacing. On that
link use `"skipConfigWrite": true` (the keyboard is already in effect 21) and `"echoWaitMs": 60`
(wait for the keyboard's echo after each report); `workingStyle` defaults to `static` there
(`pulse` with `"streamFps": 2` also types fine). Its saved per-key map is already dark, so
`"skipBackgroundMap": true` avoids the one map write that would freeze typing for ~1.4 s.
Full-board colors work there too: `"solidKeys": "all"`, `"attentionKeys": "all"`, `"workingKeys": "all"`,
`"streamGapMs": 60`, `"streamFps": 3` gives a whole-board red breathe at 0.6 Hz (~17 reports/s)
that still types fine. `kbstatus restore` also does a config write, so
don't run it there. On a new machine run `kbstatus read-config` once (repeat until all 10 fragments
arrive) so `config.hex` holds that keyboard's own config.

`indicatorKeys` are the keys that pulse; `solidKeys` (default: the same keys, or `"all"`) are the
keys painted by the done state; `attentionKeys` and `workingKeys` (same options) are the keys
those states paint in any style. Pulse rates slow down automatically so every cycle gets at least 4 frames
(a full-board frame takes ~0.7 s to send, so a full-board pulse breathes at ~0.35 Hz). One color on all 87 keys is a 7-report frame instead of 2, so a
solid full board costs ~5 reports/s at the default refresh; keep pulses on the F-row. The
BT-classic link loses a fragment now and then, and a full-board frame is more exposed: expect
a brief blink every half minute or so. `streamGapMs` (pacing between a frame's fragments,
default = `echoWaitMs`) and `overlayRefreshSeconds` are the knobs; 100 ms / 1.5 s and
60 ms / 1.0 s both still blink occasionally on this link.

Key names are the lowercase labels from the key map in `kbstatus.swift` (`keyLED`)
(`esc`, `f1`…`f12`, `w`, `a`, `s`, `d`, `space`, `enter`, `up`, …). Restart the daemon
(`kbstatus stop`) after editing.

## agterm badges on the number row (optional)

With `"agtermBadge": true` the daemon polls `agtermctl` every `badgePollSeconds` (2) and lights
the number keys red, one per agterm session that has an unseen-notification badge (`"badgeCount":
"notifications"` sums the badges instead). The keys stay lit in every status, including idle, and
go out by themselves when you open the session, because agterm clears the badge then. Every open
agterm window is counted. `badgeKeys`, `badgeColor` and `agtermctlPath` (default
`/opt/homebrew/bin/agtermctl`) can be changed.

## How it works (Bluetooth specifics)

- All traffic is 20-byte HID output reports, report ID 0x13, on the BLE keyboard device
  (VID 0x3554, PID 0xFA07). Each report costs ~50 ms over BLE.
- The daemon writes the config once to switch to per-key mode (effect 21) **without saving
  to flash**; the keyboard reverts to its saved effect when it reboots.
- A per-key map transfer (`0x02 0x1C`, 28 fragments) freezes key scanning for its whole
  duration, however the fragments are paced: keystrokes only arrive after the trailer. So the
  daemon writes one black map per connection, after a pause in typing, and never uses maps for
  status colors.
- `0x88` stream frames never block key input, but the keyboard leaves stream mode a few seconds
  after the last frame and falls back to the per-key map, so solid states are re-sent every
  `overlayRefreshSeconds` (2 reports each). Pulses stream at `streamFps`.
- The keyboard echoes `0x02` map fragments back verbatim (never `0x88` frames). With `echoWaitMs`
  > 0 the map write waits for each echo and resends an un-echoed fragment once; on failure it
  backs off 2 s.
- The keyboard sleeps about a minute after the last keystroke, regardless of host traffic. While
  asleep it drops every report (nothing is queued, no burst on wake) and the F-row goes dark; the
  next keystroke wakes it and the next refresh repaints the current status within ~1.5 s.
- The `0x88` color stream's data is a sequence of groups
  `R G B count idx1..idxN`, packed 14 bytes per fragment (subcmd = fragment count, byte 4 =
  `0x1E` on full fragments, `0x10+len` on the last). 13 indicator keys fit in 2 fragments,
  so a frame costs ~100 ms. The idle frame (payload `0x23`) hands the keys back to the per-key map. (The encoding was decoded by the
  [Aula-F87-Controller](https://github.com/marcoslor/Aula-F87-Controller) project's `stream.py`;
  an older description as `(brightness, led)` pairs is wrong.)
- `attentionStyle`: `pulse` (default, red 0x88 stream) | `blink` (overlay on/off, 1 s period) | `static`.
- **Never switch built-in effects over BLE**: writing effect 2 made the keyboard drop off
  Bluetooth entirely. `kbstatus restore` writes back the exact original config and is the
  only place this is attempted.
- Reading the config over BLE loses fragments and goes quiet after ~2 reads per connection;
  `kbstatus read-config` reopens the device between attempts and caches the result in
  `~/.config/kbstatus/config.hex`.
- On reconnect the daemon re-applies per-key mode, the background map, and the current state.

## Credits

Protocol knowledge comes from [marcoslor/Aula-F87-Controller](https://github.com/marcoslor/Aula-F87-Controller)
and [NollieL/SignalRgb_CN_Key](https://github.com/NollieL/SignalRgb_CN_Key); see `docs/research/README.md`.
