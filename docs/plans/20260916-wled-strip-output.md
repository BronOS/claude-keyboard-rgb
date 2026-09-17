# WLED strip output

## Overview
- Add an RGB LED strip as a second output of the `kbstatus` daemon: a WLED-driven WS2812B strip
  behind the monitor shows the same composite status as the keyboard (blue pulse while Claude works,
  solid green when done, red pulse on attention) plus an agterm badge bar (one LED per unseen
  notification), driven over Wi-Fi with WLED's DDP realtime protocol (UDP, port 4048).
- Solves: the keyboard is only visible at the desk and only while it is awake (it sleeps ~1 min after
  the last keystroke). An ambient strip is visible from across the room and never sleeps.
- Integrates as one more renderer inside the existing daemon: the session table, priorities,
  typing-clears-done rule, agterm badge poll and pulse timing are reused unchanged. The strip is off
  unless a `strip` block exists in `~/.config/kbstatus/config.json`; the keyboard path never depends
  on it.

## Context (from discovery)
- `kbstatus/kbstatus.swift` (666 lines): single-file daemon + hook client, top-level code, built with
  `xcrun swiftc -O -o kbstatus kbstatus.swift` (`install.sh:23`, `README.md:28`). Key pieces:
  `UserConfig` (l.47) with `load()` parsing `config.json`; protocol builders `checksummed`/`frame`/
  `perKeyFrames`/`overlayFrames`/`scaled` (l.128–160); `Status`/`SessionState`/`sessions`/`composite()`
  (l.344–366); `leds(for:)`, `effectiveFps`, `pulseHz` (l.368–379); agterm badge poller + `withBadge`
  (l.388–430); `writeOverlay` + `tick()` (l.450–520) which today both decides what to show and sends
  keyboard frames; `case "daemon"` (l.612) starts the HID manager, typing monitor, badge poller and the
  100 ms tick timer.
- Patterns: globals guarded by `stateLock` for cross-thread state (`pendingCommands`, `badgeCount`);
  everything logged to `~/.cache/kbstatus/daemon.log`; config knobs are flat keys in `config.json`;
  no dependencies beyond Foundation + IOKit; installed binary replaced by rename, never `cp` over.
- No tests exist. `probe/` holds standalone Swift experiment tools.
- Hard constraints from today's measurements (see README "How it works"): status colors on the
  keyboard are 0x88 stream overlays only; per-key map writes freeze the keyboard and are never used
  for status changes. This plan must not change keyboard behaviour.

## Development Approach
- **testing approach**: Regular (code first, then tests) with a small assert-based Swift test binary.
- Pure logic moves to `kbstatus/core.swift` (declarations only, no top-level statements); the daemon's
  top-level code moves to `kbstatus/main.swift` (Swift requires top-level code to live in `main.swift`
  when compiling several files). Tests live in `kbstatus/tests/main.swift` and are compiled together
  with `core.swift` into a throwaway executable by `kbstatus/test.sh`; a failed `precondition` is a
  failed test.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write tests for new functions and for modified functions, success and error/edge cases
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change (`kbstatus/test.sh`) and rebuild the daemon (`install.sh` build line)
- maintain backward compatibility: existing `config.json` files keep working unchanged

## Testing Strategy
- **unit tests**: `kbstatus/test.sh` builds `core.swift + tests/main.swift` and runs it; required for
  every task. Tests pin the current keyboard protocol encoding first (Task 1) so the refactor is
  verified before anything new is built on it.
- **integration**: `probe/ddp-fake.py` (Task 6) is a fake WLED receiver on UDP 4048 that validates each
  DDP packet and renders the strip as colored blocks in the terminal; used to verify the strip output
  end to end on localhost before hardware exists.
- **regression, manual**: after Task 1 and again at the end, the keyboard checks used on 2026-09-16:
  working → done → idle transitions switch instantly; typing through transitions has no freeze; red
  pulse on a question; agterm badge keys light and clear; `kbstatus status` output unchanged.
- no e2e UI tests in this project.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **One daemon, two renderers.** `tick()` computes a `Picture` once per tick: composite status, its
  style, the agterm badge count and the current time. Renderers turn the picture into device frames:
  the keyboard renderer is the existing overlay code (same frames, same timing, now reading from the
  picture), the strip renderer maps the picture onto N LEDs and sends one DDP packet.
