// kbstatus — drive AULA F87 Pro (Bluetooth) RGB as a Claude Code status indicator.
// Build: xcrun swiftc -O -o kbstatus core.swift main.swift   (core.swift holds the pure protocol code)
//
//   kbstatus working|done|attention|idle|end   (client; session id read from hook JSON on stdin)
//   kbstatus status | stop | restore | daemon | read-config
//
// Design: the keyboard is kept in per-key mode (effect 21). A black per-key map is written once
// per connection (a map transfer freezes key scanning for its whole ~1.4 s, so only after a
// pause in typing). Every status is painted onto the indicator keys with the cmd 0x88 color
// stream: 2 reports, never blocks key input; solid states are re-sent every 1.5 s because the
// keyboard leaves stream mode a few seconds after the last frame. The keyboard sleeps on key
// inactivity (~1 min) and drops everything until the next key; the next refresh repaints it.
// Nothing is ever saved to flash and built-in effects are never switched (that crashes BLE).

import Foundation
import IOKit.hid

// MARK: - paths / config -------------------------------------------------------------------

let home = NSHomeDirectory()
let cfgDir = home + "/.config/kbstatus"
let cacheDir = home + "/.cache/kbstatus"
let sockPath = cacheDir + "/sock"
let logPath = cacheDir + "/daemon.log"
let configHexPath = cfgDir + "/config.hex"      // cached 10 config fragments read from keyboard
let userConfigPath = cfgDir + "/config.json"
try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: logPath, atomically: true, encoding: .utf8) }
}

struct UserConfig {
    var indicatorKeys = ["esc","f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12"]
    var solidKeys: [String]? = nil        // keys painted by solid (static) states; default = indicatorKeys; "all" = every key (7 reports per frame instead of 2)
    var attentionKeys: [String]? = nil    // keys painted by the attention state (any style); default = indicatorKeys; "all" = every key
    var workingKeys: [String]? = nil      // keys painted by the working state (any style); default = indicatorKeys; "all" = every key
    var working: RGB = (0, 90, 255)
    var done: RGB = (0, 255, 40)
    var attention: RGB = (255, 0, 0)
    var rest: RGB = (0, 0, 0)             // non-indicator keys while a status is shown (off)
    var idle: RGB = (0, 0, 0)             // whole board when no session is active (off)
    var doneHoldSeconds = 90.0            // "done" fades to idle after this
    var doneClearsOnTyping = true         // ...or as soon as a key is pressed after Claude finished (agterm-style)
    var workingTimeoutMinutes = 20.0      // a silent "working" session is dropped after this
    var pulseFloor = 0.25                 // pulse dims to this fraction of the color
    var attentionStyle = "pulse"          // pulse (0x88 color stream) | blink (1 s period) | static
    var workingStyle: String? = nil       // pulse | static; default static on the BT-classic link (PID 0xFA08), pulse elsewhere
    var skipConfigWrite = false           // never send the 0x04 config write (some links drop BT on it; keyboard must already be in effect 21)
    var streamFps = 5.0                   // pulse frame rate; lower = less Bluetooth traffic (keystrokes stall when the link is saturated)
    var echoWaitMs = 0.0                  // >0: after each report wait up to this for the keyboard's echo instead of a fixed gap (BT classic loses fragments otherwise)
    var typingHoldSeconds = 1.0           // the background map is not written until this long after the last keystroke (0 = off)
    var mapQuietSeconds = 10.0            // ...and never within this many seconds of a keystroke (a map transfer freezes key scanning ~1.4 s)
    var skipBackgroundMap = false         // the keyboard's own per-key map is already the idle color: never write a map at all
    var overlayRefreshSeconds = 1.5       // solid states are re-sent this often (the keyboard leaves stream mode a few seconds after the last frame)
    var streamGapMs: Double? = nil        // pacing between the fragments of a 0x88 frame (they are never echoed); default = echoWaitMs, or 4 ms on BLE
    var agtermBadge = false               // light number keys for agterm sessions with unseen notifications (polls agtermctl)
    var badgeKeys = ["1","2","3","4","5","6","7","8","9"]
    var badgeColor: RGB = (255, 0, 0)
    var badgeCount = "sessions"           // sessions (one key per session with a badge) | notifications (sum of badges)
    var badgePollSeconds = 2.0
    var agtermctlPath = "/opt/homebrew/bin/agtermctl"
    var vendorID = 0x3554, productID = 0xFA07

