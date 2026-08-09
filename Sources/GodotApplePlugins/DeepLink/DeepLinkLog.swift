import Foundation
@preconcurrency import SwiftGodotRuntime

/// In-memory trace of everything the deep link pipeline does.
///
/// Deep links can only be exercised on a real device, usually against a release build, where the
/// interesting events happen during launch before any UI exists. Keeping the trace in memory lets
/// `DeepLinkManager.get_debug_state()` hand the whole story to GDScript after the fact, instead of
/// requiring a Mac and Console.app to catch a log line emitted three seconds earlier.
enum DeepLinkLog {

    private static let maxEntries = 64
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String] = []

    static func write(_ message: String) {
        let line = String(format: "[DeepLink %.3f] %@", ProcessInfo.processInfo.systemUptime, message)

        lock.lock()
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        // NSLog alone is enough to reach Console.app on a device, even for a release build. Both
        // NSLog and GD.print independently shim through the legacy ASL bridge, so calling both
        // makes every line appear four times over (a default/info pair from each) with no
        // difference in content — confusing, and easy to mistake for duplicate registration.
        NSLog("%@", line)
    }

    static func trace() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
