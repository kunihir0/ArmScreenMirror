import Foundation
import Network
import CryptoKit

protocol NetworkServerDelegate: AnyObject {
    func networkServer(_ s: NetworkServer, didAcceptClient connection: NWConnection)
    func networkServer(_ s: NetworkServer, client: NWConnection, didReceive type: SMIRType, payload: Data)
    func networkServer(_ s: NetworkServer, client: NWConnection, didCloseWith error: Error?)
}

private let SMIR_HELLO_MAGIC: UInt32 = 0x534D4948  // 'SMIH'
private let SMIR_HELLO_LEN  = 56                     // ver2: añade 32 bytes X25519 pubkey
private let SMIR_NONCE_LEN  = 16
private let SMIR_X25519_LEN = 32
private let SMIR_PROTO_VER: UInt8 = 2
private let SMIR_PBKDF2_ITERS: UInt32 = 600_000

final class NetworkServer {
    weak var delegate: NetworkServerDelegate?

    /// Contraseña para derivar la clave AES-256-GCM. Sin contraseña no se aceptan conexiones.
    var password: String = ""

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var bonjour: NetService?
    private let queue = DispatchQueue(label: "smir.server")

    /// Estado por conexión.
    private final class Peer {
        enum State { case awaitingHello, encrypted }
        var state: State = .awaitingHello
        var buffer = Data()
        let crypto = SMIRCrypto()
        var clientNonce: Data?
        var serverNonce: Data?
        var ephemeralPriv: Curve25519.KeyAgreement.PrivateKey?
        var frameCount: UInt64 = 0
    }
    private var peers: [ObjectIdentifier: Peer] = [:]

