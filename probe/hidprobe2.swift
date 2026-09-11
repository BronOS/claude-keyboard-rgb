import Foundation
import IOKit.hid
func hex(_ b:[UInt8])->String{ b.map{String(format:"%02x",$0)}.joined(separator:" ") }
func frame(_ cmd:UInt8,_ sub:UInt8,_ seq:UInt8,_ payload:[UInt8])->[UInt8]{
    var f=[UInt8](repeating:0,count:20); f[0]=0x13; f[1]=cmd; f[2]=sub; f[3]=seq
    for (i,b) in payload.prefix(15).enumerated(){ f[4+i]=b }
    f[19]=UInt8(f[0..<19].reduce(0){($0+Int($1))&0xff}); return f }

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x3554, kIOHIDProductIDKey: 0xFA07] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
_ = IOHIDManagerOpen(mgr, 0)
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else { print("no device"); exit(1) }
let ro = IOHIDDeviceOpen(dev, 0); guard ro == kIOReturnSuccess else { print(String(format:"open failed 0x%08x", ro)); exit(2) }
var buf=[UInt8](repeating:0,count:64)
IOHIDDeviceRegisterInputReportCallback(dev,&buf,buf.count,{ _,_,_,type,id,data,len in
    let b=Array(UnsafeBufferPointer(start:data,count:len))
    if id != 1 && id != 2 { print(String(format:"RX type=%d id=0x%02x len=%d: ",type.rawValue,id,len)+hex(b)) }  // skip plain key reports
},nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
func send(_ f:[UInt8]){ let r=f.withUnsafeBufferPointer{IOHIDDeviceSetReport(dev,kIOHIDReportTypeOutput,0x13,$0.baseAddress!,$0.count)}; if r != 0 {print(String(format:"SetReport err 0x%08x",r))} }
func pump(_ s:Double){ CFRunLoopRunInMode(CFRunLoopMode.defaultMode, s, false) }

let mode = CommandLine.arguments.dropFirst().first ?? "read"
switch mode {
case "read":
    send(frame(0x44,0x01,0,[])); pump(3.0)
case "blink":
    let a:[UInt8]=[255,0, 255,12, 255,18, 255,24, 255,30, 255,36, 255,42]      // Esc F1-F6
    let b:[UInt8]=[255,7, 255,13, 255,19, 255,25, 255,31, 255,37, 255,43]      // 1-7
    let fa=frame(0x88,0x01,0,[0x1E]+a), fb=frame(0x88,0x01,0,[0x1E]+b)
    let t0=Date(); var n=0
    while Date().timeIntervalSince(t0) < 8.0 { let f = Int(Date().timeIntervalSince(t0)) % 2 == 0 ? fa : fb; send(f); n+=1; pump(0.02) }
    print("sent", n, "frames")
    let idle=frame(0x88,0x01,0,[0x23]); for _ in 0..<3 { send(idle); pump(0.02) }
case "audio":
    // one-fragment frame: 7 (brightness, led) pairs = 14 bytes -> subcmd=1, seq=0, datalen=0x10+14=0x1E
    let pairs:[UInt8]=[255,0, 255,12, 255,18, 255,24, 255,30, 255,36, 255,42]
    let f=frame(0x88,0x01,0,[0x1E]+pairs)
    print("TX x~150 over 3s:", hex(f))
    let t0=Date(); var n=0
    while Date().timeIntervalSince(t0) < 8.0 { send(f); n+=1; pump(0.02) }
    print("sent", n, "frames; now idle frame")
    let idle=frame(0x88,0x01,0,[0x23]); for _ in 0..<3 { send(idle); pump(0.02) }
    pump(0.5)
default: print("modes: read|audio")
}
print("done")
