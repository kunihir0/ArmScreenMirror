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

    private struct RoutedConnection {
        weak var window: MainWindowController?
        let connection: NWConnection
    }

    /// Connections that have completed the encrypted handshake but haven't
    /// yet sent SMIR_HANDSHAKE. Kept so we can close them if no window
    /// claims them within a reasonable time (or when the connection drops
    /// before identifying).
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var routed:  [ObjectIdentifier: RoutedConnection] = [:]

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
        dispatchToMain { [self] in
            windows.append(WeakWindow(ref: window))
            purgeDeadWindows()
        }
    }

    func unregister(_ window: MainWindowController) {
        // Drop any connections currently routed to the closing window so
        // they don't stay tied to a dead controller.
        dispatchToMain { [self] in
            let keysToDrop = routed.filter { $0.value.window === window }.map { $0.key }
            for key in keysToDrop {
                if let rc = routed.removeValue(forKey: key) {
                    rc.connection.cancel()
                }
            }
            windows.removeAll { $0.ref === window || $0.ref == nil }
        }
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
        dispatchToMain { [self] in
            // Hold until the device handshake reveals which window wants this
            // connection. Notify *all* living windows so each can move from
            // "waiting" to "authenticating" — they'll be filtered down to one
            // when the handshake arrives.
            pending[ObjectIdentifier(connection)] = connection
            for w in livingWindows() { w.routerDidStartAuthenticating() }
        }
    }

    func networkServer(_ s: NetworkServer,
                       client: NWConnection,
                       didReceive type: SMIRType,
                       payload: Data) {
        dispatchToMain { [self] in
            let key = ObjectIdentifier(client)

            // Already routed → forward verbatim.
            if let target = routed[key]?.window {
                target.routerReceivedMessage(type: type, payload: payload, client: client)
                return
            }

            // First message must be the device handshake. Anything else
            // before that is unexpected: cancel the connection and purge from pending.
            guard type == .handshake,
                  let hs = SMIRHandshake.decode(payload) else {
                NSLog("[Router] unexpected non-handshake message (0x%02x) on unrouted connection; dropping", type.rawValue)
                client.cancel()
                pending.removeValue(forKey: key)
                return
            }

            let descriptor = DeviceDescriptor.make(from: hs)
            DeviceHistory.touch(descriptor)

            // Pick the first window that claims this device. Exact match
            // wins over the catch-all "Listen for any" window.
            let alive = livingWindows()
            let exact = alive.first { $0.targetDevice == descriptor && !$0.hasActiveClient }
            let any   = alive.first { $0.targetDevice == nil          && !$0.hasActiveClient }
            var chosenWin = exact ?? any
            if chosenWin == nil {
                if let appDel = NSApp.delegate as? AppDelegate {
                    chosenWin = appDel.openStreamingWindow(for: descriptor)
                }
            }
            guard let win = chosenWin else {
                NSLog("[Router] no window for %@; dropping connection", descriptor.modelId)
                client.cancel()
                pending.removeValue(forKey: key)
                return
            }
            routed[key] = RoutedConnection(window: win, connection: client)
            pending.removeValue(forKey: key)

            // Hand over: tell windows that didn't get it to fall back, then
            // give the chosen window the accept + handshake message in order.
            for other in alive where other !== win {
                other.routerDidLoseClient()
            }
            win.routerDidAcceptClient(client, server: s)
            win.routerReceivedMessage(type: .handshake, payload: payload, client: client)
        }
    }

    func networkServer(_ s: NetworkServer,
                       client: NWConnection,
                       didCloseWith error: Error?) {
        dispatchToMain { [self] in
            let key = ObjectIdentifier(client)
            if let rc = routed.removeValue(forKey: key) {
                rc.window?.routerDidCloseClient(error: error)
            } else if pending.removeValue(forKey: key) != nil {
                // Closed before identifying — let every "waiting" window
                // know so they can return to the idle/waiting overlay.
                for w in livingWindows() { w.routerDidLoseClient() }
            }
        }
    }

    private func dispatchToMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