    static func load() -> UserConfig {
        var c = UserConfig()
        guard let d = FileManager.default.contents(atPath: userConfigPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
        func rgb(_ k: String) -> RGB? { if let a = j[k] as? [Int], a.count == 3 { return (UInt8(a[0]), UInt8(a[1]), UInt8(a[2])) }; return nil }
        if let k = j["indicatorKeys"] as? [String] { c.indicatorKeys = k.map { $0.lowercased() } }
        if let k = j["solidKeys"] as? [String] { c.solidKeys = k.map { $0.lowercased() } }
        if let k = j["solidKeys"] as? String, k.lowercased() == "all" { c.solidKeys = Array(keyLED.keys) }
        if let k = j["attentionKeys"] as? [String] { c.attentionKeys = k.map { $0.lowercased() } }
        if let k = j["attentionKeys"] as? String, k.lowercased() == "all" { c.attentionKeys = Array(keyLED.keys) }
        if let k = j["workingKeys"] as? [String] { c.workingKeys = k.map { $0.lowercased() } }
        if let k = j["workingKeys"] as? String, k.lowercased() == "all" { c.workingKeys = Array(keyLED.keys) }
        c.working = rgb("working") ?? c.working; c.done = rgb("done") ?? c.done
        c.attention = rgb("attention") ?? c.attention; c.rest = rgb("rest") ?? c.rest; c.idle = rgb("idle") ?? c.idle
        if let v = j["doneHoldSeconds"] as? Double { c.doneHoldSeconds = v }
        if let v = j["doneClearsOnTyping"] as? Bool { c.doneClearsOnTyping = v }
        if let v = j["workingTimeoutMinutes"] as? Double { c.workingTimeoutMinutes = v }
        if let v = j["pulseFloor"] as? Double { c.pulseFloor = v }
        if let v = j["attentionStyle"] as? String { c.attentionStyle = v }
        if let v = j["skipConfigWrite"] as? Bool { c.skipConfigWrite = v }
        if let v = j["echoWaitMs"] as? Double { c.echoWaitMs = v }
        if let v = j["streamFps"] as? Double { c.streamFps = max(0.5, v) }
        if let v = j["typingHoldSeconds"] as? Double { c.typingHoldSeconds = v }
        if let v = j["mapQuietSeconds"] as? Double { c.mapQuietSeconds = v }
        if let v = j["skipBackgroundMap"] as? Bool { c.skipBackgroundMap = v }
        if let v = j["overlayRefreshSeconds"] as? Double { c.overlayRefreshSeconds = max(0.5, v) }
        if let v = j["streamGapMs"] as? Double { c.streamGapMs = v }
        if let v = j["productID"] as? Int { c.productID = v }
        if let v = j["agtermBadge"] as? Bool { c.agtermBadge = v }
        if let k = j["badgeKeys"] as? [String] { c.badgeKeys = k.map { $0.lowercased() } }
        c.badgeColor = rgb("badgeColor") ?? c.badgeColor
        if let v = j["badgeCount"] as? String { c.badgeCount = v }
        if let v = j["badgePollSeconds"] as? Double { c.badgePollSeconds = max(0.5, v) }
        if let v = j["agtermctlPath"] as? String { c.agtermctlPath = v }
        if let v = j["workingStyle"] as? String { c.workingStyle = v }
        return c
    }
    var effectiveWorkingStyle: String { workingStyle ?? (productID == 0xFA08 ? "static" : "pulse") }
}
let cfg = UserConfig.load()
let indicatorLEDs: [UInt8] = cfg.indicatorKeys.compactMap { keyLED[$0] }.map { UInt8($0) }
let solidLEDs: [UInt8] = (cfg.solidKeys ?? cfg.indicatorKeys).compactMap { keyLED[$0] }.map { UInt8($0) }.sorted()
let attentionLEDs: [UInt8] = (cfg.attentionKeys ?? cfg.indicatorKeys).compactMap { keyLED[$0] }.map { UInt8($0) }.sorted()
let workingLEDs: [UInt8] = (cfg.workingKeys ?? cfg.indicatorKeys).compactMap { keyLED[$0] }.map { UInt8($0) }.sorted()
let badgeLEDs: [UInt8] = cfg.badgeKeys.compactMap { keyLED[$0] }.map { UInt8($0) }   // in order: key 1 lights first

// MARK: - keyboard config cache ------------------------------------------------------------

func loadConfigHex() -> [[UInt8]]? {
    guard let txt = try? String(contentsOfFile: configHexPath, encoding: .utf8) else { return nil }
    var cfgf = [[UInt8]?](repeating: nil, count: 10)
    for line in txt.split(separator: "\n") {
        let b = line.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        if b.count == 20, b[1] == 0x44, b[3] < 10 { cfgf[Int(b[3])] = b }
    }
    return cfgf.compactMap { $0 }.count == 10 ? cfgf.map { $0! } : nil
}
// MARK: - HID device -----------------------------------------------------------------------

var device: IOHIDDevice? = nil
var rxLog: [[UInt8]] = []
var rxLast: [UInt8] = []                   // last report 0x13 received (the keyboard echoes each fragment)
var rxSeq = 0
var rxBuf = [UInt8](repeating: 0, count: 64)
var needFullApply = true

func pump(_ s: Double) { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, s, false) }
@discardableResult
func send(_ f: [UInt8]) -> Bool {
    guard let d = device else { return false }
    let r = f.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x13, $0.baseAddress!, $0.count) }
    if r != kIOReturnSuccess { log(String(format: "SetReport failed 0x%08x", r)); return false }
    return true
}
/// Sends frames back to back. With `abortOnTyping` a long write is abandoned as soon as the user
/// touches a key (the per-key map only applies on its trailer, so a partial write is harmless).
/// With `verify` (needs echoWaitMs > 0) each fragment must be echoed back verbatim by the keyboard
/// within echoWaitMs or it is resent, up to 3 tries; the BT-classic link drops fragments silently.
var lastEchoStats = ""                     // "max N ms, R resent" for the last verified write (for the log)
var unechoed: (frame: [UInt8], at: Double)? = nil   // last fragment that got no echo (link asleep?)
func sendAll(_ frames: [[UInt8]], gap: Double = 0.004, abortOnTyping: Bool = false, verify: Bool = false, spacing: Double = 0) -> Bool {
    var resent = 0, maxWait = 0.0
    for (i, f) in frames.enumerated() {
        if i > 0, spacing > 0 { pump(spacing) }
        if abortOnTyping && typingActive() { if i > 0 { log("map write abandoned at fragment \(i): typing") }; return false }
        var tries = 0
        while true {
            let s0 = rxSeq
            if !send(f) { return false }
            var echoed = false
            if cfg.echoWaitMs > 0 {
                var waited = 0.0
                let limit = (verify ? max(cfg.echoWaitMs, 150) : cfg.echoWaitMs) / 1000
                while waited < limit {
                    pump(0.005); waited += 0.005
                    if rxSeq != s0, !verify || rxLast == f { echoed = true; break }
                }
                maxWait = max(maxWait, waited)
            } else { pump(gap) }
            tries += 1
            if verify && cfg.echoWaitMs > 0 && !echoed && tries < 2 { resent += 1; continue }
            if verify && cfg.echoWaitMs > 0 && !echoed {
                unechoed = (f, CFAbsoluteTimeGetCurrent())
                log("fragment not echoed after \(tries) tries: \(hex(f))"); return false
            }
            break
        }
    }
    unechoed = nil
    lastEchoStats = String(format: "echo max %.0f ms, %d resent", maxWait * 1000, resent)
    return true
}

