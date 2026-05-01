# ScreenMirror

End-to-end encrypted screen mirroring and remote control between a jailbroken iPhone (or iPad) and a Mac, over the local network.

The iPhone captures its own screen, encodes it as H.264, encrypts everything with AES-256-GCM, and pushes the stream to a server running on macOS. The server decodes the video in real time, displays it in a window, and forwards mouse, keyboard, swipes, and physical-button presses back to the iPhone.

```
┌─────────────────────┐         AES-256-GCM           ┌─────────────────────┐
│  iPhone (jailbreak) │  ───── X25519 ephemeral ───→  │   ScreenMirror.app  │
│  SpringBoard tweak  │   PBKDF2-SHA512 + password    │     macOS 12+       │
│  H.264 / VTCompress │  ←──── HID input injection ── │   AVSampleBuffer    │
└─────────────────────┘    TCP :4878 / Bonjour        └─────────────────────┘
```

## Features

- **Live H.264 streaming** with selectable quality presets (Low / Medium / High) tunable from the Mac UI without reconnecting.
- **Remote control**: mouse, keyboard, synthesised gestures (swipes, multi-finger), physical buttons (Home, Lock, Vol±, Mute, Siri).
- **Quick-nav bar**: previous page, next page, App Switcher, Notification Center, with form-factor-aware gestures (Home button vs Face ID vs iPad, branching on iOS major version).
- **End-to-end encryption**:
  - Per-session ephemeral X25519 keys (forward secrecy).
  - PBKDF2-SHA512 600 000 iterations to stretch the shared password (OWASP 2023+ guidance).
  - HKDF-SHA256 mixes the X25519 shared secret + PBKDF2 output → 256-bit AES key.
  - Monotonic counter IVs; no IV reuse.
- **Multi-device support**: launch picker lists every iPhone/iPad you've ever paired with. Pick one (or multiple, ⌘-click) and a streaming window opens per device. The shared TCP listener routes incoming connections to the right window based on the device descriptor.
- **Minimalist mode** (⌘.) hides every chrome element so only the device screen is visible.
- **Device info popover** (⌘I) with model, iOS version, resolution, peer, encryption details.
- **Bonjour** (`_smirror._tcp.`) for zero-config discovery — no need to type IPs into the iOS control app.

## Architecture

```
┌──────────────────────────── iPhone (SpringBoard tweak) ────────────────────────────┐
│                                                                                    │
│  ScreenCapture ─→ VideoEncoder ─→ NetworkClient ──┐                                │
│  (CARenderServer /                  (X25519 +     │                                │
│   _UICreateScreenUIImage              PBKDF2 +    │  encrypted TCP                 │
│   fallback)                           AES-GCM)    │                                │
│                                                   │                                │
│  TouchInjector ←── NetworkClient ◀────────────────┘                                │
│  (IOHIDEventSystemClient,                                                          │
│   Hand transducer)                                                                 │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
                            ▲
                            │ Reads host/password from a plist; the
                            │ ScreenMirrorControl iOS app edits that plist
                            │ and posts a Darwin notification to reconnect.
                            ▼
                  ScreenMirrorControl.app (iPhone)

┌──────────────────────────── Mac (AppKit) ──────────────────────────────────────────┐
│                                                                                    │
│  AppDelegate ──→ DevicePickerWindowController                                      │
│        │                  │                                                        │
│        │                  └──→ MainWindowController(targetDevice: A)               │
│        ├────────────────────→ MainWindowController(targetDevice: B)                │
│        │                                                                           │
│  ConnectionRouter (singleton)                                                      │
│   └─ NetworkServer (1 listener on :4878, N peers, AES-GCM)                         │
│      └─ delegate routes by SMIR_HANDSHAKE.deviceName / iOS / resolution            │
│                                                                                    │
│  Each window: VideoDecoder ─→ DeviceView (AVSampleBufferDisplayLayer)              │
│                EventForwarder ─→ NetworkServer.send → iPhone                       │
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

The wire format is documented in [`PROTOCOL.md`](PROTOCOL.md).

## Requirements

### Mac

- macOS 12 (Monterey) or newer.
- Xcode 14+ with Swift 5.7+ (Command Line Tools are enough: `xcode-select --install`).
- On the same local network as the iPhone.

### iPhone / iPad

- A **rootless** jailbreak (palera1n, Dopamine) on iOS 11–18. The tweak builds for both `arm64` and `arm64e`.
- SSH access enabled, with the `mobile` user's password known.
- iOS 18 has been observed to work on at least one device (iPad7,11) but SpringBoard launch on iOS 18 can be flaky for reasons unrelated to this tweak (the iCloud Family Sharing daemon sometimes deadlocks SpringBoard's main thread). If you hit a SpringBoard crash loop, see [Troubleshooting](#troubleshooting).
- [Theos](https://theos.dev/) installed on the build Mac, with `THEOS` in your environment (typically `~/theos`).

## Installation

### 1. Clone

```sh
git clone https://github.com/<your-user>/ipa-remote.git
cd ipa-remote
```

### 2. Build and install the Mac app

The repository includes a one-shot script that builds a release binary, generates the icon, assembles a `.app`, ad-hoc signs it, and drops it into `/Applications`:

```sh
./scripts/install-mac-app.sh
open /Applications/ScreenMirror.app
```

If you prefer to do it by hand:

```sh
cd mac
swift build -c release
APP=/Applications/ScreenMirror.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/ScreenMirrorServer "$APP/Contents/MacOS/ScreenMirror"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift ../scripts/generate_icon.swift /tmp/icon.png    # optional; macOS will use a generic icon otherwise
codesign --force --deep --sign - "$APP"
open "$APP"
```

To pin to the Dock, drag from Finder, or:

```sh
defaults write com.apple.dock persistent-apps -array-add \
  "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/ScreenMirror.app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
