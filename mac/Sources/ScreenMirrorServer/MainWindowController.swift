import AppKit
import Network
import CoreMedia

final class MainWindowController: NSWindowController, VideoDecoderDelegate, DeviceViewDelegate, NSWindowDelegate {

    private let router = ConnectionRouter.shared
    private let decoder = VideoDecoder()
    private lazy var forwarder = EventForwarder(server: router.server)
    private let deviceView = DeviceView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
    private let overlay = ConnectionOverlay(frame: .zero)
    private let navBar = NavBar()
    private let buttonBar = ButtonBar()
    private let statusLabel = NSTextField(labelWithString: "Waiting for device on :4878")
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passwordButton = NSButton(title: "", target: nil, action: nil)
    private let infoButton = NSButton(title: "", target: nil, action: nil)
    private let minimalistButton = NSButton(title: "", target: nil, action: nil)
    private let swipeQueue = DispatchQueue(label: "smir.swipe")

    private var currentClient: NWConnection?
    private var handshake: SMIRHandshake?
    private var sawFirstFrame = false
    private var isMinimalist: Bool = false
    private var infoPopover: NSPopover?
    private var chromeConstraints: [NSLayoutConstraint] = []
    private var minimalistConstraints: [NSLayoutConstraint] = []

    /// When non-nil, the window only accepts handshakes from this exact
    /// device descriptor; mismatched handshakes get their connection
    /// dropped so the iPhone retries (and lands on a different window).
    let targetDevice: DeviceDescriptor?

