import AppKit
import Combine
import Security
import LidGlassCore

/// Keeps LidGlass current from its GitHub releases.
///
/// A release is trusted only if its app is signed with the same certificate as the app
/// already installed: the download must satisfy the installed app's designated
/// requirement, which names that certificate. So only someone holding its private key can
/// publish an update this app will install. It is also the check macOS uses to keep Screen
/// Recording permission, so an update keeps the permission too.
final class Updater {
    struct Release {
        let version: ReleaseVersion
        let archiveURL: URL
    }

    /// An unpacked release, in a temporary folder that goes once the update is done.
    struct Download {
        let app: URL
        let workspace: URL
    }

    enum UpdateError: LocalizedError {
        case unreadableFeed(String)
        case noArchive
        case noAppInArchive
        case wrongApp
        case wrongArchitecture
        case versionMismatch(expected: ReleaseVersion, found: String)
        case untrusted(String)
        case cannotReplace(String)

        var errorDescription: String? {
            switch self {
            case .unreadableFeed(let reason): "The release list could not be read: \(reason)"
            case .noArchive: "The release has no \(Updater.archiveName) to install."
            case .noAppInArchive: "The release archive holds no LidGlass app."
            case .wrongApp: "The release archive holds a different app."
            case .wrongArchitecture: "The update does not run on this Mac's processor."
            case .versionMismatch(let expected, let found): "The release says \(expected) but its app says \(found)."
            case .untrusted(let reason): "The update is not signed with this copy's certificate, so it was not installed. \(reason)"
            case .cannotReplace(let reason): "LidGlass could not replace itself: \(reason)"
            }
        }
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/jwhitlow45/lidglass/releases/latest")!
    static let archiveName = "LidGlass.zip"
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let firstCheckDelay: TimeInterval = 60
    /// While the glass is showing, an automatic install waits this long and tries again.
    static let busyRetryDelay: TimeInterval = 60

    private let settings = Settings.shared
    private let feedURL: URL
    private let installedApp: URL
    private var timer: Timer?
    private var isChecking = false
    private var cancellables = Set<AnyCancellable>()

    /// Asked before an automatic install, so an update never restarts the app mid-fold.
    var canRelaunchNow: () -> Bool = { true }

    /// The feed can be pointed elsewhere for testing. Trust still comes only from the
    /// signature check, so the feed's source does not matter to safety.
    init(feedURL: URL = ProcessInfo.processInfo.environment["LIDGLASS_UPDATE_FEED"].flatMap(URL.init(string:))
             ?? Updater.latestReleaseURL,
         installedApp: URL = Bundle.main.bundleURL) {
        self.feedURL = feedURL
        self.installedApp = installedApp
    }

    #if arch(arm64)
    static let hostArchitecture = NSBundleExecutableArchitectureARM64
    #else
    static let hostArchitecture = NSBundleExecutableArchitectureX86_64
    #endif

    static var installedVersion: ReleaseVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(ReleaseVersion.init)
    }

    func start() {
        settings.$updatesAutomatically
            .sink { [weak self] isOn in isOn ? self?.scheduleChecks() : self?.cancelChecks() }
            .store(in: &cancellables)
    }

    /// From the menu. Checks whatever the setting, says what it found, and asks before
    /// installing.
    func checkNow() {
        Task { @MainActor in await check(isAutomatic: false) }
    }

    // MARK: - Scheduling

    private func scheduleChecks() {
        cancelChecks()
        let timer = Timer(timeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in self?.checkAutomatically() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Updater.firstCheckDelay) { [weak self] in
            self?.checkAutomatically()
        }
    }

    private func cancelChecks() {
        timer?.invalidate()
        timer = nil
    }

    private func checkAutomatically() {
        guard settings.updatesAutomatically else { return }
        guard canRelaunchNow() else {
            retryAutomaticCheckLater()
            return
        }
        Task { @MainActor in await check(isAutomatic: true) }
    }

