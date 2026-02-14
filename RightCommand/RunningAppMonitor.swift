import Cocoa

// MARK: - AppInfo

struct AppInfo: Identifiable {
    let bundleId: String
    let name: String
    let icon: NSImage
    var isPinned: Bool = false
    var isRunning: Bool = true
    var id: String { bundleId }
}

// MARK: - PinnedApp

struct PinnedApp: Codable {
    let bundleId: String
    let name: String
}

// MARK: - RunningAppMonitor

@Observable
final class RunningAppMonitor {
    /// Letter → sorted list of apps for that letter (includes pinned-but-not-running apps)
    private(set) var appsByLetter: [String: [AppInfo]] = [:]

    /// Letter → pinned app for that letter (persisted to UserDefaults)
    private(set) var pinnedApps: [String: PinnedApp] = [:]

    private let keyMonitor: KeyMonitor
    private let ownBundleId = Bundle.main.bundleIdentifier ?? ""
    private var observers: [Any] = []

    init(keyMonitor: KeyMonitor) {
        self.keyMonitor = keyMonitor
        loadPins()

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })

        refresh()
    }

    // MARK: - Pin Management

    func pin(letter: String, bundleId: String, name: String) {
        pinnedApps[letter] = PinnedApp(bundleId: bundleId, name: name)
        savePins()
        refresh()
    }

    func unpin(letter: String) {
        pinnedApps.removeValue(forKey: letter)
        savePins()
        refresh()
    }

    private func loadPins() {
        guard let data = UserDefaults.standard.data(forKey: "pinnedApps"),
              let pins = try? JSONDecoder().decode([String: PinnedApp].self, from: data) else { return }
        // Validate: only keep pins for apps that are still installed
        pinnedApps = pins.filter { _, pin in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleId) != nil
        }
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pinnedApps) {
            UserDefaults.standard.set(data, forKey: "pinnedApps")
        }
    }

    // MARK: - App Name Resolution

    /// Read CFBundleName from a bundle URL, returning nil if unavailable or empty.
    private func bundleName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
              !name.isEmpty else { return nil }
        return name
    }

    /// Prefer CFBundleName (e.g. "Chrome") over localizedName (e.g. "Google Chrome")
    /// so the first-letter mapping matches how users think of the app.
    private func shortName(for app: NSRunningApplication) -> String? {
        if let url = app.bundleURL, let name = bundleName(at: url) { return name }
        return app.localizedName
    }

    /// Resolve the short app name from a bundle identifier (for pinned apps that aren't running).
    private func shortName(forBundleId bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return bundleName(at: url)
    }

    // MARK: - Refresh

    func refresh() {
        var byLetter: [String: [AppInfo]] = [:]
        var seen = Set<String>()

        // 1. Add all running apps
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let name = shortName(for: app), !name.isEmpty,
                  let bundleId = app.bundleIdentifier,
                  bundleId != ownBundleId,
                  !seen.contains(bundleId),
                  let firstChar = name.first
            else { continue }

            let letter = String(firstChar).uppercased()
            guard charToKeyCode[letter] != nil else { continue }

            seen.insert(bundleId)
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName)!
            let isPinned = pinnedApps[letter]?.bundleId == bundleId
            byLetter[letter, default: []].append(
                AppInfo(bundleId: bundleId, name: name, icon: icon, isPinned: isPinned, isRunning: true)
            )
        }

        // 2. Add pinned apps that aren't currently running
        for (letter, pin) in pinnedApps {
            guard !seen.contains(pin.bundleId) else { continue }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleId) else { continue }

            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let name = shortName(forBundleId: pin.bundleId) ?? pin.name
            byLetter[letter, default: []].append(
                AppInfo(bundleId: pin.bundleId, name: name, icon: icon, isPinned: true, isRunning: false)
            )
        }

        // 3. Sort each letter group alphabetically by name
        for key in byLetter.keys {
            byLetter[key]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        appsByLetter = byLetter

        // 4. Build keyCode → [bundleId] map
        var keyCodeMap: [UInt16: [String]] = [:]
        for (letter, apps) in byLetter {
            if let keyCode = charToKeyCode[letter] {
                if let pin = pinnedApps[letter] {
                    // Pinned: only the pinned app, no cycling
                    keyCodeMap[keyCode] = [pin.bundleId]
                } else {
                    // Normal: all running apps (sorted order preserved for cycling)
                    keyCodeMap[keyCode] = apps.map(\.bundleId)
                }
            }
        }
        keyMonitor.updateAppMappings(keyCodeMap)
    }
}
