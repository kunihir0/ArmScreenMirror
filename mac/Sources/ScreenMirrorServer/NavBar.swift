import AppKit

/// Barra superior con accesos rápidos por gestos: páginas anterior/siguiente,
/// App Switcher, Centro de Control, Notificaciones. Mismo lenguaje visual que
/// ButtonBar (NSVisualEffectView, IconButton circular).
final class NavBar: NSView {

    enum Action {
        case prevPage
        case nextPage
        case appSwitcher
        case notifications
    }

    var handler: ((Action) -> Void)?

    private let bg = NSVisualEffectView()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        stack.orientation = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let bottomBorder = NSView()
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)

        struct Spec {
            let action: Action
            let title: String
            let symbol: String
            let key: String
            let modifiers: NSEvent.ModifierFlags
            let tint: NSColor?
        }
        let specs: [Spec] = [
            .init(action: .prevPage,      title: "Previous Page",   symbol: "chevron.backward.2",     key: "[", modifiers: [.command], tint: .systemTeal),
            .init(action: .nextPage,      title: "Next Page",       symbol: "chevron.forward.2",      key: "]", modifiers: [.command], tint: .systemTeal),
            .init(action: .appSwitcher,   title: "App Switcher",    symbol: "rectangle.on.rectangle", key: "h", modifiers: [.command, .shift], tint: .systemBlue),
            .init(action: .notifications, title: "Notifications",   symbol: "bell.fill",              key: "n", modifiers: [.command], tint: .systemOrange),
        ]

        for (i, spec) in specs.enumerated() {
            let isPageNav = (spec.action == .prevPage || spec.action == .nextPage)
            let b = IconButton()
            b.translatesAutoresizingMaskIntoConstraints = false
            b.symbolName = spec.symbol
            b.symbolPointSize = isPageNav ? 14 : 17
            b.tint = spec.tint
            b.shape = isPageNav ? .capsule : .circle
            b.toolTip = "\(spec.title)  \(modString(spec.modifiers))\(displayKey(spec.key))"
            b.keyEquivalent = spec.key
            b.keyEquivalentModifierMask = spec.modifiers
            b.holdMode = false
            b.onTap = { [weak self] in self?.handler?(spec.action) }
            // Páginas: cápsula más ancha, otros: círculo 36×36.
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: isPageNav ? 48 : 36),
                b.heightAnchor.constraint(equalToConstant: 32),
            ])
            stack.addArrangedSubview(b)

            if i == 1 {
                let sep = NSBox()
                sep.boxType = .custom
                sep.fillColor = NSColor.separatorColor.withAlphaComponent(0.6)
                sep.borderWidth = 0
                sep.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    sep.widthAnchor.constraint(equalToConstant: 1),
                    sep.heightAnchor.constraint(equalToConstant: 20),
                ])
                stack.addArrangedSubview(sep)
            }
        }

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),

            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 0.5),

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

    private func displayKey(_ k: String) -> String {
        switch k {
        case "[":  return "["
        case "]":  return "]"
        default:   return k.uppercased()
        }
    }
}