func attachInputCallback(_ d: IOHIDDevice) {
    IOHIDDeviceRegisterInputReportCallback(d, &rxBuf, rxBuf.count, { _, _, _, _, id, data, len in
        if id == 0x13 {
            let b = Array(UnsafeBufferPointer(start: data, count: len))
            rxLog.append(b); if rxLog.count > 64 { rxLog.removeFirst(rxLog.count - 64) }
            rxLast = Array(b.prefix(20)); rxSeq &+= 1; lastInputAt = CFAbsoluteTimeGetCurrent()
        }
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}
func usagePage(_ d: IOHIDDevice) -> Int { (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0 }
/// Prefer a vendor collection if the keyboard exposes one; the BT-classic F87 Pro exposes a single
/// keyboard collection (page 1, usage 6) that carries report 0x13 as well.
func pickDevice(_ set: Set<IOHIDDevice>) -> IOHIDDevice? { set.first { usagePage($0) == 0xFF00 } ?? set.first }

func openDevice(_ d: IOHIDDevice) -> Bool {
    let r = IOHIDDeviceOpen(d, 0)
    if r != kIOReturnSuccess { log(String(format: "device open failed 0x%08x (Input Monitoring permission?)", r)); return false }
    attachInputCallback(d); device = d; needFullApply = true
    log(String(format: "device attached (usage page 0x%04x)", usagePage(d))); return true
}

func startHIDManager(onArrive: Bool) -> IOHIDManager {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: cfg.vendorID, kIOHIDProductIDKey: cfg.productID] as CFDictionary)
    if onArrive {
        // Reconnect: take whatever collection arrives. The BT-classic F87 Pro exposes only the keyboard
        // collection (page 1), so requiring the vendor page here left the daemon deaf after the first
        // disconnect. pickDevice() still prefers the vendor collection when several are present at startup.
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, d in if device == nil { log("device arrived (usage page \(String(format: "0x%04x", usagePage(d))))"); _ = openDevice(d) } }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, d in
            if let cur = device, cur == d { IOHIDDeviceUnscheduleFromRunLoop(cur, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue); device = nil; log("device removed") }
        }, nil)
    }
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    _ = IOHIDManagerOpen(mgr, 0)
    if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
        log("HID collections: " + set.map { String(format: "page 0x%04x usage 0x%02x", usagePage($0), (IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0) }.joined(separator: ", "))
        if device == nil, let d = pickDevice(set) { _ = openDevice(d) }
    }
    return mgr
}

