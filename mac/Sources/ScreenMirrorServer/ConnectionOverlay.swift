import AppKit

/// Pantalla negra con icono pulsante + estado y subtexto, visible mientras
/// no hay vídeo. Oculta con fundido cuando llega el primer frame.
final class ConnectionOverlay: NSView {

    enum Phase: Equatable {
        case idle
        case waiting
        case authenticating
        case streaming
        case disconnected
        case changingQuality(Quality)

        var title: String {
            switch self {
            case .idle:                       return "Starting…"
            case .waiting:                    return "Waiting for device"
            case .authenticating:             return "Encrypting channel"
            case .streaming:                  return ""
            case .disconnected:               return "Connection closed"
            case .changingQuality(let q):     return "Applying \(q.label) quality"
            }
        }
        var subtitle: String {
            switch self {
            case .idle:                       return "Preparing secure server"
            case .waiting:                    return "Bonjour _smirror._tcp.  •  TCP :4878"
            case .authenticating:             return "Negotiating AES-256-GCM key (PBKDF2-SHA512 + X25519)"
            case .streaming:                  return ""
            case .disconnected:               return "The iPhone has disconnected"
            case .changingQuality(let q):     return "Restarting capture at \(Int(q.scale * 100))% • \(q.fps) fps • \(q.bitrate / 1000) Kbps"
            }
        }
        var symbol: String {
            switch self {
            case .idle:                       return "shield"
            case .waiting:                    return "antenna.radiowaves.left.and.right"
            case .authenticating:             return "lock.shield.fill"
            case .streaming:                  return ""
            case .disconnected:               return "exclamationmark.shield.fill"
            case .changingQuality:            return "slider.horizontal.3"
            }
        }
        var tint: NSColor {
            switch self {
            case .idle, .waiting:             return .systemBlue
            case .authenticating:             return .systemGreen
            case .streaming:                  return .clear
            case .disconnected:               return .systemOrange
            case .changingQuality:            return .systemPurple
            }
        }
    }

    var phase: Phase = .idle {
        didSet { if phase != oldValue { animateTo(phase) } }
    }

    private let bgLayer  = CALayer()
    private let icon     = NSImageView()
    private let ring     = CAShapeLayer()
    private let pulse    = CAShapeLayer()
    private let titleLabel    = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let dotsLabel     = NSTextField(labelWithString: "")
    private var dotsTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        bgLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(bgLayer)
        layer = root
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        // Anillo + pulso detrás del icono
        ring.fillColor   = NSColor.clear.cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        ring.lineWidth   = 1.5
        root.addSublayer(ring)

        pulse.fillColor   = NSColor.clear.cgColor
        pulse.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
        pulse.lineWidth   = 2
        root.addSublayer(pulse)

        // Icono central (NSImageView para template + tint)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .systemBlue
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .medium)
        addSubview(icon)

        // Textos
        titleLabel.font            = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor       = NSColor.white.withAlphaComponent(0.92)
        titleLabel.alignment       = .center
        titleLabel.isBezeled       = false
        titleLabel.drawsBackground = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font            = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor       = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.alignment       = .center
        subtitleLabel.isBezeled       = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        dotsLabel.font            = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        dotsLabel.textColor       = NSColor.white.withAlphaComponent(0.55)
        dotsLabel.alignment       = .center
        dotsLabel.isBezeled       = false
        dotsLabel.drawsBackground = false
        dotsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotsLabel)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -34),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 22),

            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            dotsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotsLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
        ])

        animateTo(phase)
        startDotsAnimation()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds
        let r: CGFloat = 56
        let pulseR: CGFloat = 80
        let center = CGPoint(x: bounds.midX, y: bounds.midY + 34)  // bottom-up
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2),
                           transform: nil)
        pulse.frame = bounds
        pulse.path = CGPath(ellipseIn: CGRect(x: center.x - pulseR, y: center.y - pulseR, width: pulseR*2, height: pulseR*2),
                            transform: nil)
        // El centro CALayer en NSView con isFlipped=false es bottom-up.
    }

    // MARK: - Animations

    private func animateTo(_ p: Phase) {
        if p == .streaming {
            stopDotsAnimation()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.allowsImplicitAnimation = true
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isHidden = true
            })
            return
        }

        isHidden = false
        if alphaValue < 1.0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                self.animator().alphaValue = 1.0
            }
        }

        if let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title) {
            icon.image = img
        }
        icon.contentTintColor = p.tint
        ring.strokeColor = p.tint.withAlphaComponent(0.18).cgColor
        pulse.strokeColor = p.tint.withAlphaComponent(0.45).cgColor

        titleLabel.stringValue    = p.title
        subtitleLabel.stringValue = p.subtitle

        // Pulso del anillo grande: escala+fade contínuo
        pulse.removeAllAnimations()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue   = 1.25
        scale.duration  = 1.6
        scale.repeatCount = .infinity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue   = 0.0
        fade.duration  = 1.6
        fade.repeatCount = .infinity
        pulse.add(scale, forKey: "scale")
        pulse.add(fade, forKey: "fade")

        // Icono "respira" (escala 1.0 ↔ 1.06)
        let layer = icon.layer ?? CALayer()
        icon.wantsLayer = true
        if let l = icon.layer {
            l.removeAnimation(forKey: "breath")
            let breath = CABasicAnimation(keyPath: "transform.scale")
            breath.fromValue = 1.0
            breath.toValue   = 1.06
            breath.duration  = 1.0
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(breath, forKey: "breath")
        }
        _ = layer
    }

    // Dots "..." animados: . → .. → ... → vacío
    private func startDotsAnimation() {
        stopDotsAnimation()
        var step = 0
        dotsTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            step = (step + 1) % 4
            self.dotsLabel.stringValue = String(repeating: "•", count: step)
        }
        if let t = dotsTimer { RunLoop.main.add(t, forMode: .common) }
    }
    private func stopDotsAnimation() {
        dotsTimer?.invalidate()
        dotsTimer = nil
        dotsLabel.stringValue = ""
    }
}