    init(port: UInt16 = 4878) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let params = NWParameters.tcp
        if let opts = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            opts.noDelay = true
            opts.enableKeepalive = true
            opts.keepaliveIdle = 5
        }
        let l = try NWListener(using: params, on: port)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:        NSLog("[NetworkServer] listener READY on :%d", self.port.rawValue)
            case .failed(let e):NSLog("[NetworkServer] listener FAILED: %@", String(describing: e))
            case .waiting(let e):NSLog("[NetworkServer] listener WAITING: %@", String(describing: e))
            case .cancelled:    NSLog("[NetworkServer] listener cancelled")
            default: break
            }
        }
        l.start(queue: queue)
        listener = l

        bonjour = NetService(domain: "local.", type: "_smirror._tcp.",
                             name: Host.current().localizedName ?? "Mac",
                             port: Int32(port.rawValue))
        bonjour?.publish()

        NSLog("[NetworkServer] escuchando en %d (cifrado AES-256-GCM, anunciado por Bonjour)", port.rawValue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        bonjour?.stop();   bonjour = nil
    }

    private func accept(_ conn: NWConnection) {
        NSLog("[NetworkServer] nuevo cliente: %@", String(describing: conn.endpoint))
        let peer = Peer()
        peers[ObjectIdentifier(conn)] = peer
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                NSLog("[NetworkServer] client conn READY")
                self.receive(on: conn)
            case .failed(let err):
                NSLog("[NetworkServer] client conn FAILED: %@", String(describing: err))
                self.delegate?.networkServer(self, client: conn, didCloseWith: err)
                self.peers.removeValue(forKey: ObjectIdentifier(conn))
                conn.cancel()
            case .waiting(let err):
                NSLog("[NetworkServer] client conn WAITING: %@", String(describing: err))
                self.delegate?.networkServer(self, client: conn, didCloseWith: err)
                self.peers.removeValue(forKey: ObjectIdentifier(conn))
                conn.cancel()
            case .cancelled:
                NSLog("[NetworkServer] client conn CANCELLED")
                self.delegate?.networkServer(self, client: conn, didCloseWith: nil)
                self.peers.removeValue(forKey: ObjectIdentifier(conn))
            case .preparing:
                NSLog("[NetworkServer] client conn preparing")
            case .setup:
                NSLog("[NetworkServer] client conn setup")
            @unknown default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if let peer = self.peers[ObjectIdentifier(conn)] {
                    peer.buffer.append(data)
                    self.parse(connection: conn, peer: peer)
                }
            }
            if let error {
                NSLog("[NetworkServer] receive error: %@", error.localizedDescription)
                self.delegate?.networkServer(self, client: conn, didCloseWith: error)
                conn.cancel(); return
            }
            if isComplete {
                self.delegate?.networkServer(self, client: conn, didCloseWith: nil)
                conn.cancel(); return
            }
            self.receive(on: conn)
        }
    }

    private func parse(connection conn: NWConnection, peer: Peer) {
        while true {
            switch peer.state {
            case .awaitingHello:
                guard peer.buffer.count >= SMIR_HELLO_LEN else { return }
                let magic = peer.buffer.readU32BE(at: 0)
                guard magic == SMIR_HELLO_MAGIC else {
                    NSLog("[NetworkServer] hello magic mismatch — cerrando")
                    conn.cancel(); return
                }
                let clientVer = peer.buffer[peer.buffer.startIndex + 4]
                guard clientVer == SMIR_PROTO_VER else {
                    NSLog("[NetworkServer] versión protocolo: cliente=%d local=%d", clientVer, SMIR_PROTO_VER)
                    conn.cancel(); return
                }
                let nonceRange = (peer.buffer.startIndex + 8) ..< (peer.buffer.startIndex + 8 + SMIR_NONCE_LEN)
                peer.clientNonce = peer.buffer.subdata(in: nonceRange)
                let pubRange = (peer.buffer.startIndex + 8 + SMIR_NONCE_LEN) ..< (peer.buffer.startIndex + 8 + SMIR_NONCE_LEN + SMIR_X25519_LEN)
                let clientPub = peer.buffer.subdata(in: pubRange)
                peer.buffer.removeFirst(SMIR_HELLO_LEN)

                guard !password.isEmpty else {
                    NSLog("[NetworkServer] contraseña no configurada — rechazando cliente")
                    conn.cancel(); return
                }

                // 1) Generar nuestra clave efímera X25519 + nonce.
                peer.ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
                peer.serverNonce  = SMIRCrypto.randomBytes(SMIR_NONCE_LEN)

                let serverPub = peer.ephemeralPriv!.publicKey.rawRepresentation

                // 2) ECDHE: shared = X25519(server_priv, client_pub)
                let peerKey: Curve25519.KeyAgreement.PublicKey
                do {
                    peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub)
                } catch {
                    NSLog("[NetworkServer] X25519 pubkey inválida: %@", error.localizedDescription)
                    conn.cancel(); return
                }
                let shared: SharedSecret
                do {
                    shared = try peer.ephemeralPriv!.sharedSecretFromKeyAgreement(with: peerKey)
                } catch {
                    NSLog("[NetworkServer] ECDHE falló: %@", error.localizedDescription)
                    conn.cancel(); return
                }
                // Borramos la privada efímera ya — forward secrecy.
                peer.ephemeralPriv = nil

                // 3) Derivación de clave: HKDF(shared || PBKDF2(password), salt = nonces)
                var salt = Data()
                salt.append(peer.clientNonce!)
                salt.append(peer.serverNonce!)
                guard let pwdKDF = SMIRCrypto.deriveKey(
                    password: password, salt: salt,
                    iterations: SMIR_PBKDF2_ITERS, keyBytes: 32) else {
                    NSLog("[NetworkServer] PBKDF2 falló")
                    conn.cancel(); return
                }
                var ikm = Data()
                shared.withUnsafeBytes { ikm.append(contentsOf: $0) }
                ikm.append(pwdKDF)
                let info = "SMIR-session-key-v2".data(using: .utf8)!
                let sessionKey = SMIRCrypto.hkdfSHA256(ikm: ikm, salt: salt, info: info, length: 32)
                peer.crypto.key = SymmetricKey(data: sessionKey)
                let sharedFP: (UInt8,UInt8,UInt8,UInt8) = shared.withUnsafeBytes { p in
                    let b = p.bindMemory(to: UInt8.self)
                    return (b[0], b[1], b[2], b[3])
                }
                NSLog("[NetworkServer] DBG pwd.utf8=%d bytes pwdKDF[0..3]=%02x%02x%02x%02x sharedFP[0..3]=%02x%02x%02x%02x sessKey[0..3]=%02x%02x%02x%02x salt[0..3]=%02x%02x%02x%02x",
                      password.utf8.count,
                      pwdKDF[0], pwdKDF[1], pwdKDF[2], pwdKDF[3],
                      sharedFP.0, sharedFP.1, sharedFP.2, sharedFP.3,
                      sessionKey[0], sessionKey[1], sessionKey[2], sessionKey[3],
                      salt[0], salt[1], salt[2], salt[3])

                // 4) Enviar HELLO de respuesta: 'SMIH' + ver + flags + 2 reserved + 16 nonce + 32 pubkey.
                var helloResp = Data()
                helloResp.append(contentsOf: SMIR_HELLO_MAGIC.bigEndianBytes)
                helloResp.append(SMIR_PROTO_VER)
                helloResp.append(2)              // flags: FS+pwd
                helloResp.append(contentsOf: [0, 0])
                helloResp.append(peer.serverNonce!)
                helloResp.append(serverPub)
                conn.send(content: helloResp, completion: .contentProcessed { _ in })

                peer.state = .encrypted
                NSLog("[NetworkServer] auth OK — canal cifrado AES-256-GCM con forward secrecy (X25519)")
                self.delegate?.networkServer(self, didAcceptClient: conn)

            case .encrypted:
                guard peer.buffer.count >= 4 else { return }
                let total = Int(peer.buffer.readU32BE(at: 0))
                if total > 16 * 1024 * 1024 {
                    NSLog("[NetworkServer] frame excesivo %d — cerrando", total)
                    conn.cancel(); return
                }
                guard peer.buffer.count >= 4 + total else { return }
                let cipherRange = (peer.buffer.startIndex + 4) ..< (peer.buffer.startIndex + 4 + total)
                let enc = peer.buffer.subdata(in: cipherRange)
                peer.buffer.removeFirst(4 + total)

                guard let plain = peer.crypto.decrypt(enc) else {
                    NSLog("[NetworkServer] decrypt falló — contraseña incorrecta")
                    conn.cancel(); return
                }
                guard plain.count >= 12 else { continue }
                let pmagic = plain.readU32BE(at: 0)
                guard pmagic == SMIR_MAGIC else { continue }
                let type = plain[plain.startIndex + 4]
                let plen = Int(plain.readU32BE(at: 8))
                guard plain.count >= 12 + plen else { continue }
                let payload = plain.subdata(in: (plain.startIndex + 12) ..< (plain.startIndex + 12 + plen))
                if let t = SMIRType(rawValue: type) {
                    peer.frameCount &+= 1
                    if peer.frameCount <= 5 || peer.frameCount % 60 == 0 {
                        NSLog("[NetworkServer] msg #%d type=0x%02x payload=%dB", peer.frameCount, type, plen)
                    }
                    delegate?.networkServer(self, client: conn, didReceive: t, payload: payload)
                }
            }
        }
    }

    func send(_ msg: SMIRMessage, to conn: NWConnection) {
        guard let peer = peers[ObjectIdentifier(conn)], peer.state == .encrypted else { return }
        let plain = msg.encoded()
        guard let enc = peer.crypto.encrypt(plain) else {
            NSLog("[NetworkServer] encrypt falló"); return
        }
        var wire = Data()
        wire.append(contentsOf: UInt32(enc.count).bigEndianBytes)
        wire.append(enc)
        conn.send(content: wire, completion: .contentProcessed { err in
            if let err { NSLog("[NetworkServer] send error: %@", err.localizedDescription) }
        })
    }
}
