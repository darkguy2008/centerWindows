import Foundation

enum Preferences {
    private enum Key {
        static let centerNewWindows = "centerNewWindows"
        static let centerOnSwitch = "centerOnSwitch"
        static let language = "language"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.centerNewWindows: true,
            Key.centerOnSwitch: true,
            Key.language: "zh",
        ])
    }

    static var centerNewWindows: Bool {
        get { UserDefaults.standard.bool(forKey: Key.centerNewWindows) }
        set { UserDefaults.standard.set(newValue, forKey: Key.centerNewWindows) }
    }

    static var centerOnSwitch: Bool {
        get { UserDefaults.standard.bool(forKey: Key.centerOnSwitch) }
        set { UserDefaults.standard.set(newValue, forKey: Key.centerOnSwitch) }
    }

    /// `"zh"` (default) or `"en"`.
    static var language: String {
        get { UserDefaults.standard.string(forKey: Key.language) ?? "zh" }
        set { UserDefaults.standard.set(newValue, forKey: Key.language) }
    }

    /// Return the Chinese or English string based on the current language preference.
    static func L(_ zh: String, _ en: String) -> String {
        language == "en" ? en : zh
    }
}