- **Strip layout** from config: `statusRange` LEDs show the state color scaled by the pulse level;
  `badgeRange` LEDs light one per badge in `badgeColor` from the start of the range; other LEDs off;
  idle = all off. `brightness` (0–1) scales everything.
- **Transport**: DDP over UDP, fire-and-forget. Sent when the picture changes; at the tick rate (10 fps)
  while pulsing; as a keep-alive every `keepAliveSeconds` (1.0) while a solid state is shown so WLED
  stays in realtime mode; idle sends one all-off packet and then nothing (WLED's realtime timeout keeps
  it dark). No retries, no acknowledgement. Host resolved with `getaddrinfo` at startup (supports
  `wled-xxxx.local`) and re-resolved every 60 s after a send error.
- **Why not a second daemon**: the hooks call one command; the state logic is the product; a second
  process would duplicate it or need a protocol. The renderer split keeps a later extraction cheap.
- **Serial/Adalight** is deliberately out of scope (config key `transport` reserved, only `"ddp"`
  accepted; anything else logs and disables the strip).

## Technical Details
- **`Picture`** (core): `struct Picture { status: Status; style: String; badge: Int; t: Double }`.
- **Pulse level** (core): `pulseLevel(t:hz:floor:) = floor + (1 - floor) * (0.5 - 0.5 * cos(2π·hz·t))`;
  `cappedHz(nominal:fps:) = min(nominal, fps / 4)` (a cycle needs ≥ 4 frames). Keyboard keeps its
  per-device fps cap (`effectiveFps`); the strip uses the tick rate (10 fps), so its attention pulse
  runs at the full 2 Hz and working at 0.8 Hz.
- **`StripConfig`** (core): `host: String, port: UInt16 = 4048, leds: Int, statusRange: ClosedRange<Int>,
  badgeRange: ClosedRange<Int>?, brightness: Double = 0.6, keepAliveSeconds: Double = 1.0,
  transport: String = "ddp"`, parsed by `StripConfig.parse([String: Any]) -> StripConfig?` (returns nil
  with a reason string when `host`/`leds` are missing or ranges exceed `leds`).
- **`stripColors(picture, cfg, colors) -> [RGB]`** (core): `colors` = the working/done/attention/badge
  RGB values from `UserConfig`; pulse styles scale the state color by `pulseLevel`, static styles use
  it as is, blink alternates on/off per second like the keyboard; badge LEDs = `min(badge, count)`
  from the start of `badgeRange`; result scaled by `brightness`.
- **DDP packet** (core): `ddpPacket(colors: [RGB], sequence: UInt8) -> [UInt8]` = 10-byte header +
  3·N bytes: `[0x41 (version 1 | push), seq & 0x0F, 0x0B (RGB, 8 bits per channel), 0x01 (output 1),
  offset u32 BE, length u16 BE] + RGB…`. ➕ Frames are split like WLED's own sender: 480 channels
  (160 LEDs) per packet with channel offsets, push flag only on the last packet (`ddpFrame`). 60 LEDs =
  one 190-byte packet; `leds` > 480 is rejected by `parse`.
- **UDP sender** (main): BSD `socket(AF_INET/AF_INET6, SOCK_DGRAM)` from `getaddrinfo(host, port)`;
  `sendto` per frame; on `-1` log once and schedule re-resolve; sequence number increments per packet.
- **Strip renderer state** (main): `lastStripSend`, `lastStripKey` (status+style+badge+quantized
  level) — send if key changed, or pulsing and 100 ms elapsed, or solid and `keepAliveSeconds` elapsed.
- **Config block** (`config.json`):
  ```json
  "strip": { "host": "wled-desk.local", "leds": 60, "statusRange": [0, 49],
             "badgeRange": [50, 59], "brightness": 0.6, "keepAliveSeconds": 1.0 }
  ```
- **Status text**: `kbstatus status` gains `strip: <host> <N> LEDs, last send Ns ago` or `strip: off`.
- **`kbstatus strip-test [secs]`**: standalone bring-up command: sweeps red → green → blue → a badge
  pattern across the strip without the daemon (daemon must be stopped or it also sends).