    static weak var shared: MainWindowController?
    var onWindowWillClose: ((MainWindowController) -> Void)?
    private var didInitialAutoFit = false
    private var lastOrientationIsLandscape: Bool?
    init(targetDevice: DeviceDescriptor? = nil) {
        self.targetDevice = targetDevice
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 920),
                           styleMask: style, backing: .buffered, defer: false)
        win.title = targetDevice.map { "ScreenMirror — \($0.displayName)" }
                  ?? "ScreenMirror"
        win.minSize = NSSize(width: 280, height: 380)
        super.init(window: win)
        MainWindowController.shared = self
        win.delegate = self
        let autosaveName = NSWindow.FrameAutosaveName("ScreenMirror_\(targetDevice?.modelId ?? "Default")")
        win.setFrameAutosaveName(autosaveName)
        router.register(self)

        let content = NSView(frame: win.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        win.contentView = content

        deviceView.delegate = self
        deviceView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(deviceView)

        // Overlay sits on top of deviceView and shares its rect.
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay)

        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.handler = { [weak self] action in self?.handleNav(action) }
        content.addSubview(navBar)

        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.handler = { [weak self] btn in self?.pressDeviceButton(btn) }
        buttonBar.holdHandler = { [weak self] btn, down in
            guard let self else { return }
            guard self.currentClient != nil else {
                self.setStatus("No device connected"); return
            }
            self.forwarder.pressButton(btn, down: down)
        }
        content.addSubview(buttonBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(statusLabel)

        // Quality selector — NSPopUpButton with 3 options.
        qualityPopup.translatesAutoresizingMaskIntoConstraints = false
        qualityPopup.controlSize = .small
        qualityPopup.font = .systemFont(ofSize: 11, weight: .regular)
        qualityPopup.bezelStyle = .roundRect
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged(_:))
        for q in Quality.allCases {
            let item = NSMenuItem(title: "Quality: \(q.label)", action: nil, keyEquivalent: "")
            item.tag = Int(q.rawValue)
            qualityPopup.menu?.addItem(item)
        }
        qualityPopup.selectItem(withTag: Int(QualityStore.current.rawValue))
        qualityPopup.toolTip = "Change streaming quality (⌘1 / ⌘2 / ⌘3)"
        content.addSubview(qualityPopup)

        // Password change — small button with key icon, visible.
        passwordButton.translatesAutoresizingMaskIntoConstraints = false
        passwordButton.bezelStyle = .roundRect
        passwordButton.controlSize = .small
        passwordButton.font = .systemFont(ofSize: 11, weight: .regular)
        if let img = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Password") {
            passwordButton.image = img
            passwordButton.imagePosition = .imageLeading
            passwordButton.imageScaling = .scaleProportionallyDown
        }
        passwordButton.title = "Password"
        passwordButton.target = self
        passwordButton.action = #selector(changePasswordTapped)
        passwordButton.toolTip = "Change shared password (⌘,)"
        content.addSubview(passwordButton)

        // Device info — visibly bordered icon-only button that opens a
        // popover with model / iOS / resolution / IP / encryption details.
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.bezelStyle = .roundRect
        infoButton.isBordered = true
        infoButton.controlSize = .small
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Device info") {
            infoButton.image = img
            infoButton.imagePosition = .imageOnly
            infoButton.imageScaling = .scaleProportionallyDown
        }
        infoButton.target = self
        infoButton.action = #selector(infoTapped(_:))
        infoButton.toolTip = "Device information (⌘I)"
        content.addSubview(infoButton)

        // Minimalist mode — same visible bezel as the other bottom-bar
        // buttons so it can never disappear into the background. Lives on
        // the right end of the bottom bar with its own SF symbol that swaps
        // between expand/contract.
        minimalistButton.translatesAutoresizingMaskIntoConstraints = false
        minimalistButton.bezelStyle = .roundRect
        minimalistButton.isBordered = true
        minimalistButton.controlSize = .small
        if let img = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                             accessibilityDescription: "Toggle minimalist mode") {
            minimalistButton.image = img
            minimalistButton.imagePosition = .imageOnly
            minimalistButton.imageScaling = .scaleProportionallyDown
        }
        minimalistButton.target = self
        minimalistButton.action = #selector(toggleMinimalist)
        minimalistButton.toolTip = "Toggle minimalist mode (⌘.)"
        content.addSubview(minimalistButton)

        // Constraints that bind the device view to the chrome (normal mode).
        chromeConstraints = [
            deviceView.topAnchor.constraint(equalTo: content.topAnchor),
            deviceView.bottomAnchor.constraint(equalTo: navBar.topAnchor),
        ]
        // Constraints used while in minimalist mode (chrome hidden).
        minimalistConstraints = [
            deviceView.topAnchor.constraint(equalTo: content.topAnchor),
            deviceView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]

        NSLayoutConstraint.activate(chromeConstraints + [
            deviceView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            deviceView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            overlay.topAnchor.constraint(equalTo: deviceView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: deviceView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: deviceView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: deviceView.bottomAnchor),

            navBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 42),
            navBar.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),

            buttonBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: 46),
            buttonBar.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: infoButton.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: passwordButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: qualityPopup.centerYAnchor),

            infoButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            infoButton.centerYAnchor.constraint(equalTo: qualityPopup.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 28),
            infoButton.heightAnchor.constraint(equalToConstant: 22),

            passwordButton.trailingAnchor.constraint(equalTo: qualityPopup.leadingAnchor, constant: -6),
            passwordButton.centerYAnchor.constraint(equalTo: qualityPopup.centerYAnchor),

            qualityPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            qualityPopup.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            qualityPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),

            // Minimalist toggle — floats over the top-right of the device
            // view so it stays reachable in both normal and minimalist mode.
            minimalistButton.topAnchor.constraint(equalTo: deviceView.topAnchor, constant: 8),
            minimalistButton.trailingAnchor.constraint(equalTo: deviceView.trailingAnchor, constant: -8),
            minimalistButton.widthAnchor.constraint(equalToConstant: 32),
            minimalistButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        decoder.delegate = self
        // The router owns the listener and password; the window simply
        // observes routed events and runs its own decoder/UI.
        overlay.phase = .waiting
        win.makeFirstResponder(deviceView)
    }

    deinit {
        router.unregister(self)
    }

    func windowWillClose(_ notification: Notification) {
        router.unregister(self)
        forwarder.setClient(nil)
        currentClient?.cancel()
        currentClient = nil
        onWindowWillClose?(self)
    }

    var hasActiveClient: Bool { currentClient != nil }

    @objc private func changePasswordTapped() { promptForPassword(initial: false) }

    @objc private func infoTapped(_ sender: NSButton) {
        if let pop = infoPopover, pop.isShown { pop.performClose(nil); return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 260, height: 180)
        pop.contentViewController = makeInfoVC()
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        infoPopover = pop
    }

    private func makeInfoVC() -> NSViewController {
        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        let t = NSTextField(wrappingLabelWithString: deviceInfoText())
        t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        t.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            t.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            t.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -12),
        ])
        vc.view = v
        return vc
    }

    private func deviceInfoText() -> String {
        var lines: [String] = []
        if let hs = handshake {
            lines.append("Device:    \(hs.deviceName)")
            lines.append("iOS:       \(hs.iosMajor).\(hs.iosMinor)")
            lines.append("Resolution:\(Int(hs.width))×\(Int(hs.height)) @\(hs.scale)x")
            switch deviceForm {
            case .homeButton: lines.append("Form:      Home button")
            case .faceID:     lines.append("Form:      Face ID")
            case .iPad:       lines.append("Form:      iPad")
            }
        } else {
            lines.append("Device:    (not connected)")
        }
        if let conn = currentClient,
           case let .hostPort(host, port) = conn.endpoint {
            lines.append("Peer:      \(host):\(port)")
        }
        lines.append("Server:    :4878 (Bonjour _smirror._tcp)")
        lines.append("Cipher:    AES-256-GCM")
        lines.append("Key:       X25519 ephemeral + PBKDF2-SHA512")
        return lines.joined(separator: "\n")
    }

    @objc private func toggleMinimalist() {
        isMinimalist.toggle()
        applyMinimalistState(animated: true)
    }

    private func applyMinimalistState(animated: Bool) {
        let hide = isMinimalist
        let toHide: [NSView] = [navBar, buttonBar, statusLabel, qualityPopup, passwordButton, infoButton]

        // Swap which set of constraints binds the device view's bottom edge.
        if hide {
            NSLayoutConstraint.deactivate(chromeConstraints)
            NSLayoutConstraint.activate(minimalistConstraints)
        } else {
            NSLayoutConstraint.deactivate(minimalistConstraints)
            NSLayoutConstraint.activate(chromeConstraints)
        }

        let symbol = hide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle minimalist mode") {
            minimalistButton.image = img
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                toHide.forEach { $0.animator().alphaValue = hide ? 0 : 1 }
                self.window?.contentView?.layoutSubtreeIfNeeded()
            } completionHandler: {
                toHide.forEach { $0.isHidden = hide }
            }
        } else {
            toHide.forEach { $0.isHidden = hide; $0.alphaValue = hide ? 0 : 1 }
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘. toggles minimalist mode; ⌘I opens the info popover.
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "." {
                toggleMinimalist(); return
            }
            if event.charactersIgnoringModifiers == "i" {
                infoTapped(infoButton); return
            }
        }
        super.keyDown(with: event)
    }

    @objc private func qualityChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.tag,
              let q = Quality(rawValue: UInt8(raw)) else { return }
        applyQuality(q)
    }

    /// Apply a new quality preset. Persists it, and if a client is connected
    /// pushes the change and shows the transition overlay while iOS restarts
    /// its capture/encoder pipeline.
    func applyQuality(_ q: Quality) {
        QualityStore.current = q
        qualityPopup.selectItem(withTag: Int(q.rawValue))
        guard currentClient != nil else { return }
        sawFirstFrame = false
        overlay.phase = .changingQuality(q)
        forwarder.sendQuality(q.rawValue)
        // If no new frame arrives within 4 s, fall back to the "authenticating"
        // overlay — the reconfiguration on the iPhone went wrong.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self else { return }
            if !self.sawFirstFrame, case .changingQuality = self.overlay.phase {
                self.overlay.phase = .authenticating
            }
        }
    }

    /// Shows an alert with a secure text field to enter the password.
    /// If `initial` is true, cancelling quits the app (no point running without one).
    func promptForPassword(initial: Bool) {
        let alert = NSAlert()
        alert.messageText = initial ? "Set up password" : "Change password"
        alert.informativeText = "This password encrypts all traffic between the iPhone and the Mac (AES-256-GCM). It must match the password=… line in /var/jb/etc/screenmirror.conf on the iPhone."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Minimum 8 characters"
        field.stringValue = Keychain.load() ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: initial ? "Quit" : "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pwd = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if pwd.count < 8 {
                let warn = NSAlert()
                warn.messageText = "Password too short"
                warn.informativeText = "Use at least 8 characters."
                warn.runModal()
                promptForPassword(initial: initial)
                return
            }
            Keychain.save(pwd)
            router.password = pwd
            setStatus("Password saved — waiting for client")
        } else if initial {
            NSApp.terminate(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.statusLabel.stringValue = s }
    }

    // MARK: - Hardware buttons

    /// Send a short press to a physical iPhone button.
    func pressDeviceButton(_ button: SMIRButton, hold: TimeInterval = 0.08) {
        guard currentClient != nil else {
            setStatus("No device connected")
            return
        }
        forwarder.pressButton(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            self.forwarder.pressButton(button, down: false)
        }
    }

    // MARK: - Gesture navigation

    /// Form factor (used to pick the right Control Center / App Switcher gesture).
    private enum DeviceForm { case homeButton, faceID, iPad }
    private var deviceForm: DeviceForm {
        guard let hs = handshake else { return .homeButton }
        let pw = max(1, CGFloat(hs.width)  / CGFloat(max(hs.scale, 1)))
        let ph = max(1, CGFloat(hs.height) / CGFloat(max(hs.scale, 1)))
        let aspect = max(pw, ph) / min(pw, ph)
        // iPad: 4:3 (≈1.33–1.43); iPhone Home: ~16:9 (1.78); iPhone Face-ID: 19.5:9 (2.16+).
        if aspect < 1.5 { return .iPad }
        if aspect > 1.95 { return .faceID }
        return .homeButton
    }
    private var iosMajor: Int { Int(handshake?.iosMajor ?? 0) }

    private func handleNav(_ action: NavBar.Action) {
        guard currentClient != nil else {
            setStatus("No device connected"); return
        }
        switch action {
        case .prevPage:
            forwarder.sendSwipe(from: CGPoint(x: 0.08, y: 0.5),
                                to:   CGPoint(x: 0.92, y: 0.5),
                                durationMs: 280)
        case .nextPage:
            forwarder.sendSwipe(from: CGPoint(x: 0.92, y: 0.5),
                                to:   CGPoint(x: 0.08, y: 0.5),
                                durationMs: 280)
        case .appSwitcher:
            switch deviceForm {
            case .homeButton:
                // Double-tap the Home button quickly.
                forwarder.pressButton(.home, down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.forwarder.pressButton(.home, down: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        self.forwarder.pressButton(.home, down: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.forwarder.pressButton(.home, down: false)
                        }
                    }
                }
            case .faceID, .iPad:
                // Swipe up from the home indicator and hold briefly.
                forwarder.sendSwipe(from: CGPoint(x: 0.5, y: 0.998),
                                    to:   CGPoint(x: 0.5, y: 0.55),
                                    durationMs: 600)
            }
        case .notifications:
            switch deviceForm {
            case .homeButton:
                forwarder.sendSwipe(from: CGPoint(x: 0.5, y: 0.0),
                                    to:   CGPoint(x: 0.5, y: 0.55),
                                    durationMs: 380)
            case .faceID, .iPad:
                // Top-left (clock area) pulls down Notification Center.
                forwarder.sendSwipe(from: CGPoint(x: 0.18, y: 0.0),
                                    to:   CGPoint(x: 0.5, y: 0.55),
                                    durationMs: 380)
            }
        }
    }

    // MARK: - Router callbacks

    /// Some pending connection just finished the encrypted handshake. We
    /// don't know yet whether it's *our* device — show "authenticating"
    /// in the overlay and wait. If the handshake comes through with a
    /// non-matching descriptor, `routerDidLoseClient` flips us back.
    func routerDidStartAuthenticating() {
        DispatchQueue.main.async {
            if !self.hasActiveClient { self.overlay.phase = .authenticating }
        }
    }

    /// The router has chosen this window for `connection`. Wire up
    /// state and push the saved quality preset to the device.
    func routerDidAcceptClient(_ connection: NWConnection, server: NetworkServer) {
        currentClient = connection
        forwarder.setClient(connection)
        sawFirstFrame = false
        DispatchQueue.main.async {
            self.overlay.phase = .authenticating
            self.forwarder.sendQuality(QualityStore.current.rawValue)
        }
        setStatus("Encrypted channel established — waiting for handshake")
    }

    /// A connection that briefly looked like ours went elsewhere (or
    /// disconnected). Return to the waiting overlay.
    func routerDidLoseClient() {
        DispatchQueue.main.async {
            if !self.hasActiveClient { self.overlay.phase = .waiting }
        }
    }

    func routerReceivedMessage(type: SMIRType, payload: Data, client: NWConnection) {
        switch type {
        case .handshake:
            guard let hs = SMIRHandshake.decode(payload) else { return }
            let descriptor = DeviceDescriptor.make(from: hs)
            self.handshake = hs
            let pointW = CGFloat(hs.width) / CGFloat(max(hs.scale, 1))
            let pointH = CGFloat(hs.height) / CGFloat(max(hs.scale, 1))
            self.deviceView.devicePointSize = CGSize(width: pointW, height: pointH)
            self.window?.title = "ScreenMirror — \(descriptor.displayName)"
            self.setStatus("Connected: \(hs.deviceName) \(Int(hs.width))×\(Int(hs.height))@\(hs.scale)x")

            let isLandscape = pointW > pointH
            if !self.didInitialAutoFit {
                self.didInitialAutoFit = true
                self.lastOrientationIsLandscape = isLandscape
                let autosaveName = NSWindow.FrameAutosaveName("ScreenMirror_\(descriptor.modelId)")
                self.window?.setFrameAutosaveName(autosaveName)
                let restored = self.window?.setFrameUsingName(autosaveName) ?? false
                let visible = (self.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                if !restored || !(self.window?.frame.intersects(visible) ?? false) {
                    self.autoFitWindow(toScreenFraction: 0.68)
                }
            } else if let last = self.lastOrientationIsLandscape, last != isLandscape {
                self.lastOrientationIsLandscape = isLandscape
                self.adaptWindowForOrientationChange(pointSize: CGSize(width: pointW, height: pointH))
            }

        case .videoConfig:
            guard payload.count >= 4 else { return }
            let spsLen = payload.readU32BE(at: 0)
            guard payload.count >= 4 + Int(spsLen) + 4 else { return }
            let sps = payload.subdata(in: 4..<(4 + Int(spsLen)))
            let ppsLen = payload.readU32BE(at: 4 + Int(spsLen))
            let ppsStart = 4 + Int(spsLen) + 4
            guard payload.count >= ppsStart + Int(ppsLen) else { return }
            let pps = payload.subdata(in: ppsStart..<(ppsStart + Int(ppsLen)))
            decoder.configure(spsLen: spsLen, sps: sps, ppsLen: ppsLen, pps: pps)

        case .videoFrame:
            guard payload.count > 12 else { return }
            let pts = payload.readU64BE(at: 4)
            let nal = payload.subdata(in: 12..<payload.count)
            decoder.decodeAnnexB(nal, pts: pts)
            if !sawFirstFrame {
                sawFirstFrame = true
                DispatchQueue.main.async { self.overlay.phase = .streaming }
            }

        case .ping:
            router.server.send(SMIRMessage(type: .pong, payload: payload), to: client)

        default: break
        }
    }

    func routerDidCloseClient(error: Error?) {
        if currentClient != nil {
            currentClient = nil
            forwarder.setClient(nil)
            sawFirstFrame = false
            setStatus(error.map { "Closed: \($0.localizedDescription)" } ?? "Waiting for device on :4878")
            DispatchQueue.main.async {
                self.overlay.phase = .disconnected
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if self.currentClient == nil { self.overlay.phase = .waiting }
                }
            }
        }
    }

    // MARK: - VideoDecoderDelegate

    func videoDecoder(_ d: VideoDecoder, didProduceSampleBuffer sb: CMSampleBuffer) {
        DispatchQueue.main.async {
            // Skip enqueue while the window is minimized or hidden — saves
            // GPU and the Mac display compositor. The iPhone keeps streaming
            // but we pay no rendering cost.
            if let win = self.window, win.isMiniaturized || win.occlusionState.contains(.visible) == false {
                return
            }
            self.deviceView.enqueue(sb)
        }
    }

    // MARK: - DeviceViewDelegate

    func deviceView(_ v: DeviceView, mouseEvent type: SMIRType, atNorm p: CGPoint) {
        forwarder.sendTouch(type, atNorm: p)
    }

    func deviceView(_ v: DeviceView, keyEvent code: UInt16, down: Bool) {
        forwarder.sendKey(usage: code, down: down)
    }

    func deviceView(_ v: DeviceView, typedText text: String) {
        forwarder.sendText(text)
    }

    // MARK: - Window sizing

    private func currentChromeHeight() -> CGFloat {
        guard let win = window else { return 110 }
        let titleBar = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100)).height - 100
        let bottomBar: CGFloat = isMinimalist ? 0 : 120
        return titleBar + bottomBar
    }

    func autoFitWindow(toScreenFraction fraction: CGFloat = 0.68) {
        guard let win = window else { return }
        guard let screen = win.screen ?? NSScreen.main else { return }
        let pSize = deviceView.devicePointSize
        guard pSize.width > 0 && pSize.height > 0 else { return }

        let avail = screen.visibleFrame
        let chromeH = currentChromeHeight()

        let maxH = avail.height * fraction
        let maxW = avail.width * 0.55

        var targetContentH = maxH - chromeH
        var targetContentW = targetContentH * (pSize.width / pSize.height)

        if targetContentW > maxW {
            targetContentW = maxW
            targetContentH = targetContentW * (pSize.height / pSize.width)
        }

        let finalW = max(targetContentW, win.minSize.width)
        let finalH = targetContentH + chromeH

        let x = avail.minX + max(0, (avail.width - finalW) / 2)
        let y = avail.minY + max(0, (avail.height - finalH) / 2)
        let newFrame = NSRect(x: x, y: y, width: finalW, height: finalH)
        win.setFrame(newFrame, display: true, animate: true)
    }

    func applyScaleFactor(_ scale: CGFloat) {
        guard let win = window else { return }
        guard let screen = win.screen ?? NSScreen.main else { return }
        let pSize = deviceView.devicePointSize
        guard pSize.width > 0 && pSize.height > 0 else { return }

        let avail = screen.visibleFrame
        let chromeH = currentChromeHeight()

        var contentW = pSize.width * scale
        var contentH = pSize.height * scale

        let maxContentH = avail.height * 0.90 - chromeH
        let maxContentW = avail.width * 0.90
        if contentH > maxContentH {
            contentH = maxContentH
            contentW = contentH * (pSize.width / pSize.height)
        }
        if contentW > maxContentW {
            contentW = maxContentW
            contentH = contentW * (pSize.height / pSize.width)
        }

        let finalW = max(contentW, win.minSize.width)
        let finalH = contentH + chromeH

        let curCenter = CGPoint(x: win.frame.midX, y: win.frame.midY)
        var x = curCenter.x - finalW / 2
        var y = curCenter.y - finalH / 2

        if x < avail.minX { x = avail.minX }
        if x + finalW > avail.maxX { x = avail.maxX - finalW }
        if y < avail.minY { y = avail.minY }
        if y + finalH > avail.maxY { y = avail.maxY - finalH }

        let newFrame = NSRect(x: x, y: y, width: finalW, height: finalH)
        win.setFrame(newFrame, display: true, animate: true)
    }

    private func adaptWindowForOrientationChange(pointSize: CGSize) {
        guard let win = window else { return }
        guard let screen = win.screen ?? NSScreen.main else { return }
        let avail = screen.visibleFrame
        let chromeH = currentChromeHeight()

        let curContentW = win.frame.width
        let curContentH = max(win.frame.height - chromeH, 50)
        let approxArea = curContentW * curContentH
        let aspect = pointSize.width / pointSize.height

        var newContentH = sqrt(approxArea / aspect)
        var newContentW = newContentH * aspect

        let maxContentH = avail.height * 0.85 - chromeH
        let maxContentW = avail.width * 0.85
        if newContentH > maxContentH {
            newContentH = maxContentH
            newContentW = newContentH * aspect
        }
        if newContentW > maxContentW {
            newContentW = maxContentW
            newContentH = newContentW / aspect
        }

        let finalW = max(newContentW, win.minSize.width)
        let finalH = newContentH + chromeH

        let curCenter = CGPoint(x: win.frame.midX, y: win.frame.midY)
        var x = curCenter.x - finalW / 2
        var y = curCenter.y - finalH / 2

        if x < avail.minX { x = avail.minX }
        if x + finalW > avail.maxX { x = avail.maxX - finalW }
        if y < avail.minY { y = avail.minY }
        if y + finalH > avail.maxY { y = avail.maxY - finalH }

        let newFrame = NSRect(x: x, y: y, width: finalW, height: finalH)
        win.setFrame(newFrame, display: true, animate: true)
    }

    @objc func viewFitToScreen() { autoFitWindow(toScreenFraction: 0.68) }
    @objc func viewScale100()    { applyScaleFactor(1.0) }
    @objc func viewScale75()     { applyScaleFactor(0.75) }
    @objc func viewScale67()     { applyScaleFactor(0.67) }
    @objc func viewScale50()     { applyScaleFactor(0.50) }
}