// MARK: - typing monitor ---------------------------------------------------------------------
// The keyboard stops scanning keys while it digests an output report, so over Bluetooth every
// LED write is felt as a typing stall. Watch the keyboard's own key collection (non-exclusive,
// covered by the same Input Monitoring grant) and hold all writes while keys are active.

var lastKeyActivity = 0.0
var wasTyping = false
var lastInputAt = 0.0                      // any report from the keyboard (echo or key): proof the link is awake
var asleepSince = 0.0
/// After a fragment gets no echo the keyboard is asleep (it sleeps ~1 min after the last key and
/// drops every report until the next key). Only the background map is echo-verified, so this just
/// keeps the map from being retried every 2 s: wait for input from the keyboard, re-probe every 20 s.
func linkAsleep() -> Bool {
    guard let u = unechoed else { asleepSince = 0; return false }
    let t = CFAbsoluteTimeGetCurrent()
    if lastInputAt > u.at { unechoed = nil; asleepSince = 0; log("keyboard awake again (input after \(String(format: "%.1f", lastInputAt - u.at)) s)"); return false }
    if asleepSince == 0 { asleepSince = t; log("no echo; keyboard asleep, background map deferred") }
    if t - asleepSince >= 20 { asleepSince = 0; unechoed = nil; nextMapAttempt = 0; return false }   // probe again
    return true
}
func typingActive() -> Bool {
    guard cfg.typingHoldSeconds > 0 else { return false }
    let t = CFAbsoluteTimeGetCurrent(), active = t - lastKeyActivity < cfg.typingHoldSeconds
    if active != wasTyping { wasTyping = active }
    return active
}
func startTypingMonitor() -> IOHIDManager {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: cfg.vendorID, kIOHIDProductIDKey: cfg.productID,
                                        kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06] as CFDictionary)
    IOHIDManagerRegisterInputValueCallback(mgr, { _, _, _, v in
        let page = IOHIDElementGetUsagePage(IOHIDValueGetElement(v))
        lastInputAt = CFAbsoluteTimeGetCurrent()
        if page == 0x07 || page == 0x0C { lastKeyActivity = lastInputAt }   // keys / media keys; our 0x13 echoes arrive on page 0xFF02
    }, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(mgr, 0)
    if r != kIOReturnSuccess { log(String(format: "typing monitor open failed 0x%08x; writes will not pause for typing", r)) }
    let n = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.count ?? 0
    log("typing monitor: \(n) key collection(s), hold \(cfg.typingHoldSeconds) s")
    return mgr
}

/// Read the 10 config fragments. BLE drops fragments and goes quiet after ~2 reads per connection,
/// so reopen the device between attempts and accumulate.
func readConfigFromKeyboard(maxTries: Int = 12) -> [[UInt8]]? {
    guard let d = device else { return nil }
    var cfgf = [[UInt8]?](repeating: nil, count: 10)
    for attempt in 1...maxTries {
        rxLog.removeAll(); send(frame(0x44, 0x01, 0, [])); pump(1.2)
        for r in rxLog where r.count >= 20 && r[1] == 0x44 && r[2] == 0x0A && r[3] < 10 { cfgf[Int(r[3])] = r }
        let missing = (0..<10).filter { cfgf[$0] == nil }
        print("  read attempt \(attempt): missing \(missing)")
        if missing.isEmpty { break }
        IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(d, 0); pump(0.5); _ = IOHIDDeviceOpen(d, 0); attachInputCallback(d); pump(0.5)
    }
    guard cfgf.compactMap({ $0 }).count == 10 else { return nil }
    let full = cfgf.map { $0! }
    try? full.map { hex($0) }.joined(separator: "\n").write(toFile: configHexPath, atomically: true, encoding: .utf8)
    return full
}

// MARK: - state ----------------------------------------------------------------------------

var sessions: [String: SessionState] = [:]
let stateLock = NSLock()
var pendingCommands: [String] = []
var stopRequested = false

