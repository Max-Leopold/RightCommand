import SwiftUI

@main
struct RightCommandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("RightCommand", systemImage: "command") {
            MenuBarContent(keyMonitor: delegate.keyMonitor, monitor: delegate.appMonitor)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let keyMonitor = KeyMonitor()
    private(set) lazy var appMonitor = RunningAppMonitor(keyMonitor: keyMonitor)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — menu bar only
        NSApplication.shared.setActivationPolicy(.accessory)

        // Force lazy initialization so the monitor starts watching immediately
        _ = appMonitor

        // Attempt to start (prompts for accessibility if not granted)
        keyMonitor.start()

        // Poll until accessibility is granted and monitoring starts
        Task {
            while !keyMonitor.isRunning {
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() {
                    keyMonitor.start()
                }
            }
        }
    }
}

// MARK: - Menu Bar Content

struct MenuBarContent: View {
    let keyMonitor: KeyMonitor
    let monitor: RunningAppMonitor

    private typealias AppEntry = (app: AppInfo, letter: String, groupSize: Int)

    private var allEntries: [AppEntry] {
        monitor.appsByLetter.flatMap { letter, apps in
            apps.map { (app: $0, letter: letter, groupSize: apps.count) }
        }
    }

    private var pinnedEntries: [AppEntry] {
        allEntries
            .filter(\.app.isPinned)
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    private var runningEntries: [AppEntry] {
        allEntries
            .filter { !$0.app.isPinned }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pinnedEntries.isEmpty && runningEntries.isEmpty {
                emptyState
            } else {
                if !pinnedEntries.isEmpty {
                    sectionHeader("Pinned")
                    appRows(pinnedEntries)
                }
                if !runningEntries.isEmpty {
                    if !pinnedEntries.isEmpty {
                        Divider()
                    }
                    sectionHeader("Apps")
                    appRows(runningEntries)
                }
            }
            Divider()
            QuitButton()
        }
        .frame(width: 300)
        .onAppear {
            keyMonitor.checkAccessibility()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("RightCommand")
                    .font(.headline)
                Text("Right ⌘ + key to switch apps")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            statusIndicator
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if keyMonitor.isRunning {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if !keyMonitor.hasAccessibility {
            Button("Grant Access") {
                keyMonitor.requestAccessibility()
            }
            .controlSize(.small)
        } else {
            Button("Start") {
                keyMonitor.start()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "command")
                .font(.title2)
                .foregroundStyle(.quaternary)
            Text("No running apps detected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - App List

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func appRows(_ entries: [AppEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(entries, id: \.app.id) { entry in
                HStack(spacing: 10) {
                    Image(nsImage: entry.app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)

                    Text(entry.app.name)
                        .lineLimit(1)

                    Spacer()

                    // Pin toggle
                    Button {
                        if entry.app.isPinned {
                            monitor.unpin(letter: entry.letter)
                        } else {
                            monitor.pin(letter: entry.letter, bundleId: entry.app.bundleId, name: entry.app.name)
                        }
                    } label: {
                        Group {
                            if entry.app.isPinned {
                                Image(systemName: "pin.fill")
                                    .foregroundStyle(.tint)
                            } else {
                                Image(systemName: "pin")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)

                    // Shortcut badge: only if this app owns the shortcut
                    if entry.app.isPinned || monitor.pinnedApps[entry.letter] == nil {
                        ShortcutBadge(
                            letter: entry.letter,
                            shared: !entry.app.isPinned && entry.groupSize > 1
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .opacity(entry.app.isRunning ? 1.0 : 0.6)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Quit Button

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isHovered ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.accentColor : .clear)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Shortcut Badge

/// Renders a keyboard-shortcut hint like native macOS menu items.
/// Shows ⌘ + keycap-styled letter. When multiple apps share the letter, adds a cycling indicator.
struct ShortcutBadge: View {
    let letter: String
    var shared: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if shared {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Text("⌘")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Text(letter)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary)
                )
        }
    }
}
