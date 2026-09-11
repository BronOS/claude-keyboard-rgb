import Foundation
import IOKit.hid

// ---- frame helpers ----------------------------------------------------------
func hex(_ b:[UInt8])->String{ b.map{String(format:"%02x",$0)}.joined(separator:" ") }
func frame(_ cmd:UInt8,_ sub:UInt8,_ seq:UInt8,_ payload:[UInt8])->[UInt8]{
    var f=[UInt8](repeating:0,count:20); f[0]=0x13; f[1]=cmd; f[2]=sub; f[3]=seq
    for (i,b) in payload.prefix(15).enumerated(){ f[4+i]=b }
    f[19]=UInt8(f[0..<19].reduce(0){($0+Int($1))&0xff}); return f }
func withChecksum(_ f:[UInt8])->[UInt8]{ var g=f; g[19]=UInt8(g[0..<19].reduce(0){($0+Int($1))&0xff}); return g }

// ---- device -----------------------------------------------------------------
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x3554, kIOHIDProductIDKey: 0xFA08] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
_ = IOHIDManagerOpen(mgr, 0)
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else { print("no device"); exit(1) }
let ro = IOHIDDeviceOpen(dev, 0); guard ro == kIOReturnSuccess else { print(String(format:"open failed 0x%08x", ro)); exit(2) }