func composite() -> Status {
    let now = Date()
    for (id, s) in sessions {
        if s.status == .done, now.timeIntervalSince(s.since) > cfg.doneHoldSeconds { sessions[id] = nil }
        if s.status == .done, cfg.doneClearsOnTyping, lastKeyActivity > s.since.timeIntervalSinceReferenceDate + 0.5 { sessions[id] = nil; log("session \(id) done cleared by typing") }
        if s.status == .working, now.timeIntervalSince(s.since) > cfg.workingTimeoutMinutes * 60 { sessions[id] = nil }
    }
    let st = sessions.values.map { $0.status }
    if st.contains(.attention) { return .attention }
    if st.contains(.working) { return .working }
    if st.contains(.done) { return .done }
    return .idle
}
func indicators(_ c: RGB) -> [(UInt8, RGB)] { indicatorLEDs.map { ($0, c) } }
func solid(_ c: RGB) -> [(UInt8, RGB)] { solidLEDs.map { ($0, c) } }
/// Keys a state paints: attention and working have their own sets (default: indicatorKeys); done uses solidKeys.
func leds(for s: Status, _ c: RGB) -> [(UInt8, RGB)] {
    let set = s == .attention ? attentionLEDs : s == .working ? workingLEDs : solidLEDs
    return set.map { ($0, c) }
}
/// Frames per second a state can actually get (a 7-fragment frame takes fragments x gap to send).
func effectiveFps(for s: Status) -> Double {
    let gap = (cfg.streamGapMs ?? (cfg.echoWaitMs > 0 ? cfg.echoWaitMs : 4)) / 1000
    let frameTime = Double(overlayFrames(leds(for: s, (1, 1, 1))).count) * gap
    return min(cfg.streamFps, frameTime > 0 ? 1 / frameTime : cfg.streamFps)
}
/// Pulse rate for the keyboard: the nominal one, slowed to the frame rate this key set can get.
func pulseHz(for s: Status) -> Double { cappedHz(nominal: nominalPulseHz[s] ?? 0.8, fps: effectiveFps(for: s)) }
func color(for s: Status) -> RGB? { switch s { case .working: return cfg.working; case .done: return cfg.done; case .attention: return cfg.attention; case .idle: return nil } }
func style(for s: Status) -> String { styleFor(s, working: cfg.effectiveWorkingStyle, attention: cfg.attentionStyle) }
/// The picture for this instant: composite status, its style, the agterm badge count (capped to the badge keys).
func currentPicture() -> Picture {
    stateLock.lock(); let badge = min(badgeCount, badgeLEDs.count); stateLock.unlock()
    let s = composite()
    return Picture(status: s, style: style(for: s), badge: badge, t: CFAbsoluteTimeGetCurrent())
}

// MARK: - agterm badges ---------------------------------------------------------------------
// The number keys mirror agterm's sidebar badges: one red key per session with unseen notifications
// (or the sum of the badges). Polled from `agtermctl` on a background thread; agterm clears a badge
// when the session is selected, so the keys go out by themselves.

