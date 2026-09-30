import Foundation

/// Presets de calidad. Cada uno determina la resolución de captura, el FPS,
/// el bitrate cap y el quality-mode del encoder H.264 en el iPhone.
enum Quality: UInt8, CaseIterable {
    case low    = 0
    case medium = 1
    case high   = 2

    var label: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Valores guía que se mandan al iPhone con SMIR_QUALITY. El iOS reinicia
    /// captura + encoder con estos parámetros.
    /// scale: factor sobre la resolución nativa del iPhone (en píxeles).
    /// fps: tasa de captura cuando hay actividad.
    /// idleFps: tasa de captura cuando no hay cambios (modo ahorro).
    /// bitrate: cap superior del encoder H.264 (bps).
    /// h264Quality: VTCompressionPropertyKey_Quality (0..1).
    var scale:       Double { switch self { case .low: 0.30; case .medium: 0.40; case .high: 0.45 } }
    var fps:         UInt8  { switch self { case .low: 30;   case .medium: 30;   case .high: 30   } }
    var idleFps:     UInt8  { switch self { case .low: 30;   case .medium: 30;   case .high: 30   } }
    var bitrate:     UInt32 { switch self { case .low: 800_000; case .medium: 1_500_000; case .high: 2_200_000 } }
    var h264Quality: Float  { switch self { case .low: 0.40; case .medium: 0.50; case .high: 0.55 } }
}

enum QualityStore {
    private static let key = "smir-quality-preset"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "com.example.ScreenMirrorServer") ?? .standard
    }

    static var current: Quality {
        get {
            let raw = defaults.integer(forKey: key)   // 0 si no existe → low. Ajustamos a medium.
            if !defaults.contains(key: key) { return .medium }
            return Quality(rawValue: UInt8(raw)) ?? .medium
        }
        set {
            defaults.set(Int(newValue.rawValue), forKey: key)
            defaults.synchronize()
        }
    }
}

private extension UserDefaults {
    func contains(key: String) -> Bool { object(forKey: key) != nil }
}
