import Foundation

enum SMIRType: UInt8 {
    case handshake    = 0x01
    case videoConfig  = 0x02
    case videoFrame   = 0x03
    case orientation  = 0x04
    case quality      = 0x05
    case touchDown    = 0x10
    case touchMove    = 0x11
    case touchUp      = 0x12
    case swipe        = 0x13
    case keyEvent     = 0x20
    case textInput    = 0x21
    case buttonEvent  = 0x30
    case ping         = 0x40
    case pong         = 0x41
}

enum SMIRButton: UInt8 {
    case home    = 1
    case lock    = 2
    case volUp   = 3
    case volDown = 4
    case mute    = 5
    case siri    = 6
}

let SMIR_MAGIC: UInt32 = 0x534D4952

struct SMIRMessage {
    let type: SMIRType
    let payload: Data

    func encoded() -> Data {
        var d = Data(capacity: 12 + payload.count)
        d.append(contentsOf: SMIR_MAGIC.bigEndianBytes)
        d.append(type.rawValue)
        d.append(contentsOf: [0,0,0])
        d.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        d.append(payload)
        return d
    }
}

struct SMIRHandshake {
    let width: UInt32
    let height: UInt32
    let scale: Float
    let iosMajor: UInt8
    let iosMinor: UInt8
    let orientation: UInt8
    let deviceName: String

    static func decode(_ data: Data) -> SMIRHandshake? {
        guard data.count >= 4 + 4 + 4 + 4 + 64 else { return nil }
        let w  = data.readU32BE(at: 0)
        let h  = data.readU32BE(at: 4)
        let sb = data.readU32BE(at: 8)
        let scale = Float(bitPattern: sb)
        let major = data[10 + 2]   // index 12
        let minor = data[10 + 3]   // index 13
        let orient = data[10 + 4]  // index 14
        // reserved at 15
        let nameRange = 16..<min(16 + 64, data.count)
        var nameBytes = data.subdata(in: nameRange)
        if let nul = nameBytes.firstIndex(of: 0) {
            nameBytes = nameBytes.prefix(upTo: nul)
        }
        let name = String(data: nameBytes, encoding: .utf8) ?? "Device"
        return SMIRHandshake(width: w, height: h, scale: scale,
                             iosMajor: major, iosMinor: minor,
                             orientation: orient, deviceName: name)
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let b = self.bigEndian
        return [UInt8(truncatingIfNeeded: b),
                UInt8(truncatingIfNeeded: b >> 8),
                UInt8(truncatingIfNeeded: b >> 16),
                UInt8(truncatingIfNeeded: b >> 24)]
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let b = self.bigEndian
        return [UInt8(truncatingIfNeeded: b),
                UInt8(truncatingIfNeeded: b >> 8)]
    }
}

extension Data {
    func readU32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= self.count else { return 0 }
        let b = self[self.startIndex + offset ..< self.startIndex + offset + 4]
        return b.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])
        }
    }
    func readU64BE(at offset: Int) -> UInt64 {
        guard offset + 8 <= self.count else { return 0 }
        let b = self[self.startIndex + offset ..< self.startIndex + offset + 8]
        return b.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(raw[i]) }
            return v
        }
    }
}
