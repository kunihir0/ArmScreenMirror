import Foundation

/// Stable identity for a remembered iPhone/iPad. We can't depend on a real
/// per-device UUID because the iPhone tweak only sends `utsname.machine`
/// (e.g. "iPhone10,4"), so we synthesize a key from model + iOS version +
/// resolution. Two devices of the *same* model running the *same* iOS at
/// the *same* resolution will collide; in practice that's rare enough that
/// we treat them as the same device for picker purposes.
struct DeviceDescriptor: Codable, Equatable, Hashable {
    let modelId: String   // raw machine string from uname (iPhone10,4 / iPad13,8 …)
    let iosMajor: Int
    let iosMinor: Int
    let width: Int        // pixels
    let height: Int       // pixels

    /// Human-readable label like "iPhone 8 · iOS 16.7".
    var displayName: String {
        "\(Self.friendlyModel(modelId)) · iOS \(iosMajor).\(iosMinor)"
    }

    static func make(from hs: SMIRHandshake) -> DeviceDescriptor {
        DeviceDescriptor(modelId:  hs.deviceName,
                         iosMajor: Int(hs.iosMajor),
                         iosMinor: Int(hs.iosMinor),
                         width:    Int(hs.width),
                         height:   Int(hs.height))
    }

    /// Maps `utsname.machine` strings to marketing names. Falls back to the
    /// raw model id when unknown — keeping unrecognized devices visible
    /// rather than hiding them behind a generic label.
    static func friendlyModel(_ id: String) -> String {
        DeviceDescriptor.modelTable[id] ?? id
    }

    private static let modelTable: [String: String] = [
        // iPhones (selected; the dictionary covers what jailbreak users
        // actually run on — pre-iOS 17 hardware).
        "iPhone8,1":  "iPhone 6s",
        "iPhone8,2":  "iPhone 6s Plus",
        "iPhone8,4":  "iPhone SE",
        "iPhone9,1":  "iPhone 7",       "iPhone9,3": "iPhone 7",
        "iPhone9,2":  "iPhone 7 Plus",  "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8",       "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",  "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X",       "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",  "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE 2",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE 3",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPads
        "iPad7,5":    "iPad (6th)",     "iPad7,6": "iPad (6th)",
        "iPad7,11":   "iPad (7th)",     "iPad7,12": "iPad (7th)",
        "iPad8,1":    "iPad Pro 11\"",  "iPad8,2": "iPad Pro 11\"",
        "iPad11,1":   "iPad mini 5",    "iPad11,2": "iPad mini 5",
        "iPad13,1":   "iPad Air 4",     "iPad13,2": "iPad Air 4",
    ]
}

/// One entry in the "remembered devices" list. Mutable so we can bump
/// lastSeen and let the user rename the device.
struct DeviceRecord: Codable, Equatable {
    var descriptor: DeviceDescriptor
    var firstSeen: Date
    var lastSeen: Date
    var nickname: String?  // user-set; nil → fall back to descriptor.displayName

    var displayLabel: String { nickname ?? descriptor.displayName }

    var lastSeenRelative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: lastSeen, relativeTo: Date())
    }
}

/// UserDefaults-backed "device book". Same suite as the password store so
/// settings travel together. JSON-encoded array of DeviceRecord.
enum DeviceHistory {
    private static let key = "smir-device-history-v1"
    private static let suite = "com.example.ScreenMirrorServer"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suite) ?? .standard
    }

    static func load() -> [DeviceRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DeviceRecord].self, from: data)) ?? []
    }

    static func save(_ records: [DeviceRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    /// Insert if new, bump lastSeen otherwise. Returns the (possibly new) record.
    @discardableResult
    static func touch(_ desc: DeviceDescriptor) -> DeviceRecord {
        var all = load()
        let now = Date()
        if let idx = all.firstIndex(where: { $0.descriptor == desc }) {
            all[idx].lastSeen = now
            save(all)
            return all[idx]
        }
        let rec = DeviceRecord(descriptor: desc,
                               firstSeen: now,
                               lastSeen: now,
                               nickname: nil)
        all.append(rec)
        save(all)
        return rec
    }

    static func forget(_ desc: DeviceDescriptor) {
        var all = load()
        all.removeAll { $0.descriptor == desc }
        save(all)
    }

    static func setNickname(_ name: String?, for desc: DeviceDescriptor) {
        var all = load()
        guard let idx = all.firstIndex(where: { $0.descriptor == desc }) else { return }
        all[idx].nickname = (name?.isEmpty == true) ? nil : name
        save(all)
    }
}
