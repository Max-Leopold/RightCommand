import Cocoa
import CoreGraphics

// MARK: - Key Mappings (US keyboard layout keyCodes)

let charToKeyCode: [String: UInt16] = [
    "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
    "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
    "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
    "Y": 16, "Z": 6,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
    "7": 26, "8": 28, "9": 25, "0": 29,
]

// MARK: - Global state for CGEventTap callback (accessed only from main thread)

/// Right Command key device-dependent flag (NX_DEVICERCMDKEYMASK from IOKit)
private let kRightCmdFlag: UInt64 = 0x10
private let kCommandMask = UInt64(CGEventFlags.maskCommand.rawValue)

nonisolated(unsafe) private var gRightCmdDown = false
/// keyCode → sorted list of bundle identifiers (sorted by app display name)
nonisolated(unsafe) private var gAppsByKey: [UInt16: [String]] = [:]
/// keyCode → bundle identifier of the last app we activated (for cycling)
nonisolated(unsafe) private var gLastActivatedByKey: [UInt16: String] = [:]
nonisolated(unsafe) private var gEventTap: CFMachPort?
nonisolated(unsafe) private var gRunLoopSource: CFRunLoopSource?

// MARK: - CGEventTap Callback

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    // Re-enable tap if the system disabled it due to timeout
    if type == .tapDisabledByTimeout {
        if let tap = gEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags.rawValue

    if type == .flagsChanged {
        gRightCmdDown = (flags & kRightCmdFlag) != 0 && (flags & kCommandMask) != 0
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown, gRightCmdDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let apps = gAppsByKey[keyCode], !apps.isEmpty {
            // Cycle synchronously: if last activated is in the list, pick the next one
            let lastId = gLastActivatedByKey[keyCode]
            var nextIndex = 0
            if let lastId, let idx = apps.firstIndex(of: lastId) {
                nextIndex = (idx + 1) % apps.count
            }
            let targetId = apps[nextIndex]
            gLastActivatedByKey[keyCode] = targetId

            Task { @MainActor in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetId) else {
                    print("RightCommand: no URL for bundle \(targetId)")
                    return
                }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                do {
                    try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                } catch {
                    print("RightCommand: failed to activate \(targetId): \(error)")
                }
            }
            return nil // suppress the event
        }
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - KeyMonitor

@Observable
final class KeyMonitor {
    var isRunning = false
    var hasAccessibility = false

    func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard !isRunning else { return }

        guard AXIsProcessTrusted() else {
            hasAccessibility = false
            requestAccessibility()
            return
        }
        hasAccessibility = true

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            print("RightCommand: failed to create event tap — ensure Accessibility is granted.")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        gEventTap = tap
        gRunLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isRunning = true
    }

    func stop() {
        guard let tap = gEventTap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = gRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            gRunLoopSource = nil
        }
        CFMachPortInvalidate(tap)
        gEventTap = nil
        gRightCmdDown = false

        isRunning = false
    }

    func updateAppMappings(_ map: [UInt16: [String]]) {
        gAppsByKey = map
        // Prune stale cycling state: remove entries for keyCodes no longer mapped
        // or where the last-activated bundleId is no longer in the list
        for (keyCode, bundleId) in gLastActivatedByKey {
            guard let apps = map[keyCode], apps.contains(bundleId) else {
                gLastActivatedByKey.removeValue(forKey: keyCode)
                continue
            }
        }
    }
}
