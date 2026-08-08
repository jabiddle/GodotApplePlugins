import Foundation

/// The kinds of payload the OS can hand us.
///
/// Raw values cross into GDScript verbatim through `DeepLinkManager.drain_pending()`, so they
/// have to stay in sync with the `match` in `native_bridge.gd`.
enum DeepLinkKind: String, Sendable {
    case quickAction
    case universalLink
    case customURL
}

struct DeepLinkEvent: Sendable {
    let kind: DeepLinkKind
    let payload: String
    let at: TimeInterval
}

/// The Godot-facing end of the queue.
protocol DeepLinkSink: AnyObject, Sendable {
    func deliverDeepLink(_ event: DeepLinkEvent)
}

/// Buffers deep link payloads on their way from UIKit into Godot.
///
/// Deliberately not a Godot object. Payloads arrive during
/// `application:didFinishLaunchingWithOptions:` and scene connection — long before GDScript has
/// instantiated `DeepLinkManager` — and they have to survive that object being released and
/// re-created.
final class DeepLinkQueue: @unchecked Sendable {

    nonisolated(unsafe) static let shared = DeepLinkQueue()

    /// Identical payloads arriving inside this window count as a single delivery. Godot fans out
    /// both the scene callbacks and the legacy application callbacks, so one tap can legitimately
    /// reach us twice.
    private static let dedupeWindow: TimeInterval = 1.0

    /// Cap on the backlog, so a build where GDScript never attaches cannot grow without bound.
    private static let maxBuffered = 16

    private let lock = NSLock()
    private var buffered: [DeepLinkEvent] = []
    private var recent: [DeepLinkEvent] = []
    private weak var sink: (any DeepLinkSink)?
    private var sinkIsReady = false

    // MARK: - Producer side (called from the UIKit/AppKit callbacks)

    func enqueue(_ kind: DeepLinkKind, _ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let event = DeepLinkEvent(
            kind: kind,
            payload: trimmed,
            at: Date.timeIntervalSinceReferenceDate
        )

        lock.lock()

        recent.removeAll { event.at - $0.at > Self.dedupeWindow }
        if recent.contains(where: { $0.kind == event.kind && $0.payload == event.payload }) {
            lock.unlock()
            return
        }
        recent.append(event)

        let target: (any DeepLinkSink)? = sinkIsReady ? sink : nil
        if target == nil {
            buffered.append(event)
            if buffered.count > Self.maxBuffered {
                buffered.removeFirst(buffered.count - Self.maxBuffered)
            }
        }

        lock.unlock()

        if let target {
            Self.onMain { target.deliverDeepLink(event) }
        }
    }

    // MARK: - Consumer side (called from DeepLinkManager)

    func attach(_ newSink: any DeepLinkSink) {
        lock.lock()
        sink = newSink
        sinkIsReady = false
        lock.unlock()
    }

    func detach(_ oldSink: any DeepLinkSink) {
        lock.lock()
        // `sink` is weak, so by the time a sink's `deinit` runs the reference has already been
        // zeroed — hence the nil check. A sink that has since been replaced is left alone.
        if sink == nil || sink === oldSink {
            sink = nil
            sinkIsReady = false
        }
        lock.unlock()
    }

    /// Marks the attached sink as wired up, and flushes anything that arrived in the meantime.
    ///
    /// This closes the window between `drainPending()` and GDScript finishing `_ready`: payloads
    /// landing in between are buffered by `enqueue` and released here rather than stranded.
    func markReady() {
        lock.lock()
        sinkIsReady = true
        let target = sink
        let pending = buffered
        buffered.removeAll()
        lock.unlock()

        guard let target, !pending.isEmpty else { return }
        Self.onMain {
            for event in pending {
                target.deliverDeepLink(event)
            }
        }
    }

    /// Removes and returns everything buffered so far, oldest first.
    func drainPending() -> [DeepLinkEvent] {
        lock.lock()
        defer { lock.unlock() }
        let pending = buffered
        buffered.removeAll()
        return pending
    }

    /// Removes and returns the oldest buffered payload of `kind`, if any.
    ///
    /// Only used by the legacy `check_pending_*` callables, which cannot express ordering across
    /// kinds. Prefer `drainPending()`.
    func drainFirst(_ kind: DeepLinkKind) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = buffered.firstIndex(where: { $0.kind == kind }) else { return nil }
        return buffered.remove(at: index).payload
    }

    /// Godot's main loop lives on the main thread on Apple platforms, and signals must be emitted
    /// from it. Delivering inline when we are already there preserves arrival order.
    private static func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