    private func retryAutomaticCheckLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Updater.busyRetryDelay) { [weak self] in
            self?.checkAutomatically()
        }
    }

    // MARK: - Checking and installing

    @MainActor
    private func check(isAutomatic: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            guard let installed = Updater.installedVersion, let release = try await newerRelease(than: installed) else {
                if !isAutomatic { tell("LidGlass is up to date", "You have version \(Updater.installedVersion?.description ?? "unknown").") }
                return
            }
            if !isAutomatic && !confirmInstall(release, installed: installed) { return }
            let download = try await download(release)
            // Cleaned up by hand rather than with defer, which would not run once the app
            // terminates to relaunch.
            let removeDownload = { try? FileManager.default.removeItem(at: download.workspace) }
            do {
                try verify(download.app, as: release)
            } catch {
                removeDownload()
                throw error
            }
            // The download takes a while. An automatic install must still be wanted, and the
            // glass still down, at the moment it happens.
            if isAutomatic && !(settings.updatesAutomatically && canRelaunchNow()) {
                removeDownload()
                if settings.updatesAutomatically { retryAutomaticCheckLater() }
                return
            }
            do {
                try install(download.app)
            } catch {
                removeDownload()
                throw error
            }
            removeDownload()
            NSLog("LidGlass: installed \(release.version), relaunching")
            try relaunch()
        } catch {
            NSLog("LidGlass: update failed: \(error.localizedDescription)")
            if !isAutomatic { tell("LidGlass could not update", error.localizedDescription) }
        }
    }

    /// The latest published release, if it is newer than `installed`. No releases at all is
    /// not an error, just nothing to install.
    func newerRelease(than installed: ReleaseVersion) async throws -> Release? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode {
            if status == 404 { return nil }
            guard status == 200 else { throw UpdateError.unreadableFeed("HTTP \(status)") }
        }
        struct Feed: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let assets: [Asset]
        }
        let feed: Feed
        do {
            feed = try JSONDecoder().decode(Feed.self, from: data)
        } catch {
            throw UpdateError.unreadableFeed(error.localizedDescription)
        }
        guard let version = ReleaseVersion(feed.tag_name), version > installed else { return nil }
        guard let archive = feed.assets.first(where: { $0.name == Updater.archiveName }) else { throw UpdateError.noArchive }
        return Release(version: version, archiveURL: archive.browser_download_url)
    }

    /// Downloads and unpacks the release next to the installed app, on the same volume, so
    /// installing is a rename rather than a copy.
    func download(_ release: Release) async throws -> Download {
        let (downloaded, _) = try await URLSession.shared.download(from: release.archiveURL)
        let workspace = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: installedApp, create: true)
        let archive = workspace.appendingPathComponent(Updater.archiveName)
        try FileManager.default.moveItem(at: downloaded, to: archive)
        let unpacked = workspace.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        // The archive must hold exactly one app, as a real folder. Its name does not matter,
        // since the installed copy may have been renamed. A symbolic link could make the
        // signature check read one bundle while the install moves another.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: Array(keys))) ?? []
        guard ditto.terminationStatus == 0, entries.count == 1, let app = entries.first, app.pathExtension == "app",
              let values = try? app.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink != true else {
            try? FileManager.default.removeItem(at: workspace)
            throw UpdateError.noAppInArchive
        }
        return Download(app: app, workspace: workspace)
    }

    func verify(_ app: URL, as release: Release) throws {
        guard let update = Bundle(url: app),
              update.bundleIdentifier == Bundle(url: installedApp)?.bundleIdentifier else { throw UpdateError.wrongApp }
        guard update.executableArchitectures?.contains(NSNumber(value: Updater.hostArchitecture)) == true else {
            throw UpdateError.wrongArchitecture
        }
        let found = update.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "no version"
        guard ReleaseVersion(found) == release.version else {
            throw UpdateError.versionMismatch(expected: release.version, found: found)
        }

        var installedCode: SecStaticCode?
        var requirement: SecRequirement?
        var updateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installedApp as CFURL, [], &installedCode) == errSecSuccess, let installedCode,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &updateCode) == errSecSuccess, let updateCode else {
            throw UpdateError.untrusted("The signatures could not be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(updateCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.untrusted((SecCopyErrorMessageString(status, nil) as String?) ?? "Error \(status).")
        }
    }

    func install(_ app: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: app)
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
    }

    /// A small shell waits for this process to exit, then opens the new copy.
    private func relaunch() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                           installedApp.path]
        try shell.run()
        NSApp.terminate(nil)
    }

    // MARK: - Asking

    @MainActor
    private func confirmInstall(_ release: Release, installed: ReleaseVersion) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "LidGlass \(release.version) is available"
        alert.informativeText = "You have version \(installed). LidGlass will relaunch to finish."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func tell(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
