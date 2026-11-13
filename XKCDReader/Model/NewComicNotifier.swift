import BackgroundTasks
import Foundation
import UserNotifications

/// New-comic alerts without a server. iOS wakes the app in the background now and then, the app
/// checks xkcd.com for the latest comic, and posts a local notification if it's new. iOS picks
/// when those wake-ups happen, so an alert can come a few hours after the comic.
enum NewComicNotifier {
    static let taskID = "app.xkcdrevival.reader.refresh"
    static let enabledKey = "notifyNewComics"
    private static let lastSeenKey = "lastSeenComicNum"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Alert text: the comic's title, with "xkcd · #N" under it.
    private static func fill(_ content: UNMutableNotificationContent, for comic: Comic) {
        content.title = comic.displayTitle
        content.body = "xkcd · #\(comic.num)"
    }

    /// Asks iOS for another background wake-up, or cancels it when alerts are off.
    static func schedule() {
        guard isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Records that everything up to `num` has been available to see in the app.
    static func markSeen(_ num: Int, fromBackgroundCheck: Bool = false) {
        let defaults = UserDefaults.standard
        // An armed background test survives opening the app. Only the check itself ends it.
        if backgroundTestArmed {
            guard fromBackgroundCheck else { return }
            defaults.set(false, forKey: backgroundTestKey)
        }
        if num > defaults.integer(forKey: lastSeenKey) { defaults.set(num, forKey: lastSeenKey) }
    }

    /// Runs in the background task. Looks for a newer comic and posts one notification for it.
    static func checkAndNotify() async {
        schedule()
        guard isEnabled, let latest = try? await XKCDClient.fetchComic(nil) else { return }

        let seen = UserDefaults.standard.integer(forKey: lastSeenKey)
        defer { markSeen(latest.num, fromBackgroundCheck: true) }
        guard seen > 0, latest.num > seen else { return }

        let content = UNMutableNotificationContent()
        fill(content, for: latest)
        content.sound = .default
        content.userInfo = ["num": latest.num]
        let request = UNNotificationRequest(identifier: "new-comic-\(latest.num)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Testing on a device (Debug Mode menu)

    /// Posts the same alert a new comic would, a few seconds from now, so there's time to leave the
    /// app or lock the phone.
    static func sendTestAlert(after seconds: TimeInterval = 6) async -> Bool {
        guard await requestPermission(), let latest = try? await XKCDClient.fetchComic(nil) else { return false }
        let content = UNMutableNotificationContent()
        fill(content, for: latest)
        content.sound = .default
        content.userInfo = ["num": latest.num]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: "test-alert", content: content, trigger: trigger)
        return (try? await UNUserNotificationCenter.current().add(request)) != nil
    }

    /// Makes the app think it hasn't seen the newest comic, so the next background wake-up finds a
    /// "new" comic and alerts. The app has to stay in the background, since opening it marks
    /// everything seen again.
    static func armBackgroundTest() async -> Bool {
        guard let latest = try? await XKCDClient.fetchComic(nil) else { return false }
        UserDefaults.standard.set(latest.num - 1, forKey: lastSeenKey)
        UserDefaults.standard.set(true, forKey: backgroundTestKey)
        schedule()
        return true
    }

    /// While a background test is armed, coming to the front doesn't mark the newest comic seen.
    private static let backgroundTestKey = "backgroundAlertTestArmed"
    static var backgroundTestArmed: Bool { UserDefaults.standard.bool(forKey: backgroundTestKey) }

    #if DEBUG
    /// For testing: pretend the newest comic hasn't been seen and run the check now.
    static func simulateNewComic() async {
        guard let latest = try? await XKCDClient.fetchComic(nil) else { return }
        UserDefaults.standard.set(latest.num - 1, forKey: lastSeenKey)
        await checkAndNotify()
    }
    #endif
}

/// Carries "open this comic" from a tapped notification to the comic grid.
enum ComicLink {
    static let openComic = Notification.Name("ComicLink.openComic")
    private static var pending: Int?

    /// Called when a notification is tapped, whether or not the grid is on screen yet.
    @MainActor static func open(_ num: Int) {
        pending = num
        NotificationCenter.default.post(name: openComic, object: nil)
    }

    @MainActor static func takePending() -> Int? {
        defer { pending = nil }
        return pending
    }
}