var badgeCount = 0                          // protected by stateLock
func runAgtermctl(_ args: [String]) -> Data? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.agtermctlPath); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return p.terminationStatus == 0 ? d : nil
}
func agtermJSON(_ args: [String]) -> [String: Any]? {
    guard let d = runAgtermctl(args), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return j["result"] as? [String: Any]
}
func pollBadges() -> Int {
    var windows = ((agtermJSON(["window", "list", "--json"])?["windows"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    if windows.isEmpty { windows = [""] }
    var sessions = 0, notes = 0
    for w in windows {
        var args = ["tree", "--json"]; if !w.isEmpty { args += ["--window", w] }
        guard let tree = agtermJSON(args)?["tree"] as? [String: Any], let wss = tree["workspaces"] as? [[String: Any]] else { continue }
        for ws in wss { for s in (ws["sessions"] as? [[String: Any]] ?? []) { let u = s["unseen"] as? Int ?? 0; if u > 0 { sessions += 1; notes += u } } }
    }
    return cfg.badgeCount == "notifications" ? notes : sessions
}
func startBadgePoller() {
    guard cfg.agtermBadge else { return }
    guard FileManager.default.isExecutableFile(atPath: cfg.agtermctlPath) else { log("agtermBadge: \(cfg.agtermctlPath) not found; badges disabled"); return }
    log("agtermBadge: polling every \(cfg.badgePollSeconds) s, counting \(cfg.badgeCount), keys \(badgeLEDs)")
    Thread {
        while true {
            let n = pollBadges()
            stateLock.lock(); badgeCount = n; stateLock.unlock()
            Thread.sleep(forTimeInterval: cfg.badgePollSeconds)
        }
    }.start()
}
var appliedBadge = 0
/// Badge keys painted red on top of a state's keys (the state color is removed from those keys).
func withBadge(_ base: [(UInt8, RGB)], _ n: Int) -> [(UInt8, RGB)] {
    guard n > 0 else { return base }
    let lit = Array(badgeLEDs.prefix(n))
    return base.filter { !lit.contains($0.0) } + lit.map { ($0, cfg.badgeColor) }
}

var appliedStatus: Status? = nil          // status currently painted on the indicator keys
var backgroundApplied = false             // black per-key map written on this connection
var lastOverlayWrite = 0.0
var nextMapAttempt = 0.0                  // backoff after a failed/abandoned map write (never retry in a tight loop)
var lastConfigApply = Date.distantPast
let daemonStart = CFAbsoluteTimeGetCurrent()

func ensurePerKeyMode() -> Bool {
    guard needFullApply else { return true }
    guard let orig = loadConfigHex() ?? readConfigFromKeyboard() else { log("no config fragments; cannot enter per-key mode"); return false }
    if cfg.skipConfigWrite { log("config write skipped (skipConfigWrite; cached config reports effect \(orig[0][15]))") }
    else if !sendAll(configFrames(orig, effect: 21, colorMode: 0x01), gap: 0.02) { return false }
    else { log("per-key mode applied") }
    needFullApply = false; lastConfigApply = Date(); backgroundApplied = cfg.skipBackgroundMap; appliedStatus = nil
    return true
}
/// Paint the indicator keys with the 0x88 stream: 2 reports, instant, never blocks key input.
/// The keyboard drops out of stream mode a few seconds after the last frame, so solid states
/// are re-sent every overlayRefreshSeconds.
func writeOverlay(_ leds: [(UInt8, RGB)]) -> Bool {
    lastOverlayWrite = CFAbsoluteTimeGetCurrent()   // interval counts from the frame start: a 7-fragment frame takes ~0.4 s to send
    let gap = (cfg.streamGapMs ?? (cfg.echoWaitMs > 0 ? cfg.echoWaitMs : 4)) / 1000
    for f in overlayFrames(leds) { if !send(f) { return false }; pump(gap) }
    return true
}
func tick() {
    stateLock.lock(); let cmds = pendingCommands; pendingCommands.removeAll(); stateLock.unlock()
    for c in cmds { handle(c) }
    if stopRequested { CFRunLoopStop(CFRunLoopGetMain()); return }
    guard device != nil, !linkAsleep(), ensurePerKeyMode() else { return }
    let pic = currentPicture()
    renderKeyboard(pic)
}
/// Keyboard renderer: paints the picture with 0x88 overlays (see the design note at the top of the file).
func renderKeyboard(_ pic: Picture) {
    let want = pic.status, st = pic.style, t = pic.t, badge = pic.badge
    // Background map (all keys idle color): written once per connection. A map transfer freezes the
    // keyboard for its whole duration (~1.4 s), so only after 3 s of quiet, verified fragment by fragment.
    if !backgroundApplied, !typingActive(), t - max(lastKeyActivity, daemonStart) >= cfg.mapQuietSeconds, t >= nextMapAttempt, t - lastOverlayWrite >= 0.25 {
        guard sendAll(perKeyFrames(solidMap(cfg.idle)), abortOnTyping: true, verify: true) else { nextMapAttempt = t + 2.0; return }
        backgroundApplied = true; appliedStatus = nil; log("background map applied (\(lastEchoStats))")
    }
    // Indicator keys: overlays for every state, with the agterm badge keys composed into each frame.
    let changed = appliedStatus != want || appliedBadge != badge
    var ok = true
    switch st {
    case "pulse":
        guard let c = color(for: want) else { break }
        if !changed && t - lastOverlayWrite < 1.0 / cfg.streamFps { return }
        let level = pulseLevel(t: t, hz: pulseHz(for: want), floor: cfg.pulseFloor)
        ok = writeOverlay(withBadge(leds(for: want, scaled(c, level)), badge))
    case "blink":
        guard let c = color(for: want) else { break }
        if !changed && t - lastOverlayWrite < 0.5 { return }
        ok = writeOverlay(withBadge(t.truncatingRemainder(dividingBy: 1.0) < 0.5 ? leds(for: want, c) : [], badge))
    default:
        if let c = color(for: want) {
            if !changed && t - lastOverlayWrite < cfg.overlayRefreshSeconds { return }
            ok = writeOverlay(withBadge(leds(for: want, c), badge))
        } else if badge > 0 {                          // idle with badges: just the red number keys, refreshed like a solid state
            if !changed && t - lastOverlayWrite < cfg.overlayRefreshSeconds { return }
            ok = writeOverlay(withBadge([], badge))
        } else if changed { ok = writeOverlay([]) }   // idle frame hands the keys back to the (black) map; no refresh needed
    }
    if ok && changed {
        if appliedStatus != want { log("shown: \(want)") }
        if appliedBadge != badge { log("badge keys: \(badge)") }
        appliedStatus = want; appliedBadge = badge
    }
    if !ok { appliedStatus = nil }
}

func handle(_ line: String) {
    if line == "REMAP" { backgroundApplied = false; return }   // diagnostics: force the background map again
    let parts = line.split(separator: " ").map(String.init)
    guard parts.count >= 2, parts[0] == "SET" else { return }
    let sid = parts[1], verb = parts.count > 2 ? parts[2] : ""
    if verb == "end" { sessions[sid] = nil; log("session \(sid) ended"); return }
    if let s = Status(rawValue: verb) {
        if s == .idle { sessions[sid] = nil } else {
            // keep the original timestamp while status is unchanged (working pings shouldn't reset "since" for timeout... they should refresh it)
            sessions[sid] = SessionState(status: s, since: Date())
        }
        log("session \(sid) -> \(s)")
    }
}
func statusText() -> String {
    stateLock.lock(); defer { stateLock.unlock() }
    var s = "device: \(device == nil ? "absent" : "present")\ncomposite: \(composite().rawValue)\nshown: \(appliedStatus?.rawValue ?? "none")\nbackground map: \(backgroundApplied ? "applied" : "pending")\nworking style: \(cfg.effectiveWorkingStyle)\nagterm badges: \(cfg.agtermBadge ? "\(badgeCount)" : "off")\ntyping: \(typingActive() ? "active (writes held)" : "quiet")\n"
    for (id, st) in sessions { s += "  \(id) \(st.status.rawValue) since \(Int(Date().timeIntervalSince(st.since)))s\n" }
    return s
}

// MARK: - unix socket ----------------------------------------------------------------------

func sockaddr(for path: String) -> sockaddr_un {
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in for (i, c) in bytes.enumerated() where i < 103 { p[i] = c } } }
    return addr
}
func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
    var addr = sockaddr(for: sockPath)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if r != 0 { close(fd); return nil }
    return fd
}
func serveSocket() {
    if connectSocket() != nil { fputs("kbstatus daemon already running\n", stderr); exit(0) }
    unlink(sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr(for: sockPath)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard r == 0, listen(fd, 16) == 0 else { log("socket bind/listen failed: \(errno)"); exit(1) }
    Thread {
        while true {
            let c = accept(fd, nil, nil); if c < 0 { continue }
            var buf = [UInt8](repeating: 0, count: 512)
            let n = read(c, &buf, buf.count)
            if n > 0, let line = String(bytes: buf[0..<n], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if line == "STATUS" { let t = statusText(); _ = t.withCString { write(c, $0, strlen($0)) } }
                else if line == "STOP" { stateLock.lock(); stopRequested = true; stateLock.unlock() }
                else if line == "REMAP" { stateLock.lock(); pendingCommands.append("REMAP"); stateLock.unlock() }
                else { stateLock.lock(); pendingCommands.append(line); stateLock.unlock() }
            }
            close(c)
        }
    }.start()
}
func clientSend(_ line: String, expectReply: Bool = false) -> String? {
    guard let fd = connectSocket() else { return nil }
    _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
    var out = ""
    if expectReply { var buf = [UInt8](repeating: 0, count: 4096); let n = read(fd, &buf, buf.count); if n > 0 { out = String(bytes: buf[0..<n], encoding: .utf8) ?? "" } }
    close(fd); return out
}
func spawnDaemon() {
    // Bundle.main knows the real executable; argv[0] is just "kbstatus" when run via PATH and would
    // resolve against the cwd (which once spawned a stale build from the source directory).
    let path = Bundle.main.executablePath ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var attr: posix_spawnattr_t? = nil; posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var fa: posix_spawn_file_actions_t? = nil; posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("daemon"), nil]
    var pid: pid_t = 0
    let r = posix_spawn(&pid, path, &fa, &attr, argv, environ)
    if r != 0 { fputs("failed to spawn daemon: \(r)\n", stderr) }
}

