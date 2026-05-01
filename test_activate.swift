// Mimics the activation sequence AltTab uses on the Desktop app's window:
// 1. _SLPSSetFrontProcessWithOptions (private SkyLight) — process frontmost
// 2. SLPSPostEventRecordTo (twice) — make-key event records
// 3. AXUIElementPerformAction(window, kAXRaiseAction)
//
// Build:
//   swiftc -O -o test_activate test_activate.swift
// Run:
//   ./test_activate
import Cocoa
import ApplicationServices

// Private SkyLight type & functions (declared just enough to call them).
// PSN is two UInt32s; we hand it around as a raw pointer to dodge the
// "tuple not @convention(c)" restriction.
struct PSN { var hi: UInt32 = 0; var lo: UInt32 = 0 }

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutableRawPointer) -> OSStatus

let SLS = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> OSStatus
typealias SLPSPostEventRecordToType = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> OSStatus

let slpsSetFront: SLPSSetFrontProcessWithOptionsType? = {
    guard let s = SLS, let sym = dlsym(s, "_SLPSSetFrontProcessWithOptions") else {
        return nil as SLPSSetFrontProcessWithOptionsType?
    }
    return unsafeBitCast(sym, to: SLPSSetFrontProcessWithOptionsType.self)
}()
let slpsPost: SLPSPostEventRecordToType? = {
    guard let s = SLS, let sym = dlsym(s, "SLPSPostEventRecordTo") else {
        return nil as SLPSPostEventRecordToType?
    }
    return unsafeBitCast(sym, to: SLPSPostEventRecordToType.self)
}()

// Find the Desktop app
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.aum.desktop" }) else {
    print("ERROR: Desktop app not running")
    exit(1)
}
let pid = app.processIdentifier
print("Desktop pid=\(pid)")

// Get its AX windows
let axApp = AXUIElementCreateApplication(pid)
var winRef: CFTypeRef?
let r = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef)
guard r == .success, let windows = winRef as? [AXUIElement], let target = windows.first else {
    print("ERROR: no AX windows; status=\(r.rawValue)")
    exit(1)
}
print("Found \(windows.count) AX windows")

// Try to read window's CGWindowID via private AX call so the SLPS step can target it
typealias _AXUIElementGetWindowType = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
let axLib = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/HIServices", RTLD_NOW)
let axGetWindow: _AXUIElementGetWindowType? = {
    guard let s = axLib, let sym = dlsym(s, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: _AXUIElementGetWindowType.self)
}()
var cgwid: UInt32 = 0
if let f = axGetWindow {
    let er = f(target, &cgwid)
    print("_AXUIElementGetWindow status=\(er.rawValue) cgwid=\(cgwid)")
} else {
    print("could not dlsym _AXUIElementGetWindow")
}

// Step 1+2: SLPS frontmost + key event records
var psn = PSN()
let st = withUnsafeMutablePointer(to: &psn) { ptr -> OSStatus in
    GetProcessForPID(pid, UnsafeMutableRawPointer(ptr))
}
print("GetProcessForPID status=\(st) psn=(\(psn.hi),\(psn.lo))")

if let f = slpsSetFront {
    // SLPSMode.userGenerated.rawValue == 2 in AltTab
    let r = withUnsafeMutablePointer(to: &psn) { p in
        f(UnsafeMutableRawPointer(p), cgwid, 2)
    }
    print("_SLPSSetFrontProcessWithOptions status=\(r)")
} else {
    print("slpsSetFront unavailable")
}

if let f = slpsPost, cgwid != 0 {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    var widCopy = cgwid
    withUnsafeBytes(of: &widCopy) { (src: UnsafeRawBufferPointer) in
        bytes.withUnsafeMutableBufferPointer { dst in
            _ = memcpy(dst.baseAddress!.advanced(by: 0x3c), src.baseAddress!, MemoryLayout<UInt32>.size)
        }
    }
    memset(&bytes[0x20], 0xff, 0x10)
    bytes[0x08] = 0x01
    let r1: OSStatus = withUnsafeMutablePointer(to: &psn) { p in
        bytes.withUnsafeMutableBufferPointer { b in
            f(UnsafeMutableRawPointer(p), UnsafeMutableRawPointer(b.baseAddress!))
        }
    }
    bytes[0x08] = 0x02
    let r2: OSStatus = withUnsafeMutablePointer(to: &psn) { p in
        bytes.withUnsafeMutableBufferPointer { b in
            f(UnsafeMutableRawPointer(p), UnsafeMutableRawPointer(b.baseAddress!))
        }
    }
    print("SLPSPostEventRecordTo r1=\(r1) r2=\(r2)")
}

// Step 3: AX raise
let raise = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
print("AXUIElementPerformAction(kAXRaiseAction) status=\(raise.rawValue)")

// Wait briefly so any hook in the Desktop app has time to log
Thread.sleep(forTimeInterval: 1.0)
print("Done. Inspect /tmp/desktop-app.log")
