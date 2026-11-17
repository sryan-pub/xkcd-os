import Foundation

/// Settings the app and its widgets both read. They live in the shared app-group container,
/// because a widget cannot see the app's own preferences.
enum SharedSettings {
    static let appGroup = "group.app.xkcdrevival.reader"
    private static let invertKey = "invertComicsInDarkMode"

    private static var store: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Redraw comics for dark mode. On unless the reader switched it off in the app.
    static var invertInDarkMode: Bool {
        get { store?.object(forKey: invertKey) as? Bool ?? true }
        set { store?.set(newValue, forKey: invertKey) }
    }
}
