import Foundation
import CryptoKit
import CommonCrypto

/// Wrapper sobre CryptoKit (AES-GCM) + CommonCrypto (PBKDF2-SHA256).
/// Mantiene contadores monotónicos para usar como IV — no es necesario
/// transmitirlos: TCP garantiza orden, ambos extremos suben sus contadores
/// en paralelo.
final class SMIRCrypto {

    var key: SymmetricKey?
    private(set) var sendCounter: UInt64 = 0
    private(set) var recvCounter: UInt64 = 0

    static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        _ = d.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return d
    }

    static func deriveKey(password: String,
                          salt: Data,
                          iterations: UInt32 = 600_000,
                          keyBytes: Int = 32) -> Data? {
        guard !password.isEmpty,
              let pwd = password.data(using: .utf8),
              !pwd.isEmpty else { return nil }
        var derived = Data(count: keyBytes)
        let result = derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int32 in
            return pwd.withUnsafeBytes { p -> Int32 in
                return salt.withUnsafeBytes { s -> Int32 in
                    let pBuf  = p.bindMemory(to: Int8.self).baseAddress
                    let sBuf  = s.bindMemory(to: UInt8.self).baseAddress
                    let oBuf  = out.bindMemory(to: UInt8.self).baseAddress
                    // SHA-512 + 600k iteraciones (recomendación OWASP 2023+).
                    return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                                pBuf, pwd.count,
                                                sBuf, salt.count,
                                                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                                                iterations,
                                                oBuf, keyBytes)
                }
            }
        }
        return result == 0 ? derived : nil
    }

    /// HKDF-SHA256: extrae+expande clave de longitud arbitraria.
    static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let saltKey  = SymmetricKey(data: salt.isEmpty ? Data(count: 32) : salt)
        let prk      = HMAC<SHA256>.authenticationCode(for: ikm, using: saltKey)
        let prkData  = Data(prk)
        let prkKey   = SymmetricKey(data: prkData)

        var out = Data()
        var T = Data()
        var counter: UInt8 = 1
        while out.count < length {
            var input = T
            input.append(info)
            input.append(counter)
            let block = HMAC<SHA256>.authenticationCode(for: input, using: prkKey)
            T = Data(block)
            let remaining = length - out.count
            out.append(T.prefix(min(remaining, T.count)))
            counter &+= 1
        }
        return out
    }

    private func iv(for counter: UInt64) -> Data {
        var d = Data(count: 12)
        for i in 0..<8 {
            d[4 + i] = UInt8(truncatingIfNeeded: counter >> ((7 - i) * 8))
        }
        return d
    }

    func encrypt(_ plaintext: Data) -> Data? {
        guard let key = key else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: iv(for: sendCounter))
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            sendCounter &+= 1
            return sealed.ciphertext + sealed.tag
        } catch {
            return nil
        }
    }

    func decrypt(_ data: Data) -> Data? {
        guard let key = key, data.count >= 16 else { return nil }
        let ct = data.prefix(data.count - 16)
        let tag = data.suffix(16)
        do {
            let nonce = try AES.GCM.Nonce(data: iv(for: recvCounter))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            let plain = try AES.GCM.open(box, using: key)
            recvCounter &+= 1
            return plain
        } catch {
            return nil
        }
    }
}