- **Build**: `xcrun swiftc -O -o kbstatus core.swift main.swift` (install.sh, README); tests:
  `kbstatus/test.sh` = `xcrun swiftc -o "$TMPDIR/kbstatus-tests" core.swift tests/main.swift && "$TMPDIR/kbstatus-tests"`.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes,
  tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - hardware purchase, WLED
  flashing and setup, first light, on-desk tuning

## Implementation Steps

### Task 1: Split the daemon into core.swift + main.swift and add the test harness

**Files:**
- Create: `kbstatus/core.swift`
- Create: `kbstatus/tests/main.swift`
- Create: `kbstatus/test.sh`
- Rename: `kbstatus/kbstatus.swift` → `kbstatus/main.swift`
- Modify: `install.sh`, `README.md`, `.gitignore` (test binary lives in `$TMPDIR`, nothing to ignore)

- [x] `git mv kbstatus/kbstatus.swift kbstatus/main.swift`; move to `core.swift`: `RGB`, `keyLED`,
      `checksummed`, `frame`, `perKeyFrames`, `overlayFrames`, `scaled`, `Status`, `SessionState`
      (declarations only; `cfg`, sockets, HID, logging stay in `main.swift`)
- [x] update the build line in `install.sh` and both build mentions in `README.md` to
      `xcrun swiftc -O -o kbstatus core.swift main.swift`; update the README layout table
- [x] create `kbstatus/test.sh` (compile `core.swift tests/main.swift` into `$TMPDIR/kbstatus-tests`, run it,
      exit non-zero on failure) and `kbstatus/tests/main.swift` with a tiny `check(_:_:)` helper that
      counts failures and exits 1
- [x] write tests pinning the keyboard protocol: `checksummed` (sum mod 256 into byte 19), `frame`
      layout (report id 0x13, cmd/sub/seq, payload cap 15), `perKeyFrames` (28 frames, R/G/B planes,
      trailer `06 00 00 5A A5`), `overlayFrames` (13 F-row keys → 2 fragments with byte 4 = 0x1E then
      0x10+len; empty list → the idle frame `13 88 01 00 23 … bf`; 87 keys one color → 7 fragments;
      two colors → two groups sorted by count), `scaled` (clamping and rounding)
- [x] write edge-case tests: `overlayFrames` with all-black colors yields the idle frame; more than 14
      fragments are truncated to 14; `frame` with an over-long payload keeps 15 bytes
- [x] run `kbstatus/test.sh` - must pass; rebuild and reinstall the daemon (rename, not cp) and run the
      manual keyboard regression checks - behaviour must be identical before task 2
      (2026-09-17: 100 checks pass; socket transitions working/done/attention/idle logged as before;
      typing/visual check pending with the user)

### Task 2: Introduce Picture and the pulse math

**Files:**
- Modify: `kbstatus/core.swift`, `kbstatus/main.swift`, `kbstatus/tests/main.swift`

- [x] add `struct Picture` and `pulseLevel(t:hz:floor:)`, `cappedHz(nominal:fps:)` to `core.swift`
- [x] in `main.swift`, make `tick()` build one `Picture` (composite status, `style(for:)`, badge count
      under `stateLock`, `CFAbsoluteTimeGetCurrent()`), and have the keyboard branch read status/style/
      badge/level from it; `pulseHz(for:)` becomes `cappedHz(nominal:fps: effectiveFps(for:))`
- [x] keep every keyboard decision identical: same early returns, same `changed` logic, same log lines
- [x] write tests: `pulseLevel` at t=0 equals `floor`, at half period equals 1, never leaves
      `[floor, 1]`; `cappedHz` returns the nominal rate when fps is high and `fps/4` when low; a
      `Picture` for each status carries the expected style given a `workingStyle`
- [x] run `kbstatus/test.sh` - must pass; rebuild, reinstall, keyboard regression check before task 3

### Task 3: Strip config and LED color mapping (pure)

**Files:**
- Modify: `kbstatus/core.swift`, `kbstatus/tests/main.swift`

- [x] add `struct StripConfig` with `parse(_ dict: [String: Any]) -> (StripConfig?, String?)`:
      requires `host` and `leds` (1…480), `statusRange`/`badgeRange` as `[Int, Int]` within `0..<leds`
      and non-overlapping, `brightness` clamped to 0…1, `transport` must be `"ddp"`, defaults for the rest