var rxLog:[[UInt8]] = []
var buf=[UInt8](repeating:0,count:64)
IOHIDDeviceRegisterInputReportCallback(dev,&buf,buf.count,{ _,_,_,_,id,data,len in
    if id == 0x13 { rxLog.append(Array(UnsafeBufferPointer(start:data,count:len))) }
},nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
func pump(_ s:Double){ CFRunLoopRunInMode(CFRunLoopMode.defaultMode, s, false) }
func send(_ f:[UInt8]){
    let r=f.withUnsafeBufferPointer{IOHIDDeviceSetReport(dev,kIOHIDReportTypeOutput,0x13,$0.baseAddress!,$0.count)}
    if r != 0 {print(String(format:"  SetReport err 0x%08x",r))}
}
/// send a fragment and wait briefly for its echo
func sendEcho(_ f:[UInt8], wait:Double = 0.06){ let n=rxLog.count; send(f); var t=0.0; while rxLog.count==n && t<wait { pump(0.01); t+=0.01 } }

// ---- protocol ops -----------------------------------------------------------
/// Read the 10 config fragments, retrying until all present (BLE drops frames).
let cachePath = NSString(string:"~/.cache/kbtest/config.hex").expandingTildeInPath
func loadCache() -> [[UInt8]?] {
    var cfg = [[UInt8]?](repeating:nil, count:10)
    guard let txt = try? String(contentsOfFile:cachePath, encoding:.utf8) else { return cfg }
    for line in txt.split(separator:"\n") {
        let b = line.split(separator:" ").compactMap{UInt8($0,radix:16)}
        if b.count==20, b[3]<10 { cfg[Int(b[3])] = b }
    }
    return cfg
}
func saveCache(_ cfg:[[UInt8]?]) {
    try? FileManager.default.createDirectory(atPath:(cachePath as NSString).deletingLastPathComponent, withIntermediateDirectories:true)
    let txt = cfg.compactMap{$0}.map{hex($0)}.joined(separator:"\n")
    try? txt.write(toFile:cachePath, atomically:true, encoding:.utf8)
}
func readConfig(maxTries:Int = 10) -> [[UInt8]]? {
    var cfg = loadCache()
    if cfg.compactMap({$0}).count == 10 { print("  config from cache"); return cfg.map{$0!} }
    for attempt in 1...maxTries {
        rxLog.removeAll()
        send(frame(0x44,0x01,0,[]))
        pump(1.2)
        for r in rxLog where r.count>=20 && r[1]==0x44 && r[2]==0x0A && r[3]<10 { cfg[Int(r[3])] = r }
        saveCache(cfg)
        let have = cfg.compactMap{$0}.count
        let missing = (0..<10).filter{cfg[$0]==nil}
        print("  read attempt \(attempt): have \(have)/10, missing \(missing)")
        if have == 10 { return cfg.map{$0!} }
        print("    rx this attempt: \(rxLog.count) reports")
        // BLE: reopen the device between attempts, fresh connections yield different fragments
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(dev, 0); pump(0.5)
        _ = IOHIDDeviceOpen(dev, 0)
        IOHIDDeviceRegisterInputReportCallback(dev,&buf,buf.count,{ _,_,_,_,id,data,len in
            if id == 0x13 { rxLog.append(Array(UnsafeBufferPointer(start:data,count:len))) }
        },nil)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        pump(0.5)
    }
    return nil
}
func writeConfigEffect(_ cfg:[[UInt8]], effect:UInt8, colorMode:UInt8 = 0x01){
    for (i,var f) in cfg.enumerated() {
        f[1]=0x04
        if i==0 { f[8]=0x01; f[14]=0x00; f[15]=effect; f[17]=colorMode }
        sendEcho(withChecksum(f))
    }
}
func perKeyFrames(r:[UInt8], g:[UInt8], b:[UInt8]) -> [[UInt8]] {
    var out:[[UInt8]]=[]
    for (plane,vals) in [r,g,b].enumerated() {
        for k in 0..<9 {
            let slice = Array(vals[k*14 ..< min(k*14+14, vals.count)])
            out.append(frame(0x02,0x1C,UInt8(plane*9+k),[0x0E]+slice))
        }
    }
    out.append(frame(0x02,0x1C,27,[0x06,0x00,0x00,0x5A,0xA5]))
    return out
}
func writePerKeySolid(_ r:UInt8,_ g:UInt8,_ b:UInt8, fast:Bool = false){
    let n=126
    for f in perKeyFrames(r:[UInt8](repeating:r,count:n), g:[UInt8](repeating:g,count:n), b:[UInt8](repeating:b,count:n)) {
        if fast { send(f); pump(0.005) } else { sendEcho(f) }
    }
}
func save(){ sendEcho(frame(0x0A,0x01,0,[0x04,0x07])) }
func streamKeys(_ leds:[UInt8], secs:Double){
    var pairs:[UInt8]=[]; for l in leds { pairs += [255,l] }
    let f=frame(0x88,0x01,0,[0x10+UInt8(pairs.count)]+pairs)
    let t0=Date(); while Date().timeIntervalSince(t0)<secs { send(f); pump(0.03) }
    let idle=frame(0x88,0x01,0,[0x23]); for _ in 0..<3 { send(idle); pump(0.03) }
}

// ---- modes ------------------------------------------------------------------
let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "help" {
case "read":
    if let cfg = readConfig() { for f in cfg { print("  ", hex(f)) }; print("  effect=\(cfg[0][15]) colorMode=\(cfg[0][17]) applyFlag=\(cfg[0][14])") }
    else { print("  could not read full config") }

case "experiment":
    print("STEP A: per-key map only (no config write), solid RED ... watch the keyboard")
    rxLog.removeAll(); writePerKeySolid(255,0,0); print("  echoes: \(rxLog.count)/28"); pump(4.0)

    print("STEP B: read config, write config effect=21 (no save), per-key solid GREEN")
    if let cfg = readConfig() {
        print("  current effect=\(cfg[0][15]) colorMode=\(cfg[0][17])")
        rxLog.removeAll(); writeConfigEffect(cfg, effect:21); print("  config echoes: \(rxLog.count)/10")
        rxLog.removeAll(); writePerKeySolid(0,255,0); print("  perkey echoes: \(rxLog.count)/28")
    } else { print("  read failed, skipping config write"); writePerKeySolid(0,255,0) }
    pump(4.0)

    print("STEP C: 0x88 stream on Esc,F1-F6 for 4s, then idle")
    streamKeys([0,12,18,24,30,36,42], secs:4.0)
    pump(1.0)
    print("done — tell me what you saw at A, B, C")

case "perkey":   // perkey R G B [--save]
    let r=UInt8(args[1])!, g=UInt8(args[2])!, b=UInt8(args[3])!
    rxLog.removeAll(); let t0=Date(); writePerKeySolid(r,g,b, fast: args.contains("--fast")); pump(0.3); print("  perkey echoes: \(rxLog.count)/28 in \(String(format:"%.2f",Date().timeIntervalSince(t0)))s")
    if args.contains("--save") { save(); print("  saved") }

case "effect":   // effect N [--save]  (switch built-in effect, colorMode 3 = default)
    let n=UInt8(args[1])!
    if let cfg = readConfig() { writeConfigEffect(cfg, effect:n, colorMode: n==21 ? 0x01 : 0x03); if args.contains("--save") { save(); print("  saved") } ; print("  wrote effect \(n)") }

case "stream":
    streamKeys([0,12,18,24,30,36,42], secs: Double(args.dropFirst().first ?? "4") ?? 4)

default:
    print("modes: read | experiment | perkey R G B [--save] | effect N [--save] | stream [secs]")
}
