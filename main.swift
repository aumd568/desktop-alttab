import Cocoa
import ScreenCaptureKit
import ApplicationServices

// Captured at process start. Used by Trigger to suppress activations during
// the first second of launch — the polling watcher's first tick can race
// the AppDelegate setup and report us as frontmost spuriously.
let launchTime = Date()

// MARK: - Trigger (debounced F11 synthesis)
//
// Multiple hooks can fire for one activation; debounce so we post F11 once.
final class Trigger {
    static let shared = Trigger()
    private var lastFire = Date.distantPast
    private let minInterval: TimeInterval = 0.5
    private let q = DispatchQueue(label: "desktop.trigger")

    func fire(reason: String) {
        q.sync {
            let now = Date()
            if now.timeIntervalSince(launchTime) < 1.0 {
                Trigger.log("skip(startup) reason=\(reason)")
                return
            }
            if now.timeIntervalSince(lastFire) < minInterval {
                Trigger.log("skip(debounce) reason=\(reason)")
                return
            }
            lastFire = now
            Trigger.log("fire reason=\(reason)")
            DispatchQueue.main.async { Trigger.postShowDesktopKey() }
        }
    }

    // Lightweight file logger — useful when diagnosing activation paths
    // because NSLog from a sandboxed accessory app can be hard to read back.
    static let logURL = URL(fileURLWithPath: "/tmp/desktop-app.log")
    static let logFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    static func log(_ msg: String) {
        let line = "\(logFmt.string(from: Date())) \(msg)\n"
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        }
    }

    static func postShowDesktopKey() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let f11: CGKeyCode = 103
        let down = CGEvent(keyboardEventSource: src, virtualKey: f11, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: f11, keyDown: false)
        down?.flags = .maskSecondaryFn
        up?.flags = .maskSecondaryFn
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - GhostWindow
//
// AltTab discovers it because we override accessibilitySubrole to .standardWindow
// even though styleMask is .borderless. Lives off-screen at -30000,-30000 so it
// never paints over real windows.
class GhostWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? { nil }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .standardWindow }
}

// MARK: - AX self-observer
//
// Backup activation signal. AppKit's NSApplication.didBecomeActive can be
// suppressed for .accessory apps in some macOS versions; AX sits at the
// WindowServer level and fires reliably when AltTab uses the SLPS+AX
// activation sequence.
final class AXSelfObserver {
    private var observer: AXObserver?
    private let element = AXUIElementCreateApplication(getpid())

    func start() {
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, notif, _ in
            if (notif as String) == kAXApplicationActivatedNotification as String {
                Trigger.shared.fire(reason: "ax.activated")
            }
        }
        guard AXObserverCreate(getpid(), cb, &obs) == .success, let observer = obs else { return }
        self.observer = observer
        AXObserverAddNotification(observer, element, kAXApplicationActivatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

// MARK: - Frontmost watcher (polling fallback)
//
// Last-resort trigger if both NSWorkspace and AX miss an activation. Polls
// every 100ms for the frontmost-pid transition. Cost: one syscall per tick,
// negligible CPU.
final class FrontmostWatcher {
    private var timer: Timer?
    private let ourPid = getpid()
    private var wasFront = false

    func start() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let isFront = (frontPid == ourPid)
        if isFront && !wasFront { Trigger.shared.fire(reason: "watcher") }
        wasFront = isFront
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var ghostWindow: GhostWindow!
    var imageView: NSImageView!
    var axObserver: AXSelfObserver!
    var watcher: FrontmostWatcher!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!
        let frame = screen.frame
        let aspect = frame.width / frame.height
        let height: CGFloat = 600
        let width = height * aspect

        let w = GhostWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = "Desktop"
        w.isOpaque = true
        w.backgroundColor = .black
        w.alphaValue = 1.0
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .normal
        w.collectionBehavior = [.ignoresCycle]
        w.isReleasedWhenClosed = false
        w.isMovable = false
        w.isExcludedFromWindowsMenu = true

        let iv = NSImageView(frame: w.contentView!.bounds)
        iv.imageScaling = .scaleAxesIndependently
        iv.imageAlignment = .alignCenter
        iv.image = NSApp.applicationIconImage
        iv.autoresizingMask = [.width, .height]
        w.contentView = iv
        imageView = iv

        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        ghostWindow = w

        // Wallpaper capture: live thumbnail in AltTab, refresh every 5s,
        // skip refresh while AltTab itself is frontmost (Cmd+Tab open).
        Task { await captureWallpaper() }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.lwouis.alt-tab-macos" {
                return
            }
            Task { await self?.captureWallpaper() }
        }

        // Primary trigger: NSWorkspace's app-activated notification. Fires
        // earliest in the activation sequence and doesn't false-positive on
        // window orderFront at launch (unlike window-focus AX events).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [ourPid = getpid()] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == ourPid {
                Trigger.shared.fire(reason: "ws.activate")
            }
        }

        // Backup trigger: AX application-activated. Some macOS versions can
        // suppress AppKit/NSWorkspace activation notifications for accessory
        // apps; AX runs at the WindowServer level and stays reliable.
        axObserver = AXSelfObserver()
        axObserver.start()

        // Last-resort trigger: poll the frontmost pid. Fires on the
        // not-front -> front transition. Negligible CPU.
        watcher = FrontmostWatcher()
        watcher.start()
    }

    func captureWallpaper() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let wallpapers = content.windows.filter {
                $0.owningApplication?.applicationName == "Dock" &&
                ($0.title?.hasPrefix("Wallpaper-") ?? false)
            }
            guard let wallpaper = wallpapers.first else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(wallpaper.frame.width) * 2
            cfg.height = Int(wallpaper.frame.height) * 2
            cfg.showsCursor = false
            // desktopIndependentWindow captures the wallpaper's pixels regardless of what's covering it on screen
            let filter = SCContentFilter(desktopIndependentWindow: wallpaper)
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            await MainActor.run {
                self.imageView?.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            }
        } catch {
            NSLog("Desktop.app: capture error \(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
