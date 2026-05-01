import Cocoa
import ScreenCaptureKit

class GhostWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
        return nil
    }
    override var canBecomeKey: Bool { true }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        return .standardWindow
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var ghostWindow: GhostWindow!
    var imageView: NSImageView!

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

        // Capture wallpaper on launch + every 30s, pause when AltTab is active
        Task { await captureWallpaper() }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            // Skip if AltTab is currently the frontmost app (Cmd+Tab is open)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.lwouis.alt-tab-macos" {
                return
            }
            Task { await self?.captureWallpaper() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.postShowDesktopKey()
        }
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

    func postShowDesktopKey() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let f11: CGKeyCode = 103
        let down = CGEvent(keyboardEventSource: src, virtualKey: f11, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: f11, keyDown: false)
        down?.flags = .maskSecondaryFn
        up?.flags = .maskSecondaryFn
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
