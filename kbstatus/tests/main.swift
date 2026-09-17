// kbstatus tests — assert-based checks for the pure code in core.swift.
// Run with kbstatus/test.sh (compiles core.swift + this file into a throwaway binary).

import Foundation

var checks = 0, failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL line \(line): \(msg)") }
}
func eq(_ a: RGB, _ b: RGB) -> Bool { a.0 == b.0 && a.1 == b.1 && a.2 == b.2 }
let fRow: [UInt8] = [0, 12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72, 78]
let allKeys: [UInt8] = keyLED.values.sorted().map { UInt8($0) }

// MARK: key map
check(keyLED.count == 87, "key map has 87 keys, got \(keyLED.count)")
check(Set(keyLED.values).count == keyLED.count, "LED indices are unique")
check(keyLED.values.max()! < 126, "LED indices fit the 126-slot per-key map")

// MARK: checksummed / frame
do {
    var f = [UInt8](repeating: 0, count: 20); f[0] = 0x13; f[1] = 0x88; f[2] = 0x01; f[4] = 0x23
    let c = checksummed(f)
    check(c[19] == 0xBF, "idle frame checksum is 0xBF, got \(hex([c[19]]))")
    check(Array(c[0..<19]) == Array(f[0..<19]), "checksummed leaves bytes 0-18 untouched")
    let big = checksummed([UInt8](repeating: 0xFF, count: 20))
    check(big[19] == UInt8((19 * 255) & 0xFF), "checksum wraps modulo 256")
}
do {
    let f = frame(0x02, 0x1C, 5, [0x0E, 1, 2, 3])
    check(f.count == 20, "frame is 20 bytes")
    check(f[0] == 0x13 && f[1] == 0x02 && f[2] == 0x1C && f[3] == 5, "frame header: report id, cmd, sub, seq")
    check(Array(f[4..<8]) == [0x0E, 1, 2, 3] && f[8] == 0, "payload lands at byte 4")
    check(f == checksummed(f), "frame carries a valid checksum")
    let long = frame(0x88, 1, 0, [UInt8](repeating: 0xAA, count: 20))
    check(Array(long[4..<19]) == [UInt8](repeating: 0xAA, count: 15), "payload is capped at 15 bytes")
}

// MARK: perKeyFrames
do {
    var colors = solidMap((0, 0, 0)); colors[7] = (10, 20, 30); colors[125] = (1, 2, 3)
    let fr = perKeyFrames(colors)
    check(fr.count == 28, "per-key map is 28 fragments, got \(fr.count)")
    for (i, f) in fr.enumerated() {
        check(f[0] == 0x13 && f[1] == 0x02 && f[2] == 0x1C && f[3] == UInt8(i), "fragment \(i) header")
        check(f == checksummed(f), "fragment \(i) checksum")
    }
    check(fr[0][4] == 0x0E, "data fragments carry 0x0E at byte 4")
    check(fr[0][5 + 7] == 10, "R plane fragment 0 holds R of LED 7")
    check(fr[9][5 + 7] == 20, "G plane starts at fragment 9")
    check(fr[18][5 + 7] == 30, "B plane starts at fragment 18")
    check(fr[26][5 + 13] == 3, "last data fragment holds LED 125 (B plane)")
    check(Array(fr[27][4..<9]) == [0x06, 0x00, 0x00, 0x5A, 0xA5] && fr[27][3] == 27, "trailer fragment 27 is 06 00 00 5A A5")
}

// MARK: overlayFrames
do {
    let idle = overlayFrames([])
    check(idle.count == 1 && hex(idle[0]) == "13 88 01 00 23 00 00 00 00 00 00 00 00 00 00 00 00 00 00 bf", "empty list yields the idle frame, got \(hex(idle[0]))")
    let black = overlayFrames(fRow.map { ($0, (0, 0, 0)) })
    check(black == idle, "all-black colors yield the idle frame")

    let two = overlayFrames(fRow.map { ($0, (0, 90, 255)) })
    check(two.count == 2, "13 keys in one color fit in 2 fragments, got \(two.count)")
    check(two[0][2] == 2 && two[1][2] == 2, "subcmd = fragment count")
    check(two[0][3] == 0 && two[1][3] == 1, "sequence numbers 0,1")
    check(two[0][4] == 0x1E, "full fragment marker 0x1E")
    check(two[1][4] == 0x10 + 3, "last fragment marker 0x10+len (17 data bytes -> 3 left)")
    check(Array(two[0][5..<9]) == [0, 90, 255, 13], "group header R G B count")
    check(Array(two[0][9..<19]) == Array(fRow[0..<10]) && Array(two[1][5..<8]) == Array(fRow[10..<13]), "indices continue across fragments")
    check(two.allSatisfy { $0 == checksummed($0) }, "overlay fragments carry valid checksums")

    let full = overlayFrames(allKeys.map { ($0, (255, 0, 0)) })
    check(full.count == 7, "87 keys in one color = 91 data bytes = 7 fragments, got \(full.count)")
    check(full[6][4] == 0x10 + 7, "last of 7 fragments holds 7 bytes")

    let mixed = overlayFrames([(7, (255, 0, 0))] + fRow.map { ($0, (0, 255, 0)) })
    check(Array(mixed[0][5..<9]) == [0, 255, 0, 13], "bigger color group is packed first")
    let data = mixed.flatMap { Array($0[5..<19]) }
    check(Array(data[17..<22]) == [255, 0, 0, 1, 7], "second group follows: R G B count idx")

    let many = overlayFrames((0..<60).map { (UInt8($0), (UInt8($0 + 1), 0, 0)) })   // 60 groups x 5 bytes = 300 data bytes
    check(many.count == 14, "frames are truncated to 14 fragments, got \(many.count)")
    check(many[13][2] == 14, "subcmd reflects the truncated count")
}

