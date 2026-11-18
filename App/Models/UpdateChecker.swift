import Core
import Foundation

/// Opt-in check for a newer release on GitHub, at most once a day. Off by default: until it is turned on, the app makes
/// no network request at all. It only reads the latest version number and never downloads or installs anything, because
/// an update replaces a helper that runs as root, which the owner must do on purpose.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case off
        case idle
        case checking
        case upToDate(Date)
        case available(LatestRelease)
        case failed
    }

    private(set) var state = State.off
    private var dismissed: String?

    private static let interval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "updates.lastCheck"
    private static let latestKey = "updates.latestVersion"
    private static let dismissedKey = "updates.dismissedVersion"

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?

    let current = ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? ReleaseVersion("0")!

    init(settings: AppSettings, defaults: UserDefaults) {
        self.settings = settings
        self.defaults = defaults
        dismissed = defaults.string(forKey: Self.dismissedKey)
    }

    /// A newer version the owner has not hidden, for the notice in the window.
    var noticeRelease: LatestRelease? {
        guard case let .available(release) = state, dismissed != release.version.description else { return nil }
        return release
    }

    /// Call at launch and after any settings change. Starts or stops the daily check.
    func settingsChanged() {
        guard settings.stored.checkForUpdates else {
            loop?.cancel()
            loop = nil
            state = .off
            return
        }
        guard loop == nil else { return }
        // What the last check found is shown at once, without waiting for the network.
        if let saved = defaults.string(forKey: Self.latestKey).flatMap(ReleaseVersion.init), saved > current {
            state = .available(LatestRelease(version: saved))
        } else if let last = defaults.object(forKey: Self.lastCheckKey) as? Date {
            state = .upToDate(last)
        } else {
            state = .idle
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let last = self.defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
                if Date().timeIntervalSince(last) >= Self.interval { await self.check() }
                // Hourly wake-ups are cheap and catch up after sleep; the check itself runs once a day.
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func checkNow() {
        Task { await check() }
    }

    func dismiss() {
        guard case let .available(release) = state else { return }
        dismissed = release.version.description
        defaults.set(dismissed, forKey: Self.dismissedKey)
    }

    private func check() async {
        guard settings.stored.checkForUpdates, state != .checking else { return }
        let previous = state
        state = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)
        guard let release = await Self.fetch() else {
            // A version found earlier stays known; otherwise the failure is shown next to the Check Now button.
            if case .available = previous { state = previous } else { state = .failed }
            return
        }
        defaults.set(release.version.description, forKey: Self.latestKey)
        state = release.version > current ? .available(release) : .upToDate(Date())
    }

    /// No cookies, no cache, no credentials: the request carries nothing but the app's name, which GitHub requires.
    private nonisolated static func fetch() async -> LatestRelease? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: ReleaseCheck.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("jMacosTweaker", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ReleaseCheck.parse(data)
    }
}