- [x] add `struct StatusColors { working, done, attention, badge: RGB }` and
      `stripColors(_ p: Picture, _ cfg: StripConfig, _ colors: StatusColors, floor: Double) -> [RGB]`
- [x] implement: idle → all off (badge LEDs still lit if badge > 0); static → state color; pulse →
      state color × `pulseLevel(t, hz: cappedHz(nominal, fps: 10), floor)`; blink → on for the first
      half of each second; badge LEDs from the start of `badgeRange`, `min(badge, rangeCount)`; final
      `brightness` scaling via `scaled`
- [x] write tests: parse success with defaults filled; parse failures (missing host, leds 0 and 481,
      range outside leds, overlapping ranges, transport "serial") return a reason; mapping for each
      status with and without badges; badge count capped to the range; brightness 0.5 halves values;
      LEDs outside both ranges stay black
- [x] run `kbstatus/test.sh` - must pass before task 4

### Task 4: DDP packet builder (pure)

**Files:**
- Modify: `kbstatus/core.swift`, `kbstatus/tests/main.swift`

- [x] add `ddpPacket(_ colors: [RGB], sequence: UInt8) -> [UInt8]` producing the 10-byte header
      (`0x41`, `seq & 0x0F`, `0x01`, `0x01`, offset 0 big-endian u32, length big-endian u16) + RGB bytes
- [x] write tests: 60 LEDs → 190 bytes, header bytes exact, length field 180 = `0x00 0xB4`; 1 LED →
      13 bytes; sequence 17 wraps to 1; colors land in order R,G,B per LED; 0 LEDs → header with
      length 0
- [x] run `kbstatus/test.sh` - must pass before task 5

### Task 5: UDP sender and strip renderer in the daemon

**Files:**
- Modify: `kbstatus/main.swift`, `kbstatus/core.swift` (only if a helper turns out pure), `kbstatus/tests/main.swift`

- [x] parse the `strip` block in `UserConfig.load()` into `var strip: StripConfig?`; log the parse reason
      and leave `strip` nil when invalid
- [x] add `StripSender` (main): `getaddrinfo` resolution of `host:port`, `socket`/`sendto`, sequence
      counter, one-time error log and re-resolve no sooner than 60 s after a failed send
- [x] add `renderStrip(_ p: Picture)` to `tick()` after the keyboard branch, gated on `cfg.strip`:
      compute `stripColors`, build a key (status, style, badge, level quantized to 1/64); send when the
      key changed, or style is pulse/blink and ≥ 100 ms since the last send, or ≥ `keepAliveSeconds`
      since the last send while a non-idle state is shown; idle sends once on change only
- [x] the keyboard branch's early `return`s must not skip the strip: restructure `tick()` so the
      keyboard renderer is a function returning early on its own, then the strip renderer runs
- [x] `kbstatus status` prints the strip line; daemon startup logs `strip: <host> resolved to <ip>,
      <N> LEDs` or the parse/resolve failure
- [x] write tests for the pure parts: the send-decision function (`shouldSendStrip(prev:now:style:
      elapsed:keepAlive:)`) covering change/pulse/keep-alive/idle cases; `UserConfig`-level parse of a
      dict with and without a `strip` block (extract the block parsing into a pure function if needed)
- [x] run `kbstatus/test.sh` - must pass; rebuild, reinstall, confirm the keyboard still behaves and
      that with no `strip` block nothing new is logged or sent, before task 6

### Task 6: Fake WLED receiver and the strip-test command

**Files:**
- Create: `probe/ddp-fake.py`
- Modify: `kbstatus/main.swift`, `README.md` (probe table)

- [x] write `probe/ddp-fake.py`: binds UDP 4048 (port via `--port`), parses the DDP header, validates
      version/push flags, offset 0 and `length == payload size`, prints each frame as one line of
      ANSI 24-bit colored blocks with the sequence number and time since the previous packet; `--leds N`
      warns when the LED count differs; exits on Ctrl-C
- [x] add `kbstatus strip-test [secs]`: standalone (no daemon), reads the `strip` block, sweeps red,
      green, blue across all LEDs, then a badge pattern (badge LEDs 1…N), one frame per second, and
      prints the packet count