killall Dock
```

### 3. Build the iOS tweak

```sh
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos

cd ios
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

The `.deb` lands in `ios/packages/`.

> If your jailbreak is **rootful** (Unc0ver, classic checkra1n), drop `THEOS_PACKAGE_SCHEME=rootless`. The package then targets `/Library/MobileSubstrate/...` instead of `/var/jb/Library/MobileSubstrate/...`.

### 4. (Optional) Build the iPhone control app

The control app provides a small UI on the device for changing host/password without SSH:

```sh
cd ios/control-app
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

### 5. Deploy to the iPhone

Over SSH:

```sh
# Tweak (mandatory)
scp ios/packages/com.example.screenmirror_*.deb mobile@<iphone-ip>:/var/mobile/sm.deb
ssh mobile@<iphone-ip> 'sudo dpkg -i /var/mobile/sm.deb && sudo killall -9 SpringBoard'

# Control app (optional)
scp ios/control-app/packages/com.example.screenmirror-control_*.deb mobile@<iphone-ip>:/var/mobile/smc.deb
ssh mobile@<iphone-ip> 'sudo dpkg -i /var/mobile/smc.deb'
```

`killall SpringBoard` (a respring) is required after installing the tweak so SpringBoard re-loads the dylib.

## Configuration

### Shared password

All traffic is encrypted with a key derived from a shared password. **It must be byte-identical on both ends** or every encrypted message will fail authentication and the connection drops silently with `decrypt failed`.

- **Mac**: the first launch prompts you. Minimum 8 characters. Saved in `~/Library/Preferences/com.example.ScreenMirrorServer.plist` (suite `com.example.ScreenMirrorServer`, key `smir-shared-password`). Change it later with the **Password** button in the bottom bar, or via the **ScreenMirror → Change Password…** menu (⌘,).
- **iPhone, option A — control app**: open **ScreenMirror** on the device, type the Mac IP (or pick from the Bonjour list) and the same password, leave the toggle **on**, tap **Apply and reconnect**.
- **iPhone, option B — manual**: edit `/var/mobile/Library/Preferences/com.example.screenmirror.plist`:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0">
  <dict>
      <key>host</key><string>192.168.1.42</string>
      <key>password</key><string>your-secret-password</string>
      <key>enabled</key><true/>
  </dict>
  </plist>
  ```

  The tweak re-reads this file on every reconnection attempt (every 5 s while disconnected and `enabled=true`).

### Bonjour (auto-discovery)

The Mac advertises `_smirror._tcp.` on `local.`. In the iOS control app, the Bonjour button auto-discovers the Mac without manual IP entry.

## Usage