// MARK: scaled
check(eq(scaled((0, 90, 255), 0.25), (0, 23, 64)), "scaled rounds half up: (0,90,255)*0.25 = (0,23,64)")
check(eq(scaled((255, 128, 1), 1.0), (255, 128, 1)), "scaled by 1 is identity")
check(eq(scaled((255, 200, 0), 2.0), (255, 255, 0)), "scaled clamps at 255")
check(eq(scaled((10, 10, 10), 0.0), (0, 0, 0)), "scaled by 0 is black")
check(eq(scaled((10, 10, 10), 0.05), (1, 1, 1)), "0.5 rounds up to 1")

// MARK: configFrames
do {
    var orig: [[UInt8]] = (0..<10).map { i in var f = [UInt8](repeating: 0, count: 20); f[0] = 0x13; f[1] = 0x44; f[2] = 0x0A; f[3] = UInt8(i); f[15] = 2; f[17] = 3; return checksummed(f) }
    orig[0][8] = 0; orig[0][14] = 1
    let w = configFrames(orig, effect: 21, colorMode: 0x01)
    check(w.count == 10, "config write keeps 10 fragments")
    check(w.allSatisfy { $0[1] == 0x04 && $0 == checksummed($0) }, "all fragments become cmd 0x04 with fresh checksums")
    check(w[0][8] == 1 && w[0][14] == 0 && w[0][15] == 21 && w[0][17] == 0x01, "fragment 0: confirm set, apply cleared, effect, color mode")
    check(w[1][15] == 2 && w[1][17] == 3, "other fragments keep their bytes")
}

// MARK: solidMap
check(solidMap((1, 2, 3)).count == 126 && eq(solidMap((1, 2, 3))[125], (1, 2, 3)), "solidMap fills 126 slots")

// MARK: picture / pulse math
do {
    let floor = 0.25
    check(abs(pulseLevel(t: 0, hz: 2, floor: floor) - floor) < 1e-9, "pulse starts at the floor")
    check(abs(pulseLevel(t: 0.25, hz: 2, floor: floor) - 1) < 1e-9, "pulse peaks at half a period")
    check(abs(pulseLevel(t: 0.5, hz: 2, floor: floor) - floor) < 1e-9, "pulse returns to the floor after one period")
    var inRange = true
    for i in 0..<1000 { let l = pulseLevel(t: Double(i) * 0.0137, hz: 0.8, floor: floor); if l < floor - 1e-9 || l > 1 + 1e-9 { inRange = false } }
    check(inRange, "pulse level never leaves [floor, 1]")
    check(abs(pulseLevel(t: 0.25, hz: 2, floor: 0) - 1) < 1e-9 && abs(pulseLevel(t: 0, hz: 2, floor: 0)) < 1e-9, "floor 0 spans 0...1")

    check(cappedHz(nominal: 2.0, fps: 10) == 2.0, "high fps keeps the nominal rate")
    check(cappedHz(nominal: 2.0, fps: 2.4) == 0.6, "2.4 fps caps the pulse to 0.6 Hz")
    check(cappedHz(nominal: 0.8, fps: 3) == 0.75, "working at 3 fps -> 0.75 Hz")
    check(nominalPulseHz[.attention] == 2.0 && nominalPulseHz[.working] == 0.8 && nominalPulseHz[.done] == nil, "nominal rates: attention 2 Hz, working 0.8 Hz, none for done")

    check(styleFor(.working, working: "pulse", attention: "static") == "pulse", "working takes the working style")
    check(styleFor(.working, working: "static", attention: "pulse") == "static", "working static when configured")
    check(styleFor(.attention, working: "static", attention: "blink") == "blink", "attention takes the attention style")
    check(styleFor(.done, working: "pulse", attention: "pulse") == "static", "done is always static")
    check(styleFor(.idle, working: "pulse", attention: "pulse") == "static", "idle reports static")
    let pic = Picture(status: .attention, style: styleFor(.attention, working: "pulse", attention: "pulse"), badge: 3, t: 12.5)
    check(pic.status == .attention && pic.style == "pulse" && pic.badge == 3 && pic.t == 12.5, "Picture carries status, style, badge, time")
}

