import SwiftUI
import UserNotifications

@main
struct XKCDReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ComicStore()
    @State private var userState = UserState()
    @Environment(\.scenePhase) private var scenePhase
    /// Asked once, in the app's own words, before iOS shows its permission prompt.
    @State private var offerAlerts = false

    init() {
        // Comics are enlarged by the trained model when it is available.
        ComicUpscaler.modelEnlarger = { image, factor, method in
            if method == .tiles, let tiled = TiledUpscaler.shared?.upscale(image, towards: factor) { return tiled }
            return ModelUpscaler.shared?.upscale(image, towards: factor)
        }
    }

    var body: some Scene {
        WindowGroup {
            ComicGridScreen()
                .environment(store)
                .environment(userState)
                .tint(Color.xkcdSlate)
                .task {
                    await store.start()
                    saveWidgetPool()
                    offerAlertsOnce()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-simulateNewComic") {
                        await NewComicNotifier.simulateNewComic()
                    }
                    #endif
                }
                .alert("New Comic Alerts", isPresented: $offerAlerts) {
                    Button("Not Now", role: .cancel) {}
                    Button("Turn On") { Task { await turnOnAlerts() } }
                } message: {
                    Text("xkcd comes out on Mondays, Wednesdays and Fridays. Want an alert when a new comic is out? You can change this any time in the menu.")
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // New comics are picked up whenever the app comes to the front.
                        Task { await store.refresh() }
                    case .background:
                        NewComicNotifier.schedule()
                        saveWidgetPool()
                    default:
                        break
                    }
                }
        }
        .backgroundTask(.appRefresh(NewComicNotifier.taskID)) {
            await NewComicNotifier.checkAndNotify()
        }
    }
}

extension XKCDReaderApp {
    /// Tells the Random Comic widget what there is to choose from. Comics newer than the bundled
    /// list have no known shape yet, and interactive ones need the website, so both are left out.
    private func saveWidgetPool() {
        let comics = store.comics.filter { $0.num <= store.seedMax && !$0.isInteractive && $0.imageURL != nil }
        guard !comics.isEmpty else { return }
        let pool = WidgetPool(nums: comics.map(\.num),
                              aspects: comics.map { ($0.aspectRatio * 100).rounded() / 100 },
                              favorites: userState.favorites.sorted(),
                              viewed: userState.viewed.sorted())
        Task.detached(priority: .utility) { pool.save() }
    }

    /// On first launch, ask to send new-comic alerts. If the answer is yes they are switched on;
    /// either way the menu's "New Comic Alerts" toggle controls them afterwards.
    private func offerAlertsOnce() {
        let defaults = UserDefaults.standard
        let askedKey = "askedAboutNewComicAlerts"
        guard !defaults.bool(forKey: askedKey), !DebugMode.isTakingScreenshots else { return }
        defaults.set(true, forKey: askedKey)
        guard !NewComicNotifier.isEnabled else { return }
        offerAlerts = true
    }

    /// The reader said yes: now iOS asks for permission, and alerts go on if that is granted.
    private func turnOnAlerts() async {
        let defaults = UserDefaults.standard
        if await NewComicNotifier.requestPermission() {
            defaults.set(true, forKey: NewComicNotifier.enabledKey)
            NewComicNotifier.markSeen(store.latestNum)
            NewComicNotifier.schedule()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let num = response.notification.request.content.userInfo["num"] as? Int else { return }
        await ComicLink.open(num)
    }
}