// MARK: - main -----------------------------------------------------------------------------

let args = Array(CommandLine.arguments.dropFirst())
let verb = args.first ?? "help"

func sessionID() -> String {
    if let i = args.firstIndex(of: "--session"), i + 1 < args.count { return args[i + 1] }
    if isatty(0) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let s = j["session_id"] as? String { return String(s.prefix(36)) }
    }
    return "manual"
}

switch verb {
case "working", "done", "attention", "idle", "end":
    if FileManager.default.fileExists(atPath: cacheDir + "/paused") { exit(0) }   // `kbstatus pause` / `resume`
    let line = "SET \(sessionID()) \(verb)"
    if clientSend(line) == nil {
        spawnDaemon()
        var ok = false
        for _ in 0..<40 { usleep(50_000); if clientSend(line) != nil { ok = true; break } }
        if !ok { fputs("kbstatus: daemon not reachable\n", stderr); exit(1) }
    }
case "pause":
    _ = clientSend("STOP"); FileManager.default.createFile(atPath: cacheDir + "/paused", contents: nil); print("paused: hooks are no-ops, daemon stopped")
case "resume":
    unlink(cacheDir + "/paused"); print("resumed: next hook call starts the daemon")
case "status":
    print(clientSend("STATUS", expectReply: true) ?? "daemon not running")
case "stop":
    if clientSend("STOP") == nil { print("daemon not running") } else { print("stop requested") }
case "daemon":
    serveSocket()
    log("daemon starting (pid \(getpid())) indicator LEDs: \(indicatorLEDs); solid states paint \(solidLEDs.count) keys (\(overlayFrames(solid((1, 1, 1))).count) reports per frame); attention paints \(attentionLEDs.count) keys at \(String(format: "%.1f", effectiveFps(for: .attention))) fps, pulse \(String(format: "%.2f", pulseHz(for: .attention))) Hz; working paints \(workingLEDs.count) keys, pulse \(String(format: "%.2f", pulseHz(for: .working))) Hz")
    let mgr = startHIDManager(onArrive: true)
    let typing = startTypingMonitor()
    startBadgePoller()
    let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.2, 0.1, 0, 0) { _ in tick() }
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.defaultMode)
    CFRunLoopRun()
    // stopping: leave the board in idle colors
    if device != nil { _ = sendAll(overlayFrames([])) }   // keys fall back to the black map
    unlink(sockPath); _ = mgr; _ = typing; log("daemon stopped")
