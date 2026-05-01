import Foundation
import Network
import CoreGraphics

/// Empaqueta eventos de input (Mac) y los manda al iPhone.
final class EventForwarder {
    private weak var server: NetworkServer?
    private weak var conn: NWConnection?

    init(server: NetworkServer) {
        self.server = server
    }

    func setClient(_ c: NWConnection?) { self.conn = c }

    private func send(_ type: SMIRType, _ payload: Data) {
        guard let server = server, let conn = conn else { return }
        server.send(SMIRMessage(type: type, payload: payload), to: conn)
    }

    func sendTouch(_ type: SMIRType, fingerId: UInt8 = 0, atNorm p: CGPoint) {
        var d = Data()
        d.append(fingerId); d.append(contentsOf: [0,0,0])
        var x = Float(p.x).bitPattern.bigEndian
        var y = Float(p.y).bitPattern.bigEndian
        withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &y) { d.append(contentsOf: $0) }
        send(type, d)
    }

    /// Manda al iPhone el preset de calidad (0=low, 1=medium, 2=high).
    /// El iOS reinicia su pipeline de captura + encoder con los parámetros
    /// del preset y emite un nuevo VIDEO_CONFIG con SPS/PPS adecuados.
    func sendQuality(_ preset: UInt8) {
        var d = Data()
        d.append(preset)
        send(.quality, d)
    }

    /// Le pide al iPhone que sintetice un swipe localmente con timing real.
    /// Mucho más fiable que dispatch_after en Mac + jitter de red.
    func sendSwipe(from: CGPoint, to: CGPoint, durationMs: UInt32) {
        var d = Data()
        for f in [Float(from.x), Float(from.y), Float(to.x), Float(to.y)] {
            var bits = f.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { d.append(contentsOf: $0) }
        }
        var ms = durationMs.bigEndian
        withUnsafeBytes(of: &ms) { d.append(contentsOf: $0) }
        send(.swipe, d)
    }

    func sendKey(usage: UInt16, down: Bool) {
        guard usage != 0 else { return }
        var d = Data()
        d.append(contentsOf: usage.bigEndianBytes)
        d.append(down ? 1 : 0); d.append(0)
        send(.keyEvent, d)
    }

    func sendText(_ s: String) {
        guard let utf8 = s.data(using: .utf8) else { return }
        var d = Data()
        d.append(contentsOf: UInt32(utf8.count).bigEndianBytes)
        d.append(utf8)
        send(.textInput, d)
    }

    func pressButton(_ button: SMIRButton, down: Bool) {
        var d = Data()
        d.append(button.rawValue)
        d.append(down ? 1 : 0)
        d.append(contentsOf: [0,0])
        send(.buttonEvent, d)
    }
}
