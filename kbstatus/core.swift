// kbstatus core — pure protocol and state types shared by the daemon (main.swift) and the tests
// (tests/main.swift). No I/O, no globals that depend on the environment: everything here is a
// function of its arguments, so it can be pinned by the test binary.

import Foundation

typealias RGB = (UInt8, UInt8, UInt8)

// LED index per key (from KB.ini / PROTOCOL.md)
let keyLED: [String: Int] = [
    "esc":0,"f1":12,"f2":18,"f3":24,"f4":30,"f5":36,"f6":42,"f7":48,"f8":54,"f9":60,"f10":66,"f11":72,"f12":78,"prtsc":84,"scrlk":90,"pause":96,
    "`":1,"1":7,"2":13,"3":19,"4":25,"5":31,"6":37,"7":43,"8":49,"9":55,"0":61,"-":67,"=":73,"bksp":79,"ins":85,"home":91,"pgup":97,
    "tab":2,"q":8,"w":14,"e":20,"r":26,"t":32,"y":38,"u":44,"i":50,"o":56,"p":62,"[":68,"]":74,"\\":80,"del":86,"end":92,"pgdn":98,
    "caps":3,"a":9,"s":15,"d":21,"f":27,"g":33,"h":39,"j":45,"k":51,"l":57,";":63,"'":69,"enter":81,
    "lshift":4,"z":10,"x":16,"c":22,"v":28,"b":34,"n":40,"m":46,",":52,".":58,"/":64,"rshift":82,"up":94,
    "lctrl":5,"lwin":11,"lalt":17,"space":35,"ralt":53,"fn":59,"app":65,"rctrl":83,"left":89,"down":95,"right":101,
]


// MARK: - keyboard protocol ------------------------------------------------------------------

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func checksummed(_ f: [UInt8]) -> [UInt8] { var g = f; g[19] = UInt8(g[0..<19].reduce(0) { ($0 + Int($1)) & 0xff }); return g }
func frame(_ cmd: UInt8, _ sub: UInt8, _ seq: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var f = [UInt8](repeating: 0, count: 20); f[0] = 0x13; f[1] = cmd; f[2] = sub; f[3] = seq
    for (i, b) in payload.prefix(15).enumerated() { f[4 + i] = b }
    return checksummed(f)
}
/// 28 fragments: R plane (0-8), G plane (9-17), B plane (18-26), trailer (27). 126 LED slots.
func perKeyFrames(_ colors: [RGB]) -> [[UInt8]] {
    let planes: [[UInt8]] = [colors.map { $0.0 }, colors.map { $0.1 }, colors.map { $0.2 }]
    var out: [[UInt8]] = []
    for (p, vals) in planes.enumerated() {
        for k in 0..<9 { out.append(frame(0x02, 0x1C, UInt8(p * 9 + k), [0x0E] + Array(vals[k*14 ..< k*14+14]))) }
    }
    out.append(frame(0x02, 0x1C, 27, [0x06, 0x00, 0x00, 0x5A, 0xA5]))
    return out
}
/// cmd 0x88 color stream (decoded from OEM captures by the Aula-F87-Controller project):
/// data = repeated groups [R, G, B, count, idx1..idxN], packed 14 bytes per fragment,
/// subcmd = fragment count, byte4 = 0x1E on full fragments, 0x10+len on the last.
/// An empty list yields the idle frame (payload 0x23), which hands the keys back to the per-key map.
func overlayFrames(_ leds: [(UInt8, RGB)]) -> [[UInt8]] {
    var groups: [[UInt8]: [UInt8]] = [:]
    for (led, c) in leds where c.0 != 0 || c.1 != 0 || c.2 != 0 { groups[[c.0, c.1, c.2], default: []].append(led) }
    if groups.isEmpty { return [frame(0x88, 0x01, 0, [0x23])] }
    var data: [UInt8] = []
    for (rgb, idx) in groups.sorted(by: { $0.value.count > $1.value.count }) { data += rgb + [UInt8(idx.count)] + idx }
    let chunks = stride(from: 0, to: data.count, by: 14).map { Array(data[$0 ..< min($0 + 14, data.count)]) }.prefix(14)
    return chunks.enumerated().map { (i, ch) in
        frame(0x88, UInt8(chunks.count), UInt8(i), [(i == chunks.count - 1) ? 0x10 + UInt8(ch.count) : 0x1E] + ch)
    }
}
func scaled(_ c: RGB, _ level: Double) -> RGB {
    func f(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, Int(Double(v) * level + 0.5)))) }
    return (f(c.0), f(c.1), f(c.2))
}
/// Config write frames switching to `effect` (21 = per-key). Confirm flag set, apply flag cleared.
func configFrames(_ original: [[UInt8]], effect: UInt8, colorMode: UInt8) -> [[UInt8]] {
    original.enumerated().map { (i, f0) in
        var f = f0; f[1] = 0x04
        if i == 0 { f[8] = 0x01; f[14] = 0x00; f[15] = effect; f[17] = colorMode }
        return checksummed(f)
    }
}

func solidMap(_ c: RGB) -> [RGB] { [RGB](repeating: c, count: 126) }

// MARK: - state types ----------------------------------------------------------------------

enum Status: String { case idle, working, done, attention }
struct SessionState { var status: Status; var since: Date }

// MARK: - picture ----------------------------------------------------------------------------

/// What every output should show at one instant. Computed once per tick from the session table,
/// the agterm badge count and the clock; each renderer (keyboard, strip) turns it into frames.
struct Picture { var status: Status; var style: String; var badge: Int; var t: Double }

/// Style a status is drawn in: working and attention are configurable, done is always solid,
/// idle has nothing to draw (its style is irrelevant).
func styleFor(_ s: Status, working: String, attention: String) -> String {
    s == .working ? working : s == .attention ? attention : "static"
}
/// Cosine pulse between `floor` and 1, `hz` cycles per second, phase-locked to the clock.
func pulseLevel(t: Double, hz: Double, floor: Double) -> Double {
    floor + (1 - floor) * (0.5 - 0.5 * cos(2 * .pi * hz * t))
}
/// A pulse needs at least 4 frames per cycle to look like one (2 Hz sampled at 2 fps is flicker).
func cappedHz(nominal: Double, fps: Double) -> Double { min(nominal, fps / 4) }
let nominalPulseHz: [Status: Double] = [.attention: 2.0, .working: 0.8]
