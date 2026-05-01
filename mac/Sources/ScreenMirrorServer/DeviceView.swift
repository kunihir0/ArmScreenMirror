import AppKit
import AVFoundation
import CoreMedia

protocol DeviceViewDelegate: AnyObject {
    func deviceView(_ v: DeviceView, mouseEvent type: SMIRType, atNorm: CGPoint)
    func deviceView(_ v: DeviceView, keyEvent code: UInt16, down: Bool)
    func deviceView(_ v: DeviceView, typedText text: String)
}

final class DeviceView: NSView {
    weak var delegate: DeviceViewDelegate?

    /// Tamaño lógico (puntos) de la pantalla del iPhone, p.ej. (390, 844).
    var devicePointSize: CGSize = CGSize(width: 390, height: 844) {
        didSet { needsLayout = true; layout() }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var trackingArea: NSTrackingArea?
    private var mouseDown = false
    private var lastTouchNorm = CGPoint.zero
    /// Distancia mínima entre puntos de touchMove en coords del iPhone (puntos lógicos).
    /// Por debajo, no enviamos eventos redundantes; por encima interpolamos.
    private let interpolationStep: CGFloat = 4.0

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.darkGray.cgColor   // marco visible
        layer = root
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(displayLayer)
    }

    override func makeBackingLayer() -> CALayer {
        return CALayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Mantener aspecto del dispositivo dentro de la vista.
        let v = bounds
        let aspect = devicePointSize.width / devicePointSize.height
        let viewAspect = v.width / v.height
        var rect = v
        if viewAspect > aspect {
            let w = v.height * aspect
            rect = NSRect(x: (v.width - w) / 2, y: 0, width: w, height: v.height)
        } else {
            let h = v.width / aspect
            rect = NSRect(x: 0, y: (v.height - h) / 2, width: v.width, height: h)
        }
        displayLayer.frame = rect
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    func enqueue(_ sb: CMSampleBuffer) {
        if displayLayer.status == .failed {
            NSLog("[DeviceView] layer failed, flush err=%@", String(describing: displayLayer.error))
            displayLayer.flush()
        }
        displayLayer.enqueue(sb)
    }

    // MARK: - Eventos de mouse → toques

    /// Convierte un NSPoint (coords del view, origen abajo-izquierda) a
    /// coordenadas normalizadas [0,1] del iPhone (origen arriba-izquierda).
    /// Importante: NO devuelve nil si el cursor sale del area del display —
    /// clamp a [0,1] para que los gestos de swipe sigan viajando aunque el
    /// usuario arrastre fuera de los límites del iPhone en la ventana del Mac.
    private func normalize(_ p: NSPoint) -> CGPoint {
        let f = displayLayer.frame
        let w = max(f.width, 1)
        let h = max(f.height, 1)
        let x = (p.x - f.minX) / w
        let y = 1.0 - (p.y - f.minY) / h
        return CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y)))
    }

    override func mouseDown(with event: NSEvent) {
        let n = normalize(convert(event.locationInWindow, from: nil))
        mouseDown = true
        lastTouchNorm = n
        delegate?.deviceView(self, mouseEvent: .touchDown, atNorm: n)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDown else { return }
        let n = normalize(convert(event.locationInWindow, from: nil))
        sendInterpolatedMoves(to: n)
        lastTouchNorm = n
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDown else { return }
        let n = normalize(convert(event.locationInWindow, from: nil))
        // Antes del touchUp, asegúrate de que iOS recibió el punto final
        // exacto — clave para que el gesture recognizer compute la velocidad
        // correcta y haga "commit" del swipe.
        sendInterpolatedMoves(to: n)
        delegate?.deviceView(self, mouseEvent: .touchUp, atNorm: n)
        mouseDown = false
    }

    /// Interpola múltiples puntos entre `lastTouchNorm` y `target` para que
    /// iOS tenga densidad suficiente para calcular velocidad y commit-ear
    /// gestures como swipe entre páginas o app switcher. Usa coords en
    /// puntos del iPhone (devicePointSize) para decidir cuántos pasos.
    private func sendInterpolatedMoves(to target: CGPoint) {
        let from = lastTouchNorm
        let dxNorm = target.x - from.x
        let dyNorm = target.y - from.y
        // Distancia en puntos del iPhone:
        let dxPts = dxNorm * devicePointSize.width
        let dyPts = dyNorm * devicePointSize.height
        let dist = sqrt(dxPts * dxPts + dyPts * dyPts)
        // Pasos: 1 cada `interpolationStep` puntos, mínimo 1, máximo 16
        // (más de 16 saturaría TCP innecesariamente).
        let steps = max(1, min(16, Int(ceil(dist / interpolationStep))))
        guard steps > 0 else { return }
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + dxNorm * t, y: from.y + dyNorm * t)
            delegate?.deviceView(self, mouseEvent: .touchMove, atNorm: p)
        }
    }

    // Si el ratón sale de la ventana mientras se arrastra, AppKit deja
    // de mandar mouseDragged. mouseExited mantiene el último estado.
    override func mouseExited(with event: NSEvent) {
        // No-op: AppKit sigue mandando mouseDragged y mouseUp aunque el
        // cursor esté fuera del view, mientras el botón esté presionado.
    }

    // Scroll vertical → swipe vertical en el iPhone.
    override func scrollWheel(with event: NSEvent) {
        let center = normalize(convert(event.locationInWindow, from: nil))
        let delta: CGFloat = event.scrollingDeltaY / max(bounds.height, 1)
        let from = CGPoint(x: center.x, y: max(0, min(1, center.y + delta * 0.5)))
        let to   = CGPoint(x: center.x, y: max(0, min(1, center.y - delta * 0.5)))
        delegate?.deviceView(self, mouseEvent: .touchDown, atNorm: from)
        delegate?.deviceView(self, mouseEvent: .touchMove, atNorm: to)
        delegate?.deviceView(self, mouseEvent: .touchUp,   atNorm: to)
    }

    // MARK: - Teclas

    override func keyDown(with event: NSEvent) {
        if let s = event.charactersIgnoringModifiers, !s.isEmpty,
           !event.modifierFlags.contains(.command) {
            delegate?.deviceView(self, typedText: s)
            return
        }
        let usage = mapKeyCodeToHIDUsage(event.keyCode)
        delegate?.deviceView(self, keyEvent: usage, down: true)
    }

    override func keyUp(with event: NSEvent) {
        let usage = mapKeyCodeToHIDUsage(event.keyCode)
        delegate?.deviceView(self, keyEvent: usage, down: false)
    }
}

// AppKit virtual keycodes (subset) -> HID Usage IDs (page 0x07)
private func mapKeyCodeToHIDUsage(_ kc: UInt16) -> UInt16 {
    switch kc {
    case 0x33: return 0x2A // delete
    case 0x24: return 0x28 // return
    case 0x35: return 0x29 // escape
    case 0x30: return 0x2B // tab
    case 0x31: return 0x2C // space
    case 0x7B: return 0x50 // left
    case 0x7C: return 0x4F // right
    case 0x7D: return 0x51 // down
    case 0x7E: return 0x52 // up
    default:   return 0
    }
}
