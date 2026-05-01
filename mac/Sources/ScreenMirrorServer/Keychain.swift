import Foundation

/// Almacenamiento simple de la contraseña compartida.
/// Usa UserDefaults — la contraseña queda en
///   ~/Library/Preferences/com.example.ScreenMirrorServer.plist
/// Suficiente para una herramienta personal de mirroring en LAN. Para uso
/// más estricto se podría reemplazar por SecItemAdd cuando la app esté
/// firmada con un Developer ID (entonces Keychain no pide autorización).
enum Keychain {
    private static let suite = "com.example.ScreenMirrorServer"
    private static let key   = "smir-shared-password"

    private static var defaults: UserDefaults {
        // Suite explícito para que funcione tanto desde el .app como
        // desde el binario suelto (donde Bundle.main.bundleIdentifier es nil).
        UserDefaults(suiteName: suite) ?? .standard
    }

    static func save(_ password: String) {
        defaults.set(password, forKey: key)
        defaults.synchronize()
    }

    static func load() -> String? {
        defaults.string(forKey: key)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
        defaults.synchronize()
    }
}
