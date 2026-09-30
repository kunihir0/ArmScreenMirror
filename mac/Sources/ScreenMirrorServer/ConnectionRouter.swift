import Foundation
import Network
import AppKit

/// One TCP listener can only bind to port 4878 once, so we centralize
/// every NetworkServer event here and fan it out to whichever streaming
/// window actually expects this device. The router keeps a list of open
/// MainWindowControllers and matches incoming SMIR_HANDSHAKE messages
/// against each window's `targetDevice`. Connections that don't match any
/// open window are dropped.
///
/// Routing happens *after* the X25519+password handshake completes — only
/// then does the iPhone identify itself via SMIR_HANDSHAKE. Until that
/// message arrives the connection is "pending" and not assigned to a
/// window; if the iPhone disconnects without sending a handshake, the
/// pending entry is just thrown away.
final class ConnectionRouter: NetworkServerDelegate {

    static let shared = ConnectionRouter()

    let server = NetworkServer(port: 4878)

    private struct WeakWindow { weak var ref: MainWindowController? }
    private var windows: [WeakWindow] = []

    /// Connections that have completed the encrypted handshake but haven't
    /// yet sent SMIR_HANDSHAKE. Kept so we can close them if no window
    /// claims them within a reasonable time (or when the connection drops
    /// before identifying).
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var routed:  [ObjectIdentifier: MainWindowController] = [:]

    private init() {
        server.delegate = self
    }

    var password: String {
        get { server.password }
        set { server.password = newValue }
    }

    func start() throws { try server.start() }

    /// Register a streaming window so it can receive routed traffic.
    func register(_ window: MainWindowController) {
        windows.append(WeakWindow(ref: window))
        purgeDeadWindows()
    }

    func unregister(_ window: MainWindowController) {
        // Drop any connections currently routed to the closing window so
        // they don't stay tied to a dead controller.
        for (key, w) in routed where w === window {
            if let conn = activeConnection(forKey: key) { conn.cancel() }
            routed.removeValue(forKey: key)
        }
        windows.removeAll { $0.ref === window || $0.ref == nil }
    }

    /// Look up a still-known connection by its identifier. Connections
    /// in `pending` may have been promoted to `routed` by the time we
    /// check, so we search both.
    private func activeConnection(forKey key: ObjectIdentifier) -> NWConnection? {
        return pending[key]
    }

    private func purgeDeadWindows() {
        windows.removeAll { $0.ref == nil }
    }

    private func livingWindows() -> [MainWindowController] {
        purgeDeadWindows()
        return windows.compactMap { $0.ref }
    }

    // MARK: - NetworkServerDelegate

    func networkServer(_ s: NetworkServer, didAcceptClient connection: NWConnection) {
        // Hold until the device handshake reveals which window wants this
        // connection. Notify *all* living windows so each can move from
        // "waiting" to "authenticating" — they'll be filtered down to one
        // when the handshake arrives.
        pending[ObjectIdentifier(connection)] = connection
        for w in livingWindows() { w.routerDidStartAuthenticating() }
    }

    func networkServer(_ s: NetworkServer,
                       client: NWConnection,
                       didReceive type: SMIRType,
                       payload: Data) {
        let key = ObjectIdentifier(client)

        // Already routed → forward verbatim.
        if let target = routed[key] {
            target.routerReceivedMessage(type: type, payload: payload, client: client)
            return
        }

        // First message must be the device handshake. Anything else
        // before that is unexpected — ignore it (the iOS tweak only
        // sends video/buttons after handshake anyway).
        guard type == .handshake,
              let hs = SMIRHandshake.decode(payload) else { return }

        let descriptor = DeviceDescriptor.make(from: hs)
        DeviceHistory.touch(descriptor)

        // Pick the first window that claims this device. Exact match
        // wins over the catch-all "Listen for any" window.
        let alive = livingWindows()
        let exact = alive.first { $0.targetDevice == descriptor && !$0.hasActiveClient }
        let any   = alive.first { $0.targetDevice == nil          && !$0.hasActiveClient }
        var chosenWin = exact ?? any
        if chosenWin == nil {
            if Thread.isMainThread {
                if let appDel = NSApp.delegate as? AppDelegate {
                    chosenWin = appDel.openStreamingWindow(for: descriptor)
                }
            } else {
                DispatchQueue.main.sync {
                    if let appDel = NSApp.delegate as? AppDelegate {
                        chosenWin = appDel.openStreamingWindow(for: descriptor)
                    }
                }
            }
        }
        guard let win = chosenWin else {
            NSLog("[Router] no window for %@; dropping connection", descriptor.modelId)
            client.cancel()
            pending.removeValue(forKey: key)
            return
        }
        routed[key] = win
        pending.removeValue(forKey: key)

        // Hand over: tell windows that didn't get it to fall back, then
        // give the chosen window the accept + handshake message in order.
        for other in alive where other !== win {
            other.routerDidLoseClient()
        }
        win.routerDidAcceptClient(client, server: s)
        win.routerReceivedMessage(type: .handshake, payload: payload, client: client)
    }

    func networkServer(_ s: NetworkServer,
                       client: NWConnection,
                       didCloseWith error: Error?) {
        let key = ObjectIdentifier(client)
        if let target = routed.removeValue(forKey: key) {
            target.routerDidCloseClient(error: error)
        } else if pending.removeValue(forKey: key) != nil {
            // Closed before identifying — let every "waiting" window
            // know so they can return to the idle/waiting overlay.
            for w in livingWindows() { w.routerDidLoseClient() }
        }
    }
}
