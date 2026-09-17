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

// MARK: - strip (WLED over DDP) -------------------------------------------------------------

/// The `strip` block of config.json.
struct StripConfig {
    var host: String
    var port: UInt16 = 4048
    var leds: Int
    var statusRange: ClosedRange<Int>          // LEDs that show the status color
    var badgeRange: ClosedRange<Int>? = nil    // LEDs that show the agterm badge count, one per badge from the start
    var brightness: Double = 0.6               // 0...1, scales every color
    var badgeWidth = 1                         // LEDs per badge (dense strips: 2-3 make a badge readable)
    var keepAliveSeconds: Double = 1.0         // re-send a solid state this often (WLED leaves realtime mode after its timeout)
    var transport = "ddp"                      // only "ddp" for now; "serial" is reserved

    static let maxLeds = 480

    /// Parses the block; on rejection returns nil and the reason.
    static func parse(_ j: [String: Any]) -> (StripConfig?, String?) {
        guard let host = j["host"] as? String, !host.isEmpty else { return (nil, "strip.host missing") }
        guard let leds = j["leds"] as? Int, leds >= 1, leds <= maxLeds else { return (nil, "strip.leds must be 1...\(maxLeds)") }
        func range(_ key: String) -> (ClosedRange<Int>?, String?) {
            guard let v = j[key] else { return (nil, nil) }
            guard let a = v as? [Int], a.count == 2, a[0] <= a[1], a[0] >= 0, a[1] < leds else { return (nil, "strip.\(key) must be [first, last] within 0...\(leds - 1)") }
            return (a[0]...a[1], nil)
        }
        let (sr, e1) = range("statusRange"); if let e = e1 { return (nil, e) }
        let (br, e2) = range("badgeRange"); if let e = e2 { return (nil, e) }
        let status = sr ?? 0...(leds - 1)
        if let b = br, status.overlaps(b) { return (nil, "strip.statusRange and strip.badgeRange overlap") }
        var c = StripConfig(host: host, leds: leds, statusRange: status, badgeRange: br)
        if let p = j["port"] as? Int { guard p >= 1, p <= 65535 else { return (nil, "strip.port out of range") }; c.port = UInt16(p) }
        if let b = j["brightness"] as? Double { c.brightness = max(0, min(1, b)) }
        if let w = j["badgeWidth"] as? Int { guard w >= 1 else { return (nil, "strip.badgeWidth must be >= 1") }; c.badgeWidth = w }
        if let k = j["keepAliveSeconds"] as? Double { c.keepAliveSeconds = max(0.2, k) }
        if let t = j["transport"] as? String { c.transport = t }
        guard c.transport == "ddp" else { return (nil, "strip.transport \"\(c.transport)\" not supported (only ddp)") }
        return (c, nil)
    }
}

struct StatusColors { var working: RGB; var done: RGB; var attention: RGB; var badge: RGB }

/// The strip's colors for a picture: status LEDs in the state color at the pulse level, badge LEDs
/// lit one per badge, everything else off, all scaled by brightness. `fps` is the rate the strip is
/// refreshed at while pulsing (it caps the pulse rate like on the keyboard).
func stripColors(_ p: Picture, _ cfg: StripConfig, _ colors: StatusColors, floor: Double, fps: Double = 10) -> [RGB] {
    var out = [RGB](repeating: (0, 0, 0), count: cfg.leds)
    let color: RGB? = { switch p.status { case .working: return colors.working; case .done: return colors.done; case .attention: return colors.attention; case .idle: return nil } }()
    if let c = color {
        let level: Double
        switch p.style {
        case "pulse": level = pulseLevel(t: p.t, hz: cappedHz(nominal: nominalPulseHz[p.status] ?? 0.8, fps: fps), floor: floor)
        case "blink": level = p.t.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1 : 0
        default: level = 1
        }
        let lit = scaled(c, level)
        for i in cfg.statusRange { out[i] = lit }
    }
    if let br = cfg.badgeRange, p.badge > 0 {
        for i in br.lowerBound ..< br.lowerBound + min(p.badge * cfg.badgeWidth, br.count) { out[i] = colors.badge }
    }
    return cfg.brightness == 1 ? out : out.map { scaled($0, cfg.brightness) }
}

// MARK: - DDP packets --------------------------------------------------------------------------
// Distributed Display Protocol as WLED receives it on UDP 4048: a 10-byte header + RGB bytes.
// Byte 0 = flags (0x40 version 1, 0x01 push = show this frame now), byte 1 = sequence (1...15,
// 0 = unused), byte 2 = data type (0x0B = RGB, 8 bits per channel), byte 3 = destination id
// (1 = default output), bytes 4-7 = channel offset (big-endian), bytes 8-9 = data length (big-endian).

let ddpFlagsVersion1: UInt8 = 0x40, ddpFlagsPush: UInt8 = 0x01, ddpTypeRGB8: UInt8 = 0x0B, ddpDestinationDefault: UInt8 = 0x01
let ddpChannelsPerPacket = 480   // WLED's own sender splits at 480 channels (160 RGB LEDs); the receiver accepts up to 1440

/// One DDP packet carrying `colors` starting at LED `offset`. `push` marks the last packet of a frame.
func ddpPacket(_ colors: ArraySlice<RGB>, offset: Int, sequence: UInt8, push: Bool = true) -> [UInt8] {
    let length = colors.count * 3, chOffset = offset * 3
    var p: [UInt8] = [ddpFlagsVersion1 | (push ? ddpFlagsPush : 0), sequence & 0x0F, ddpTypeRGB8, ddpDestinationDefault,
                      UInt8((chOffset >> 24) & 0xFF), UInt8((chOffset >> 16) & 0xFF), UInt8((chOffset >> 8) & 0xFF), UInt8(chOffset & 0xFF),
                      UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
    p.reserveCapacity(10 + length)
    for c in colors { p.append(c.0); p.append(c.1); p.append(c.2) }
    return p
}
/// A whole frame: one packet per 160 LEDs, push set on the last one, all sharing `sequence`.
func ddpFrame(_ colors: [RGB], sequence: UInt8) -> [[UInt8]] {
    let per = ddpChannelsPerPacket / 3
    if colors.isEmpty { return [ddpPacket([], offset: 0, sequence: sequence)] }
    let starts = stride(from: 0, to: colors.count, by: per)
    return starts.map { s in ddpPacket(colors[s ..< min(s + per, colors.count)], offset: s, sequence: sequence, push: s + per >= colors.count) }
}

/// Whether the strip needs a packet now. `changed`: the colors differ from the last frame sent
/// (a pulse changes every tick, so animation needs no special case); `dark`: nothing to show
/// (idle without badges) - sent once when it changes, then silence so WLED's realtime timeout
/// keeps the strip dark; otherwise a keep-alive every `keepAlive` seconds so WLED stays in
/// realtime mode while a solid state is shown.
func shouldSendStrip(changed: Bool, dark: Bool, elapsed: Double, keepAlive: Double) -> Bool {
    if changed { return true }
    if dark { return false }
    return elapsed >= keepAlive
}