case "restore":
    // Write the keyboard's original (cached) config back. Not saved to flash. Stop the daemon first.
    _ = clientSend("STOP"); usleep(2_500_000)
    _ = startHIDManager(onArrive: false)
    guard device != nil else { print("keyboard not found"); exit(1) }
    guard let orig = loadConfigHex() else { print("no cached config at \(configHexPath)"); exit(1) }
    var f: [[UInt8]] = orig.map { fr in var g = fr; g[1] = 0x04; return checksummed(g) }
    f[0][8] = 0x01; f[0][14] = 0x00; f[0] = checksummed(f[0])
    print(sendAll(f, gap: 0.02) ? "original config written (effect \(orig[0][15]))" : "write failed")
    pump(0.5)
case "bench":   // bench <fps> <secs> [r g b]  — stream a steady color onto the indicator keys (daemon must be paused)
    let fps = Double(args.count > 1 ? args[1] : "4") ?? 4, secs = Double(args.count > 2 ? args[2] : "8") ?? 8
    let c: RGB = args.count > 5 ? (UInt8(args[3]) ?? 0, UInt8(args[4]) ?? 255, UInt8(args[5]) ?? 0) : (0, 255, 0)
    _ = startHIDManager(onArrive: false); guard device != nil else { print("keyboard not found"); exit(1) }
    let t0 = Date(); var n = 0
    while Date().timeIntervalSince(t0) < secs { _ = sendAll(overlayFrames(indicatorLEDs.map { ($0, c) }), gap: 0.002); n += 1; pump(max(0.01, 1.0 / fps - 0.1)) }
    _ = sendAll(overlayFrames([])); print("sent \(n) frames in \(Int(secs))s at ~\(fps) fps")
case "map":     // map r g b | map off  — write a per-key map: indicator keys in that color, rest black (daemon must be paused)
    _ = startHIDManager(onArrive: false); guard device != nil else { print("keyboard not found"); exit(1) }
    var m = solidMap((0, 0, 0))
    if args.count > 3, let r = UInt8(args[1]), let g = UInt8(args[2]), let b = UInt8(args[3]) { for l in indicatorLEDs { m[Int(l)] = (r, g, b) } }
    let t0 = Date(); let ok = sendAll(perKeyFrames(m), verify: true); pump(0.3)
    print(ok ? "map written in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, \(rxLog.count) echoes" : "map write failed")
case "clear":   // send the 0x88 idle frame (hands the keys back to the per-key map)
    _ = startHIDManager(onArrive: false); guard device != nil else { print("keyboard not found"); exit(1) }
    print(sendAll(overlayFrames([])) ? "idle frame sent" : "failed"); pump(0.3)
case "read-config":
    _ = startHIDManager(onArrive: false)
    guard device != nil else { print("keyboard not found"); exit(1) }
    if let c = readConfigFromKeyboard() { for f in c { print("  ", hex(f)) }; print("saved to \(configHexPath)") } else { print("read failed") }
default:
    print("""
    kbstatus — AULA F87 Pro RGB status indicator for Claude Code hooks
      kbstatus working|done|attention|idle|end   set this session's state (session id from hook JSON on stdin, or --session ID)
      kbstatus status                            show daemon state
      kbstatus stop                              stop daemon (board goes to idle colors)
      kbstatus pause | resume                    make hook calls no-ops (for experiments) / re-enable
      kbstatus restore                           stop daemon and write the keyboard's original config back
      kbstatus read-config                       re-read config fragments from the keyboard
      kbstatus daemon                            run the daemon in the foreground
    config: \(userConfigPath)   log: \(logPath)
    """)
}
