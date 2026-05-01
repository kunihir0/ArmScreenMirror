import AppKit

/// Barra inferior con los botones físicos del iPhone, estilo macOS Control
/// Center: NSVisualEffectView de fondo, botones circulares con SF Symbols,
/// animación sutil al hover y al press.
final class ButtonBar: NSView {

    var handler:    ((SMIRButton) -> Void)?           // tap corto
    var holdHandler: ((SMIRButton, Bool) -> Void)?    // mouseDown/Up reales (Siri)

    private let bg = NSVisualEffectView()
    private let stack = NSStackView()

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.wantsLayer = true
        addSubview(bg)

        stack.orientation = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let topBorder = NSView()
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        struct Spec {
            let id: SMIRButton
            let title: String
            let symbol: String
            let key: String
            let modifiers: NSEvent.ModifierFlags
            let hold: Bool
            let tint: NSColor?
        }
        let specs: [Spec] = [
            .init(id: .home,    title: "Home",     symbol: "house.fill",            key: "h", modifiers: [.command],         hold: false, tint: .controlAccentColor),
            .init(id: .lock,    title: "Lock",     symbol: "lock.fill",             key: "l", modifiers: [.command],         hold: false, tint: nil),
            .init(id: .volDown, title: "Vol −",    symbol: "speaker.wave.1.fill",   key: "-", modifiers: [.command],         hold: false, tint: nil),
            .init(id: .mute,    title: "Mute",     symbol: "speaker.slash.fill",    key: "m", modifiers: [.command],         hold: false, tint: .systemRed),
            .init(id: .volUp,   title: "Vol +",    symbol: "speaker.wave.3.fill",   key: "+", modifiers: [.command],         hold: false, tint: nil),
            .init(id: .siri,    title: "Siri",     symbol: "waveform.circle.fill",  key: "s", modifiers: [.command,.shift],  hold: true,  tint: .systemPurple),
        ]

        // Insertamos separador visual entre el bloque Inicio/Lock y Volumen.
        for (i, spec) in specs.enumerated() {
            let b = IconButton()
            b.translatesAutoresizingMaskIntoConstraints = false
            b.symbolName = spec.symbol
            b.tint = spec.tint
            b.toolTip = "\(spec.title)  \(modString(spec.modifiers))\(spec.key.uppercased())"
            b.keyEquivalent = spec.key
            b.keyEquivalentModifierMask = spec.modifiers
            b.holdMode = spec.hold
            b.onTap   = { [weak self] in
                if !spec.hold { self?.handler?(spec.id) }
            }
            b.onPress = { [weak self] down in
                if spec.hold { self?.holdHandler?(spec.id, down) }
            }
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 38),
                b.heightAnchor.constraint(equalToConstant: 38),
            ])
            stack.addArrangedSubview(b)

            if i == 1 || i == 4 {
                let sep = NSBox()
                sep.boxType = .custom
                sep.fillColor = NSColor.separatorColor.withAlphaComponent(0.6)
                sep.borderWidth = 0
                sep.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    sep.widthAnchor.constraint(equalToConstant: 1),
                    sep.heightAnchor.constraint(equalToConstant: 22),
                ])
                stack.addArrangedSubview(sep)
            }
        }

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),

            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func modString(_ m: NSEvent.ModifierFlags) -> String {
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s
    }
}

/// Botón circular con SF Symbol al estilo Control Center.
/// - Hover: fondo se aclara levemente.
/// - Press: fondo se oscurece y el icono encoge un poquito.
/// - holdMode=true: dispara onPress(true) en mouseDown y onPress(false) en mouseUp.
/// - holdMode=false: dispara onTap() al soltar el ratón dentro del botón.
final class IconButton: NSView {
    enum Shape { case circle, capsule }

    var symbolName: String = "" { didSet { updateImage() } }
    var symbolPointSize: CGFloat = 17 { didSet { updateImage() } }
    var tint: NSColor? = nil    { didSet { updateImage() } }
    var shape: Shape = .circle  { didSet { needsLayout = true } }
    var holdMode: Bool = false
    var onTap:   (() -> Void)?
    var onPress: ((Bool) -> Void)?

    var keyEquivalent: String = ""
    var keyEquivalentModifierMask: NSEvent.ModifierFlags = []

    private let bgLayer = CALayer()
    private let imageLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { updateBackground() } }
    private var isPressed  = false { didSet { updateBackground(); updateImageScale() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = CALayer()
        root.addSublayer(bgLayer)
        root.addSublayer(imageLayer)
        layer = root

        bgLayer.cornerCurve = .continuous
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = false

        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds
        // Píldora horizontal o círculo (mismo radio si shape==circle).
        bgLayer.cornerRadius = (shape == .circle) ? bounds.height / 2 : min(bounds.width, bounds.height) / 2
        let inset: CGFloat = (shape == .capsule) ? 7 : 9
        imageLayer.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true  }
    override func mouseExited(with event: NSEvent)  { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        if holdMode { onPress?(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if isPressed != inside { isPressed = inside }
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if holdMode { onPress?(false) }
        else if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onTap?()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == keyEquivalent.lowercased() else {
            return false
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == keyEquivalentModifierMask else { return false }
        if holdMode {
            onPress?(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.onPress?(false) }
        } else {
            onTap?()
        }
        flashPressed()
        return true
    }

    private func flashPressed() {
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.isPressed = false }
    }

    // MARK: - Visual

    private func updateImage() {
        guard !symbolName.isEmpty,
              let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName) else {
            imageLayer.contents = nil
            return
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        let sized = img.withSymbolConfiguration(cfg) ?? img
        // Tintamos al color deseado (o al label color por defecto).
        let color = tint ?? NSColor.labelColor
        let tinted = NSImage(size: sized.size, flipped: false) { rect in
            sized.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        imageLayer.contents = tinted
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func updateBackground() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        let base = dark ? NSColor.white : NSColor.black
        let alpha: CGFloat = isPressed ? 0.16 : (isHovering ? 0.10 : 0.06)
        let color = base.withAlphaComponent(alpha).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        bgLayer.backgroundColor = color
        CATransaction.commit()
    }

    private func updateImageScale() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.10)
        imageLayer.transform = isPressed
            ? CATransform3DMakeScale(0.88, 0.88, 1)
            : CATransform3DIdentity
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
        updateImage()
    }
}