1. Open **ScreenMirror.app** on the Mac (Dock, Spotlight, or `open /Applications/ScreenMirror.app`).
2. The device picker appears as soon as your history contains at least one device. Select one (or several with ⌘-click) and click **Connect** — a streaming window opens per selection. Or click **Listen for any device** to open a single catch-all window that takes whichever iPhone connects first.
3. On the iPhone the tweak retries every 5 s while `enabled=true`. After a fresh install you need a `killall SpringBoard` so the dylib loads.
4. Once a device is streaming:
   - **Mouse click** = tap.
   - **Click + drag** = swipe (with realistic 120 Hz easeOutQuad easing; edge swipes auto-add an 80 ms initial dwell so SpringBoard's edge gesture recognizer fires).
   - **Keyboard** is forwarded as HID.
   - **Bottom button bar**: Home, Lock, Vol±, Mute (toggles audio category mute via `AVSystemController`), Siri (press and hold).
   - **Top nav bar**: Previous Page, Next Page, App Switcher, Notification Center.
   - **⌘.** toggles minimalist mode (only the device screen is visible).
   - **⌘I** opens the device-info popover.
   - **⌘1 / ⌘2 / ⌘3** = quality preset Low / Medium / High; the iPhone hot-restarts its capture/encoder pipeline in ~25 ms.

## Repository layout

```
ipa-remote/
├── README.md                     ← this file
├── PROTOCOL.md                   ← full wire format (HELLO, encrypted frames, message types)
├── scripts/
│   ├── generate_icon.swift       ← Core Graphics renderer for the 1024×1024 master icon
│   └── install-mac-app.sh        ← build + bundle + sign + install one-shot
├── ios/
│   ├── Makefile                  ← Theos: produces the rootless tweak .deb
│   ├── ScreenMirror.plist        ← MobileSubstrate filter (loads only into SpringBoard)
│   ├── entitlements.plist        ← private HID/IOSurface entitlements
│   ├── src/
│   │   ├── Tweak.x               ← controller (NetworkClient + capture + injector)
│   │   ├── ScreenCapture.{h,m}   ← CARenderServer + _UICreateScreenUIImage fallback
│   │   ├── VideoEncoder.{h,m}    ← VTCompressionSession (H.264)
│   │   ├── NetworkClient.{h,m}   ← TCP client + HELLO/X25519 + AES-GCM
│   │   ├── TouchInjector.{h,m}   ← IOHIDEventSystemClient (Hand transducer)
│   │   ├── Crypto.{h,m}          ← PBKDF2-SHA512 + HKDF-SHA256 + GCM backend probe
│   │   ├── X25519.{h,c}          ← TweetNaCl-derived scalarmult
│   │   └── Protocol.h            ← message types + payload structs
│   └── control-app/              ← iOS app for editing host/password
│       └── src/
│           ├── ViewController.m
│           └── AppDelegate.m
└── mac/
    ├── Package.swift
    ├── Resources/Info.plist      ← bundle metadata for the .app
    └── Sources/ScreenMirrorServer/
        ├── main.swift
        ├── AppDelegate.swift             ← starts router, shows picker
        ├── DevicePickerWindowController  ← table of remembered devices
        ├── DeviceHistory.swift           ← persistence (UserDefaults JSON)
        ├── ConnectionRouter.swift        ← single-listener fan-out by handshake
        ├── MainWindowController.swift    ← one streaming window per device
        ├── NetworkServer.swift           ← TCP listener + server-side HELLO
        ├── Crypto.swift                  ← CryptoKit + CommonCrypto
        ├── VideoDecoder.swift            ← VTDecompressionSession
        ├── DeviceView.swift              ← AVSampleBufferDisplayLayer + input
        ├── EventForwarder.swift          ← serialises touches/swipes/keys/buttons
        ├── NavBar.swift                  ← top quick-nav bar
        ├── ButtonBar.swift               ← bottom physical-button bar
        ├── ConnectionOverlay.swift       ← waiting / authenticating / streaming overlay
        ├── Quality.swift                 ← Low / Medium / High preset table
        └── Keychain.swift                ← shared-password persistence
```

## Troubleshooting

### `decrypt failed — wrong password` on the Mac log

The two passwords don't match. Verify both:

```sh
# Mac
defaults read com.example.ScreenMirrorServer smir-shared-password

# iPhone
ssh mobile@<ip> 'cat /var/mobile/Library/Preferences/com.example.screenmirror.plist'
```

`defaults` may serve cached values. The authoritative file is `~/Library/Preferences/com.example.ScreenMirrorServer.plist` — read it with `plutil -p` for a fresh value.

### Dock icon doesn't refresh after a rebuild

```sh
touch /Applications/ScreenMirror.app
killall Dock
# If it still won't update:
rm -rf ~/Library/Caches/com.apple.iconservices.store
sudo find /private/var/folders/ -name com.apple.dock.iconcache -exec rm {} \;
killall Dock
```

### Black screen on the Mac

The iPhone's capture backend is silently failing. The tweak auto-falls back to `_UICreateScreenUIImage` after 30 black frames from `CARenderServer`. Inspect the tweak log:

```sh
ssh mobile@<ip> 'tail -n 200 /tmp/screenmirror.log'
```

If you see Jetsam events shortly before, drop to the Low preset (⌘1) — the fallback path retains a CGImage briefly and high resolutions can OOM in SpringBoard.

### Mac listener says `READY` but `lsof :4878` shows nothing

`lsof` filters aggressively for the current user. Use `netstat -an -p tcp | grep 4878` instead, or `nc 127.0.0.1 4878` to confirm the listener is reachable. (Both will succeed; the empty `lsof` is cosmetic.)

### Local Network privacy denied (macOS Sonoma+)

macOS asks the first time the app opens a listener. If the prompt was dismissed, force a re-prompt:

```sh
tccutil reset NSLocalNetworkUsageDescription com.example.ScreenMirrorServer
```

Reopen the app and accept.

### SpringBoard crash loop on iOS 18

Crashes with `EXC_CRASH/SIGKILL` in `mach_msg2_trap` from `-[FAFetchFamilyCircleRequest fetchFamilyCircleWithError:]` are an iOS 18 SpringBoard issue (iCloud Family Sharing main-thread deadlock) and **not** caused by this tweak. To recover, disable the dylib over SSH:

```sh
ssh mobile@<ip> "sudo mv \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenMirror.dylib \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenMirror.dylib.disabled \
  && sudo killall -9 SpringBoard"
```

After SpringBoard stabilises (the family-sharing daemon usually recovers), rename the dylib back:

```sh
ssh mobile@<ip> "sudo mv \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenMirror.dylib.disabled \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenMirror.dylib \
  && sudo killall -9 SpringBoard"
```

## Security

- **Forward secrecy**: every connection generates a fresh X25519 keypair; the private half is wiped immediately after deriving the AES key. Compromising the password later does not let an attacker decrypt earlier captures.
- **Mutual authentication**: both sides arrive at the same 256-bit AES key only if they both know the password. The GCM authentication tag prevents an active attacker without the password from injecting or modifying messages — the receiving side rejects every tampered frame.
- **Password rules**: ≥ 8 characters; do not reuse outside this tool. PBKDF2-SHA512 with 600 000 iterations makes offline brute-force expensive on commodity hardware (about 1.6 GPU-seconds per attempt on an A100 today, per OWASP 2023 guidance).
- **What's visible on the wire**: the only fixed-length plaintext is the 56-byte HELLO at the start of each connection (magic + version + flags + nonce + ephemeral X25519 pubkey). Everything after is `length-prefix ‖ AES-GCM ciphertext ‖ 16-byte tag`. A passive observer learns connection timing, framing, and approximate frame size — not content.
- **Replay protection**: monotonic counter IVs (per direction). Reusing a session key with a stale counter would leak GCM keystream — we never decrement counters and never reuse the session key across reconnects.

## License

MIT — see [`LICENSE`](LICENSE).

## Tested Devices

- Iphone8 (iOS 16.x) - Jailbroken with Palera1n
- Ipad 7th (iOS 18.x) - Jailbroken with Palera1n   

## Acknowledgements

- [Theos](https://theos.dev/) for the tweak toolchain.
- [TweetNaCl](https://tweetnacl.cr.yp.to/) — basis of the X25519 scalarmult implementation.
- Veency / Activator for the IOHID `Hand transducer` injection pattern.