// MARK: strip config
do {
    let (c, e) = StripConfig.parse(["host": "10.0.0.5", "leds": 60])
    check(e == nil && c != nil, "minimal strip block parses: \(e ?? "")")
    if let c = c {
        check(c.port == 4048 && c.brightness == 0.6 && c.keepAliveSeconds == 1.0 && c.transport == "ddp", "defaults filled")
        check(c.statusRange == 0...59 && c.badgeRange == nil, "status range defaults to the whole strip, no badge range")
    }
    let (f, _) = StripConfig.parse(["host": "wled.lan", "leds": 60, "statusRange": [0, 49], "badgeRange": [50, 59], "brightness": 1.7, "keepAliveSeconds": 0.05, "port": 5000])
    check(f?.statusRange == 0...49 && f?.badgeRange == 50...59, "ranges parse")
    check(f?.brightness == 1 && f?.keepAliveSeconds == 0.2 && f?.port == 5000, "brightness clamps to 1, keep-alive floors at 0.2 s, port taken")
    func rejects(_ j: [String: Any], _ why: String) { let (c, e) = StripConfig.parse(j); check(c == nil && e != nil, "rejects \(why): \(e ?? "no reason")") }
    rejects(["leds": 60], "missing host")
    rejects(["host": "", "leds": 60], "empty host")
    rejects(["host": "h", "leds": 0], "leds 0")
    rejects(["host": "h", "leds": 481], "leds 481")
    rejects(["host": "h", "leds": 60, "statusRange": [0, 60]], "status range past the end")
    rejects(["host": "h", "leds": 60, "statusRange": [10, 5]], "reversed range")
    rejects(["host": "h", "leds": 60, "statusRange": [0, 30], "badgeRange": [30, 40]], "overlapping ranges")
    rejects(["host": "h", "leds": 60, "transport": "serial"], "serial transport")
    rejects(["host": "h", "leds": 60, "port": 70000], "port out of range")
}

// MARK: strip colors
do {
    let cfg = StripConfig(host: "h", leds: 10, statusRange: 0...6, badgeRange: 7...9, brightness: 1)
    let colors = StatusColors(working: (0, 90, 255), done: (0, 255, 40), attention: (255, 0, 0), badge: (255, 120, 0))
    func pic(_ s: Status, _ style: String, badge: Int = 0, t: Double = 0.25) -> Picture { Picture(status: s, style: style, badge: badge, t: t) }
    let done = stripColors(pic(.done, "static"), cfg, colors, floor: 0.25)
    check(done.count == 10, "one color per LED")
    check((0...6).allSatisfy { eq(done[$0], (0, 255, 40)) } && (7...9).allSatisfy { eq(done[$0], (0, 0, 0)) }, "done: status LEDs green, badge LEDs off")
    let idle = stripColors(pic(.idle, "static"), cfg, colors, floor: 0.25)
    check(idle.allSatisfy { eq($0, (0, 0, 0)) }, "idle: all off")
    let idleBadge = stripColors(pic(.idle, "static", badge: 2), cfg, colors, floor: 0.25)
    check(eq(idleBadge[7], (255, 120, 0)) && eq(idleBadge[8], (255, 120, 0)) && eq(idleBadge[9], (0, 0, 0)) && eq(idleBadge[0], (0, 0, 0)), "idle with 2 badges: first two badge LEDs lit")
    let capped = stripColors(pic(.done, "static", badge: 9), cfg, colors, floor: 0.25)
    check((7...9).allSatisfy { eq(capped[$0], (255, 120, 0)) }, "badge count capped to the badge range")
    let peak = stripColors(pic(.attention, "pulse", t: 0.25), cfg, colors, floor: 0.25)     // 2 Hz at 10 fps -> peak at t = 0.25
    check(eq(peak[0], (255, 0, 0)), "attention pulse at its peak is full red")
    let trough = stripColors(pic(.attention, "pulse", t: 0), cfg, colors, floor: 0.25)
    check(eq(trough[0], (64, 0, 0)), "attention pulse at its floor is 25% red, got \(trough[0])")
    let blinkOn = stripColors(pic(.working, "blink", t: 3.1), cfg, colors, floor: 0.25), blinkOff = stripColors(pic(.working, "blink", t: 3.6), cfg, colors, floor: 0.25)
    check(eq(blinkOn[0], (0, 90, 255)) && eq(blinkOff[0], (0, 0, 0)), "blink: on in the first half second, off in the second")
    var dim = cfg; dim.brightness = 0.5
    let half = stripColors(pic(.done, "static", badge: 1), dim, colors, floor: 0.25)
    check(eq(half[0], (0, 128, 20)) && eq(half[7], (128, 60, 0)), "brightness 0.5 halves status and badge colors, got \(half[0]) \(half[7])")
    var wide = cfg; wide.badgeWidth = 3
    let w2 = stripColors(pic(.idle, "static", badge: 1), wide, colors, floor: 0.25)
    check(eq(w2[7], (255, 120, 0)) && eq(w2[8], (255, 120, 0)) && eq(w2[9], (255, 120, 0)), "badgeWidth 3: one badge lights three LEDs")
    let w3 = stripColors(pic(.idle, "static", badge: 2), wide, colors, floor: 0.25)
    check((7...9).allSatisfy { eq(w3[$0], (255, 120, 0)) } && w3.count == 10, "badgeWidth: capped to the badge range")
    let (bw, _) = StripConfig.parse(["host": "h", "leds": 10, "badgeWidth": 2]); check(bw?.badgeWidth == 2, "badgeWidth parses")
    let (bwBad, bwErr) = StripConfig.parse(["host": "h", "leds": 10, "badgeWidth": 0]); check(bwBad == nil && bwErr != nil, "badgeWidth 0 rejected")
    let noBadgeRange = StripConfig(host: "h", leds: 5, statusRange: 0...2, badgeRange: nil, brightness: 1)
    let nb = stripColors(pic(.done, "static", badge: 3), noBadgeRange, colors, floor: 0.25)
    check(eq(nb[3], (0, 0, 0)) && eq(nb[4], (0, 0, 0)), "without a badge range, badges are not drawn and spare LEDs stay off")
}

