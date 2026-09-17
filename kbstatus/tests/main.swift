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

print("\(checks) checks, \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
