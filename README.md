# desktop-alttab

A tiny macOS app that adds a "Desktop" entry to [AltTab](https://alt-tab.app)'s Cmd+Tab switcher — like Windows. The tile shows your live wallpaper as the thumbnail, and selecting it triggers macOS's native Show Desktop action.

## Why

macOS doesn't have a "Show Desktop" entry in any window switcher. AltTab shows windows of running apps, not the desktop itself. This app is a thin wrapper that fakes a real-windowed app with a wallpaper-content thumbnail; AltTab picks it up like any other window, and selecting it fires the Show Desktop hotkey.

## How it works

- A `borderless` NSWindow is created off-screen at (-30000, -30000)
- The window's content view is an `NSImageView` painted with a live capture of the macOS wallpaper window (via `ScreenCaptureKit` with `desktopIndependentWindow:` so other windows don't occlude the capture)
- The wallpaper image refreshes every 5 seconds, paused while AltTab is active
- The window's accessibility subrole is overridden to `AXStandardWindow` so AltTab's [`WindowDiscriminator`](https://github.com/lwouis/alt-tab-macos/blob/master/src/logic/WindowDiscriminator.swift) accepts it
- On `applicationDidBecomeActive`, the app synthesizes Fn+F11 (the "Show Desktop" macOS shortcut) via `CGEvent`

## Requirements

- macOS Sequoia (15.x) — uses ScreenCaptureKit and the `accessibilitySubrole` override
- AltTab installed
- "Show Desktop" bound to Fn+F11 in System Settings → Desktop & Dock → Mission Control → Shortcuts (the macOS default)

## Setup

```bash
# 1. Build
swiftc -O -o Desktop main.swift

# 2. Wrap into an .app bundle (one-time)
mkdir -p Desktop.app/Contents/{MacOS,Resources}
cp Desktop Desktop.app/Contents/MacOS/
cp Desktop.icns Desktop.app/Contents/Resources/AppIcon.icns
cat > Desktop.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Desktop</string>
    <key>CFBundleIdentifier</key><string>com.aum.desktop</string>
    <key>CFBundleName</key><string>Desktop</string>
    <key>CFBundleDisplayName</key><string>Desktop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 3. Create a stable code-signing cert (one-time, prevents TCC prompts on every rebuild)
#    See README "Stable signing" section below

# 4. Sign and install
mv Desktop.app /Applications/
codesign --force --sign "AumDesktopSign" /Applications/Desktop.app

# 5. Add as login item (auto-start at boot)
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Desktop.app", hidden:true}'

# 6. Open AltTab settings → Controls → "Show apps with no open window" → Hide
#    (Desktop now appears via the windowed path, so windowless clutter can be hidden)
```

After install, the first Cmd+Tab → Desktop will trigger two macOS permission prompts:
- **Screen Recording** (for wallpaper capture)
- **Accessibility** (for synthesizing the Show Desktop keystroke)

Grant both. With the stable cert, they persist across rebuilds (only the standard Sequoia ~30-day re-prompt for Screen Recording remains, which is Apple's policy).

## Rebuild loop

```bash
swiftc -O -o Desktop main.swift && \
  cp Desktop /Applications/Desktop.app/Contents/MacOS/Desktop && \
  codesign --force --sign "AumDesktopSign" /Applications/Desktop.app && \
  pkill -x Desktop && \
  open /Applications/Desktop.app
```

## Stable signing (avoid TCC re-prompts)

Without a stable code-signing identity, every `codesign --sign -` (ad-hoc) produces a new code hash, and macOS treats each rebuild as a "new" app — invalidating prior Screen Recording / Accessibility grants. To fix once:

```bash
# Create a self-signed code-signing certificate
openssl genrsa -out desktop_sign.key 2048

cat > desktop_sign.cnf <<'EOF'
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = AumDesktopSign
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -new -x509 -key desktop_sign.key -out desktop_sign.crt -days 3650 \
  -config desktop_sign.cnf -extensions v3_req

openssl pkcs12 -export -inkey desktop_sign.key -in desktop_sign.crt \
  -name "AumDesktopSign" -out desktop_sign.p12 -passout pass:temppass

# Import into login keychain, allow codesign to use it
security import desktop_sign.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "temppass" -T /usr/bin/codesign -A
```

After this, `codesign --force --sign "AumDesktopSign" ...` works for any future rebuild and TCC keeps the grants stable.

Replace `AumDesktopSign` with whatever name you prefer in both the cert and the codesign command.

## Notes

- Built and tested on macOS 15.x (Sequoia) on Apple Silicon
- The window is borderless and positioned far off-screen (-30000, -30000) so it never appears visually; AltTab still sees it via Accessibility because we override the AX subrole
- Wallpaper refresh is paused when AltTab is the frontmost app to avoid race conditions during thumbnail capture
- The app is `.regular` activation policy (visible in Dock) by default — change `setActivationPolicy(.accessory)` to hide from Dock if preferred

## License

MIT