// MARK: DDP packets
do {
    let colors: [RGB] = (0..<60).map { (UInt8($0), UInt8(100 + $0), UInt8(200 - $0)) }
    let f = ddpFrame(colors, sequence: 3)
    check(f.count == 1 && f[0].count == 190, "60 LEDs = one packet of 190 bytes, got \(f.count) x \(f[0].count)")
    check(Array(f[0][0..<10]) == [0x41, 3, 0x0B, 0x01, 0, 0, 0, 0, 0x00, 0xB4], "header: ver1|push, seq 3, RGB8, dest 1, offset 0, length 180; got \(hex(Array(f[0][0..<10])))")
    check(Array(f[0][10..<13]) == [0, 100, 200] && Array(f[0][187..<190]) == [59, 159, 141], "RGB bytes in order")
    check(ddpFrame([(1, 2, 3)], sequence: 17)[0][1] == 1, "sequence wraps to 4 bits (17 -> 1)")
    check(ddpFrame([(1, 2, 3)], sequence: 1)[0].count == 13, "1 LED = 13 bytes")
    let empty = ddpFrame([], sequence: 1)
    check(empty.count == 1 && empty[0].count == 10 && empty[0][8] == 0 && empty[0][9] == 0, "0 LEDs = header only, length 0")
    let big = ddpFrame([RGB](repeating: (9, 9, 9), count: 400), sequence: 2)
    check(big.count == 3, "400 LEDs split into 3 packets (160+160+80), got \(big.count)")
    check(big[0][0] == 0x40 && big[1][0] == 0x40 && big[2][0] == 0x41, "push flag only on the last packet")
    check(Array(big[1][4..<8]) == [0, 0, 0x01, 0xE0] && Array(big[1][8..<10]) == [0x01, 0xE0], "second packet: channel offset 480, length 480")
    check(Array(big[2][4..<8]) == [0, 0, 0x03, 0xC0] && Array(big[2][8..<10]) == [0x00, 0xF0], "third packet: offset 960, length 240")
    check(big.allSatisfy { $0[1] == 2 }, "all packets of a frame share the sequence number")
}

// MARK: strip send decision
do {
    check(shouldSendStrip(changed: true, dark: false, elapsed: 0, keepAlive: 1), "a changed frame is sent at once")
    check(shouldSendStrip(changed: true, dark: true, elapsed: 0, keepAlive: 1), "going dark is sent once")
    check(!shouldSendStrip(changed: false, dark: true, elapsed: 5, keepAlive: 1), "dark and unchanged: silence, whatever the elapsed time")
    check(!shouldSendStrip(changed: false, dark: false, elapsed: 0.5, keepAlive: 1), "solid state, unchanged, before the keep-alive: no packet")
    check(shouldSendStrip(changed: false, dark: false, elapsed: 1.0, keepAlive: 1), "solid state: keep-alive at the interval")
    check(shouldSendStrip(changed: false, dark: false, elapsed: 3, keepAlive: 2.5), "keep-alive honours the configured interval")
}

print("\(checks) checks, \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