- [x] end-to-end on localhost: `strip` block with `"host": "127.0.0.1"`, run `probe/ddp-fake.py`, run
      `kbstatus strip-test 6`, then restart the daemon and drive `SET exp working|done|attention|end`
      through the socket; confirm frames, pulse rate (~10 fps), keep-alive cadence (~1 s) and that idle
      sends exactly one all-off packet
- [x] write tests: none new in Swift for this task beyond keeping Task 5's passing; the fake receiver's
      validation is exercised by the end-to-end run (record the observed output in this plan)
      ➕ observed 2026-09-17 (hooks paused, states driven via the socket, 3 s each): attention and
      working pulses = 54 packets at ~100 ms + 6 at ~200 ms (identical consecutive frames are skipped),
      done = keep-alives at ~1 s, idle = one packet then silence; all packets valid (no WARN), sequence
      1..15 wrapping. `strip-test` sweep = 14 valid packets.
      ⚠️ found and fixed: with the strip rendered from tick(), a full-board keyboard frame (7 BT reports,
      ~1 s) starved it to ~1 packet/s during attention. The strip now has its own 100 ms CFRunLoopTimer,
      which fires inside the keyboard code's run-loop pumps.
- [x] run `kbstatus/test.sh` - must pass before task 7

### Task 7: Verify acceptance criteria
- [ ] verify all requirements from Overview are implemented (strip off without config block; DDP
      frames on change / pulse / keep-alive; idle all-off once; badge bar; brightness)
- [ ] verify edge cases are handled (unresolvable host, unreachable host, invalid ranges, leds > 480,
      badge > badge range, `transport` other than ddp)
- [ ] run full test suite: `kbstatus/test.sh`
- [ ] keyboard regression: transitions, typing through transitions, question → red pulse, badge keys
      light and clear, `kbstatus status`; daemon log shows no new warnings during 10 minutes of normal use
- [ ] `./install.sh` builds and installs from a clean checkout (two-file build)

### Task 8: [Final] Update documentation
- [ ] README: layout table (core/main/tests/test.sh, probe/ddp-fake.py), build commands, a "Strip
      (WLED)" section with the config block, WLED setup steps (flash, LED count, brightness limit, DDP
      on, realtime timeout ≈ 2 s), `strip-test`, and the localhost fake-receiver recipe
- [ ] README "How it works": one paragraph on the picture/renderer split
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Hardware** (buy first; it is the long pole):
- ESP32 board with WLED (ready-made "WLED controller" / bare ESP32 dev board), WS2812B 5 V strip,
  60 LEDs/m, 1 m, USB 5 V ≥ 2 A supply. A longer or brighter strip needs a dedicated 5 V supply.

**WLED setup** (once, in the browser):
- Flash from install.wled.me over USB (a pre-flashed board such as the QuinLED dig2go skips this); join
  Wi-Fi from the captive portal; give it a fixed IP or use its `.local` name. LED settings: LED count
  as cut, data pin, brightness limiter for USB power (dig2go: 3 A max). Sync settings: DDP receiver on
  (port 4048), realtime timeout ≈ 2000 ms.
- RGBW strip (SK6812 RGBW, e.g. the DrZzs dig2go RGBW bundle): set LED type to SK6812 RGBW and
  auto-white mode to "none" so the white LED stays off; the daemon keeps sending RGB DDP frames and WLED
  fills W = 0. No code change.

**Network** (the board lives on the IoT VLAN, the Mac on the main network):
- DDP is unicast UDP to the board's IP on 4048 with no reply, so a stateful main → IoT allow rule
  is enough; confirm the rule is not TCP-only. mDNS does not cross VLANs: use a DHCP reservation
  and put the IP (or a router DNS name) in `strip.host`, not the `.local` name.

**First light**:
- Point `strip.host` at the board, `kbstatus stop`, run `kbstatus strip-test 6`. If dark: run the
  fake receiver on the Mac with `host: 127.0.0.1` to separate daemon from network/board; check WLED's
  info page for incoming realtime packets.

**On-desk tuning** (config only): `brightness`, `keepAliveSeconds` vs WLED's timeout, ranges, whether
the badge bar reads well. Rollback at any point: remove the `strip` block and restart the daemon.

**Later options** (not planned): serial/Adalight transport when the board is on USB; both Macs driving
one strip with an "attention from anyone wins" rule.
