import Foundation

/// Testing tools, hidden in normal use. Turned on in the Settings app (Settings > xkcd > Debug
/// Mode, see `Resources/Settings.bundle`). Adds:
///
/// - a button on full-screen comics that cycles the enlarging method (trained model in tiles on
///   the Neural Engine, trained model on the GPU, hand-written) and shows the last one's timing
/// - a Test Alerts menu to send a new-comic alert on demand or arm a real background check
/// - `-screenshot "explain 1053"` at launch (used by `scripts/make_screenshots.sh`) opens that
///   comic and then its alt text ("alt"), explanation ("explain") or nothing more ("comic").
///   `-screenshot about` opens About. Works without the switch so no testing tools show.
/// - `-debugMode YES -pagerCheck "53 827"` at launch (used by `scripts/check_pager_alignment.py`)
///   opens those comics one after another the way the dice does
///
/// Put new testing tools behind this switch too.
///
/// Only Debug and Simulator builds have it (the pager check uses a Release Simulator build).
/// Device Release builds ignore the switch and don't package the Settings bundle
/// (`EXCLUDED_SOURCE_FILE_NAMES` for iphoneos in the Release configuration).
enum DebugMode {
    static let key = "debugMode"

    #if DEBUG || targetEnvironment(simulator)
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif

    static var isOn: Bool { isAvailable && UserDefaults.standard.bool(forKey: key) }

    /// Comic numbers given at launch for the pager check. Empty in normal use.
    static var pagerCheckComics: [Int] {
        guard isOn else { return [] }
        return (UserDefaults.standard.string(forKey: "pagerCheck") ?? "").split(separator: " ").compactMap { Int($0) }
    }

    /// Launched by `scripts/make_screenshots.sh`, so skip the first-launch alerts offer.
    static var isTakingScreenshots: Bool { isAvailable && UserDefaults.standard.object(forKey: "screenshot") != nil }

    /// Screen to open at launch for a screenshot, if given.
    static var screenshotScene: (kind: String, num: Int)? {
        // Only needs the launch argument, not the switch, so screenshots show no testing tools.
        guard isAvailable, let parts = UserDefaults.standard.string(forKey: "screenshot")?.split(separator: " "),
              parts.count == 2, let num = Int(parts[1]) else { return nil }
        return (String(parts[0]), num)
    }
}
