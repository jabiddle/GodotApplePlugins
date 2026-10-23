import Foundation

/// The platform's answer about access, before the store's own records are weighed against it.
public enum AppleAuthorization: Sendable {
    case notDetermined
    case denied
    case approved
}

/// The access verdict the wire answers. The platform's status never tells a running app of a
/// revocation and reads "never asked" after a relaunch, so it is weighed against two records of
/// this store's own: the approval recorded on this device, and a marker setting the system removes
/// with every other at a revocation.
public enum AccessVerdict {
    public static let notDetermined = "not_determined"
    public static let denied = "denied"
    public static let approved = "approved"
    public static let unsupported = "unsupported"

    /// `""` while the approval is recorded and the marker holds but the platform does not yet read
    /// approved: no record says which, and a premature `denied` would lift a block that holds.
    public static func status(apple: AppleAuthorization, recorded: Bool, markerHolds: Bool) -> String {
        if apple == .approved && markerHolds {
            return approved
        }
        if apple == .denied || (recorded && !markerHolds) {
            return denied
        }
        return recorded ? "" : notDetermined
    }
}

public enum TokenRenewal<App: Hashable, Category: Hashable, Web: Hashable> {
    /// This system cannot renew tokens, so nothing is reported expired.
    case unavailable
    case renewed(TokenSelection<App, Category, Web>)
    case failed

    /// Renews each kind of token `selection` holds through the platform's call for that kind. A call
    /// that throws, or answers a different number of tokens than it was given, fails the whole list:
    /// one that silently lost an app would loosen a block it holds, and old tokens usually still shield.
    public static func renewing(_ selection: TokenSelection<App, Category, Web>,
                                apps: (inout [App]) throws -> Void,
                                categories: (inout [Category]) throws -> Void,
                                web: (inout [Web]) throws -> Void) -> Self {
        func renew<Token: Hashable>(_ tokens: Set<Token>, _ refresh: (inout [Token]) throws -> Void) -> Set<Token>? {
            guard !tokens.isEmpty else {
                return tokens
            }
            var renewed = Array(tokens)
            do {
                try refresh(&renewed)
            } catch {
                return nil
            }
            return renewed.count == tokens.count ? Set(renewed) : nil
        }
        guard let renewedApps = renew(selection.apps, apps), let renewedCategories = renew(selection.categories, categories),
              let renewedWeb = renew(selection.web, web) else {
            return .failed
        }
        return .renewed(TokenSelection(apps: renewedApps, categories: renewedCategories, web: renewedWeb))
    }
}

/// The named stores the shields live in.
public protocol ShieldBackend: AnyObject {
    associatedtype App: Codable & Hashable
    associatedtype Category: Codable & Hashable
    associatedtype Web: Codable & Hashable

    func read(store name: String) -> ShieldContents<App, Category, Web>
    /// Empty contents clear the store.
    func write(store name: String, contents: ShieldContents<App, Category, Web>)
    func markerHolds() -> Bool
    func writeMarker()
    /// Deletes every store the system lists for this app but those named in `names`, where the
    /// system can list them.
    func deleteListedStores(keeping names: Set<String>)
    func renew(_ selection: TokenSelection<App, Category, Web>) -> TokenRenewal<App, Category, Web>
}

public enum WindowStart: Equatable, Sendable {
    case started
    case tooMany
    case failed(String)
}

/// The monitored windows. The monitor never lists them: listing has deadlocked, so the store's own
/// record is what a wake trusts, and only the app compares it with the system's list.
public protocol WindowBackend: AnyObject {
    func start(name: String, window: PlannedWindow) -> WindowStart
    /// Never called with no names: the system reads an empty list as every window.
    func stop(names: [String])
    func stopAll()
}

/// The one evaluator the app and every extension run over the shared store. Every call derives what
/// should hold from the slots and the clock, compares it with what the stores read back, and writes
/// only the difference, so a wake that arrives late, twice or out of order does the right thing.
///
/// One thread at a time per process; the store's lock serialises the processes.
public final class RestrictionEnforcer<Shields: ShieldBackend>: @unchecked Sendable {
    public typealias Selection = TokenSelection<Shields.App, Shields.Category, Shields.Web>
    typealias Contents = ShieldContents<Shields.App, Shields.Category, Shields.Web>

    public let store: RestrictionStore
    public let shields: Shields
    public let windows: WindowBackend
    public var calendar: Calendar
    /// The platform's per-app cap in every class.
    public var cap = 50
    /// How long a wake waits for another process's hold before it skips, leaving the next wake or
    /// the app's reconcile to catch up. Longer than the app's longest hold, a reconcile that renews
    /// every list and lists the system's windows, so a wake skips only behind a hold that is stuck.
    public var wakeLockSeconds: TimeInterval = 5
    let clock: () -> Int

    /// The calendar follows the device's time zone: a `daily` window is a local time.
    public init(store: RestrictionStore, shields: Shields, windows: WindowBackend, calendar: Calendar = .autoupdatingCurrent,
                clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.store = store
        self.shields = shields
        self.windows = windows
        self.calendar = calendar
        self.clock = clock
    }

    struct Tally {
        var applied = 0
        var lifted = 0
        var rearmed = 0
        var errors: [String] = []

        func answer(expired: [String]) -> String {
            WireJSON.text(["applied": applied, "lifted": lifted, "rearmed": rearmed, "errors": errors,
                           "expired_selections": expired])
        }
    }

    // MARK: Access

    public func authorizationState(apple: AppleAuthorization) -> String {
        store.withLock {
            WireJSON.text(["status": status(apple: apple), "was_approved": store.approvalRecorded, "requirements": [Any]()])
        }
    }

    public func status(apple: AppleAuthorization) -> String {
        store.withLock {
            AccessVerdict.status(apple: apple, recorded: store.approvalRecorded, markerHolds: markerChecked(now: clock()))
        }
    }

    /// Whether a write may go ahead: refused only while the verdict is denied or never asked. An
    /// approval recorded here with the marker holding is access, as reconcile reads it, though the
    /// platform has yet to publish approved: just after the prompt, a block set then must hold.
    public func mayWrite(apple: AppleAuthorization) -> Bool {
        let verdict = status(apple: apple)
        return verdict == AccessVerdict.approved || verdict.isEmpty
    }

    /// Records this device's approval and writes the marker, after the platform's prompt approved.
    public func noteApproval() {
        store.withLock {
            store.recordApproval(at: clock())
            shields.writeMarker()
            store.lossReported = false
        }
    }

    /// Whether the marker holds. The first read that finds it gone after an approval appends one
    /// undated loss for each slot that was due, because the system tells the app nothing.
    func markerChecked(now: Int) -> Bool {
        if shields.markerHolds() {
            return true
        }
        if store.approvalRecorded && !store.lossReported && store.schemaMatches {
            let slots = store.slots()
            let events = slots.keys.sorted().filter { RestrictionEvaluator.isDue(slots[$0]!, at: now, calendar: calendar) }.map {
                RestrictionEvent(kind: RestrictionEventKind.lost, slotId: $0, generation: slots[$0]!.spec.generation, atUnix: 0,
                                 reason: RestrictionReason.permission)
            }
            store.appendEvents(events)
            store.lossReported = true
            store.setHeld([:], at: now)
        }
        return false
    }

    // MARK: Selections

    public func selection(_ id: String) -> Selection? {
        id.isEmpty ? nil : store.selection(id)
    }

    public func summary(_ id: String) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return WireJSON.text(["error": RestrictionCode.schemaMismatch])
            }
            guard let held = selection(id) else {
                return WireJSON.text(["error": RestrictionCode.unknownSelection])
            }
            return WireJSON.text(["app_count": held.apps.count, "category_count": held.categories.count,
                                  "web_count": held.web.count, "expired": held.expired, "error": ""])
        }
    }

    public func putSelection(_ selection: Selection, id: String) -> String {
        writeSelections {
            guard !id.isEmpty else {
                return RestrictionCode.unknownSelection
            }
            store.setSelection(selection, id: id)
            return ""
        }
    }

    public func deleteSelection(_ id: String) -> String {
        writeSelections {
            store.deleteSelection(id)
            return ""
        }
    }

    public func copySelection(from: String, to: String) -> String {
        writeSelections {
            guard let source = selection(from), !to.isEmpty else {
                return RestrictionCode.unknownSelection
            }
            store.setSelection(source, id: to)
            return ""
        }
    }

    /// Creates `into` as a copy when it is absent.
    public func unionSelection(from: String, into: String) -> String {
        writeSelections {
            guard let source = selection(from), !into.isEmpty else {
                return RestrictionCode.unknownSelection
            }
            store.setSelection(selection(into).map { $0.union(source) } ?? source, id: into)
            return ""
        }
    }

    public func intersectSelection(from: String, into: String) -> String {
        writeSelections {
            guard let source = selection(from), let target = selection(into) else {
                return RestrictionCode.unknownSelection
            }
            store.setSelection(target.intersection(source), id: into)
            return ""
        }
    }

    /// Counts only, never which tokens.
    public func diffSelections(base: String, other: String) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return WireJSON.text(["error": RestrictionCode.schemaMismatch])
            }
            guard let baseline = selection(base), let compared = selection(other) else {
                return WireJSON.text(["error": RestrictionCode.unknownSelection])
            }
            return WireJSON.text(["added": compared.counts(beyond: baseline).jsonObject,
                                  "removed": baseline.counts(beyond: compared).jsonObject, "error": ""])
        }
    }

    func writeSelections(_ body: () -> String) -> String {
        store.withLock {
            store.schemaMatches ? body() : RestrictionCode.schemaMismatch
        }
    }

    // MARK: Slots

    /// Refuses a malformed spec first, then a missing or oversized list, then a device without
    /// access. A store that reads back empty after the write still answers `""`: the slot reads
    /// inactive and a `refused` event says why, because a code would refuse a save nobody can fix.
    public func setRestriction(slotId: String, json: String, apple: AppleAuthorization) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return RestrictionCode.schemaMismatch
            }
            guard !slotId.isEmpty, let spec = RestrictionSpec.parse(WireJSON.object(json)) else {
                return RestrictionCode.invalidSpec
            }
            for id in spec.selectionIds where !store.hasSelection(id) {
                return RestrictionCode.unknownSelection
            }
            for block in [spec.block] + (spec.retained.map { [$0.block] } ?? []) {
                if selection(block.selectionId)?.exceeds(cap: cap) == true
                    || (selection(block.exceptSelectionId)?.apps.count ?? 0) > cap {
                    return RestrictionCode.selectionTooLarge
                }
            }
            guard mayWrite(apple: apple) else {
                return RestrictionCode.notAuthorized
            }
            var slots = store.slots()
            slots[slotId] = SlotRecord(spec: spec, suspendedUntil: slots[slotId]?.suspendedUntil ?? 0)
            let now = clock()
            let change = windowChange(slots: slots, now: now, listed: nil)
            if change.kept.count + change.starts.count > WakePlanner.windowBudget {
                return RestrictionCode.tooManyWindows
            }
            store.setSlots(slots)
            var tally = Tally()
            apply(at: now, now: now, tally: &tally)
            commitWindows(change, tally: &tally)
            return ""
        }
    }

    /// Lifts the slot now; every evaluation skips it until `until`.
    public func suspendRestriction(slotId: String, until: Int) -> String {
        changeSlot(slotId) { $0.suspendedUntil = until }
    }

    public func resumeRestriction(slotId: String) -> String {
        changeSlot(slotId) { $0.suspendedUntil = 0 }
    }

    /// A slot not held is already cleared.
    public func clearRestriction(slotId: String) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return RestrictionCode.schemaMismatch
            }
            var slots = store.slots()
            guard let removed = slots.removeValue(forKey: slotId) else {
                return ""
            }
            store.setSlots(slots)
            settle(removedGenerations: [slotId: removed.spec.generation])
            return ""
        }
    }

    func changeSlot(_ slotId: String, _ change: (inout SlotRecord) -> Void) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return RestrictionCode.schemaMismatch
            }
            var slots = store.slots()
            guard var record = slots[slotId] else {
                return RestrictionCode.unknownSlot
            }
            change(&record)
            slots[slotId] = record
            store.setSlots(slots)
            settle()
            return ""
        }
    }

    func settle(removedGenerations: [String: Int] = [:]) {
        let now = clock()
        var tally = Tally()
        apply(at: now, now: now, tally: &tally, removedGenerations: removedGenerations)
        commitWindows(windowChange(slots: store.slots(), now: now, listed: nil), tally: &tally)
    }

    /// Every slot with its spec, whether the stores hold it now as read back (`active`), whether
    /// its spec and the clock ask for it (`due`), its suspension and whether its window is shorter
    /// than the platform monitors.
    public func restrictions() -> String {
        store.withLock {
            guard store.schemaMatches else {
                return WireJSON.text(["error": RestrictionCode.schemaMismatch])
            }
            let now = clock()
            let held = store.held()
            var readBack: [String: Bool] = [:]
            var slots: [String: Any] = [:]
            for (slotId, record) in store.slots() {
                var active = false
                if let stores = held[slotId]?.stores {
                    active = stores.allSatisfy { name in
                        if readBack[name] == nil {
                            readBack[name] = !shields.read(store: name).isEmpty
                        }
                        return readBack[name]!
                    }
                }
                slots[slotId] = ["spec": record.spec.jsonObject, "active": active,
                                 "due": RestrictionEvaluator.isDue(record, at: now, calendar: calendar),
                                 "suspended_until": record.suspendedUntil,
                                 "padded": RestrictionEvaluator.isPadded(record.spec, minimumSeconds: WakePlanner.minimumWindowSeconds)]
            }
            return WireJSON.text(["slots": slots, "windows_in_use": store.windows().count, "generation": store.generation,
                                  "error": ""])
        }
    }

    /// Renews every list where the system can, then compares what should hold now with what the
    /// stores and windows read back, and writes only the difference. `listed` is the system's own
    /// list of windows, read by the app alone, and read under the lock: a list read before it is
    /// stale against a wake that registered or stopped a window meanwhile, and the difference would
    /// stop that wake's new window.
    public func reconcile(listed: @autoclosure () -> [String: PlannedWindow]?) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return Tally(errors: [RestrictionCode.schemaMismatch]).answer(expired: [])
            }
            let now = clock()
            // Writes after a revocation are kept but not enforced: a repair would heal into nothing.
            guard markerChecked(now: now) else {
                return Tally(errors: [RestrictionCode.notAuthorized]).answer(expired: [])
            }
            renewSelections()
            var tally = Tally()
            apply(at: now, now: now, tally: &tally)
            commitWindows(windowChange(slots: store.slots(), now: now, listed: listed()), tally: &tally)
            return tally.answer(expired: expiredSelectionIds())
        }
    }

    /// Stops every window, blocks then unblocks every store name, renews every list where the
    /// system can, and applies again from the slots under a new generation, in one call. A clear
    /// alone is not known to lift a shield a deleted install left behind; a block and an unblock is.
    /// A value at another version refuses it; one that cannot be parsed it replaces first, and says
    /// so in `errors`, since every other call refuses that store until then.
    public func rebuild() -> String {
        store.withLock {
            guard store.schemaReading != .otherVersion else {
                return Tally(errors: [RestrictionCode.schemaMismatch]).answer(expired: [])
            }
            let now = clock()
            guard markerChecked(now: now) else {
                return Tally(errors: [RestrictionCode.notAuthorized]).answer(expired: [])
            }
            let reset = store.resetUnparseable()
            var readBack: [String: Contents] = [:]
            for name in ShieldStoreName.fixedSet {
                readBack[name] = shields.read(store: name)
            }
            let heldBefore = holding(store.held(), readBack)
            let attributed = heldBefore.values.reduce(into: Set<String>()) { $0.formUnion($1.stores) }
            let strays = ShieldStoreName.fixedSet.filter { !readBack[$0]!.isEmpty && !attributed.contains($0) }.count
            // Every end callback the stop fires must find a newer generation and do nothing.
            store.generation += 1
            store.setWindows([:])
            windows.stopAll()
            for name in ShieldStoreName.fixedSet {
                shields.write(store: name, contents: .everything)
                shields.write(store: name, contents: Contents())
            }
            shields.deleteListedStores(keeping: Set(ShieldStoreName.fixedSet + [ShieldStoreName.marker]))
            renewSelections()
            var tally = Tally(errors: reset ? [RestrictionCode.storeReset] : [])
            apply(at: now, now: now, tally: &tally, heldBefore: heldBefore)
            tally.lifted = heldBefore.count + strays
            tally.applied = store.held().count
            commitWindows(windowChange(slots: store.slots(), now: now, listed: nil), tally: &tally)
            shields.writeMarker()
            store.lossReported = false
            return tally.answer(expired: expiredSelectionIds())
        }
    }

    /// The system's message that tokens expired, which fires falsely for new users, so it is ignored
    /// while no list is held. Ignored without access too, where every renewal would fail and mark
    /// every list expired.
    public func tokensDidExpire() {
        store.withLock {
            guard store.schemaMatches, !store.selectionIds().isEmpty, markerChecked(now: clock()) else {
                return
            }
            renewSelections()
        }
    }

    /// Every list file in one pass, a retained part's own file among them, before anything is
    /// written from them. A file is written only when its renewal changed it.
    func renewSelections() {
        for id in store.selectionIds() {
            guard let held = selection(id) else {
                continue
            }
            var next = held
            switch shields.renew(held) {
            case .unavailable:
                continue
            case let .renewed(renewed):
                next = renewed
                next.expired = false
            case .failed:
                next.expired = true
            }
            if next != held {
                store.setSelection(next, id: id)
            }
        }
    }

    func expiredSelectionIds() -> [String] {
        store.selectionIds().filter { selection($0)?.expired == true }
    }

    // MARK: Wakes

    /// A window callback. One naming a window of a replaced generation does nothing; any other
    /// evaluates at the boundary it stands for, within the tolerance, and registers the roll's
    /// next windows from the store's record. It never stops its own window, since what a stop does
    /// inside that window's callback is unmeasured: a window no longer wanted, as at its end, stays
    /// recorded for the next wake or reconcile to stop.
    public func handleCallback(windowName: String, isEnd: Bool) {
        _ = store.withLock(within: wakeLockSeconds) {
            guard store.schemaMatches, let window = store.windows()[windowName] else {
                return
            }
            let now = clock()
            guard markerChecked(now: now) else {
                return
            }
            var tally = Tally()
            apply(at: WakePlanner.evaluationInstant(window: window, isEnd: isEnd, now: now, calendar: calendar), now: now,
                  tally: &tally)
            commitWindows(windowChange(slots: store.slots(), now: now, listed: nil, sparing: windowName), tally: &tally)
        }
    }

    /// A wake at the clock, as a tap on a block screen gives.
    public func wake() {
        _ = store.withLock(within: wakeLockSeconds) {
            guard store.schemaMatches else {
                return
            }
            let now = clock()
            guard markerChecked(now: now) else {
                return
            }
            var tally = Tally()
            apply(at: now, now: now, tally: &tally)
            commitWindows(windowChange(slots: store.slots(), now: now, listed: nil), tally: &tally)
        }
    }

    /// After a clock or time-zone change: every window that does not repeat and has not started was
    /// registered as the local time of an instant, so it is registered again from the instant under a
    /// new name.
    public func reregisterWindows() {
        store.withLock {
            guard store.schemaMatches else {
                return
            }
            let now = clock()
            guard markerChecked(now: now) else {
                return
            }
            var tally = Tally()
            apply(at: now, now: now, tally: &tally)
            commitWindows(windowChange(slots: store.slots(), now: now, listed: nil, renewingOnce: true), tally: &tally)
        }
    }

    // MARK: Block screens

    /// Whether a block covers what a shield extension is asked about: an app with its category, a
    /// category alone, as a shield of all apps asks, or a website. A category alone cannot be
    /// tested against an app exception, so a block of all apps covers it.
    public func coverage(app: Shields.App?, category: Shields.Category?, web: Shields.Web?) -> (RestrictionBlock) -> Bool {
        { block in
            let listed = self.selection(block.selectionId) ?? Selection()
            let excepted = app.map { self.selection(block.exceptSelectionId)?.apps.contains($0) == true } ?? false
            if let web {
                return block.mode == .blockAll ? block.blocksAllWeb : listed.web.contains(web)
            }
            if excepted {
                return false
            }
            if block.mode == .blockAll {
                return true
            }
            return app.map { listed.apps.contains($0) } == true || category.map { listed.categories.contains($0) } == true
        }
    }

    /// The block screen over what `covers` matches, from the host's appearances and the slots the
    /// stores held at the last write: nil when no block covers it and no appearance is the fallback,
    /// or while the store is at another version or cannot be parsed, when a button records nothing.
    ///
    /// Takes no lock, because the configuration extension cannot: its sandbox opens nothing in the
    /// App Group for writing, the lock's file included, and iOS draws its own screen in place of one
    /// that waits (screen-time proposal §4.4). A caller that records against the screen holds the
    /// lock around this, as the action extension does.
    public func composeShield(covers: (RestrictionBlock) -> Bool) -> ComposedShield? {
        guard store.schemaMatches else {
            return nil
        }
        return ShieldWords.compose(slots: store.slots(), appearances: store.appearances(), at: clock(), calendar: calendar,
                                   held: Set(store.held().keys), heldAt: store.heldAt,
                                   unreadable: { $0.mode == .blockSelection && self.selection($0.selectionId) == nil },
                                   covers: covers)
    }

    /// A button pressed on a block screen, dated, naming the block the screen named; `""` only when
    /// no block covers what was tapped (screen-time proposal §4.2). The newest that opens the app is
    /// the note the host reads as it comes to the front.
    public func recordShieldButton(slotId: String, button: String) {
        store.withLock {
            guard store.schemaMatches else {
                return
            }
            let generation = store.slots()[slotId]?.spec.generation ?? 0
            store.appendEvents([RestrictionEvent(kind: RestrictionEventKind.shieldButton, slotId: slotId, generation: generation,
                                                 atUnix: clock(), button: button)])
        }
    }

    // MARK: Appearances, notices and events

    public func setAppearance(id: String, json: String, image: Data?) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return RestrictionCode.schemaMismatch
            }
            guard !id.isEmpty, let appearance = WireJSON.object(json) else {
                return RestrictionCode.invalidSpec
            }
            store.setAppearance(appearance, id: id)
            if let image, !image.isEmpty {
                try? image.write(to: store.imageURL(appearanceId: id), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: store.imageURL(appearanceId: id))
            }
            return ""
        }
    }

    public func clearAppearance(id: String) -> String {
        store.withLock {
            guard store.schemaMatches else {
                return RestrictionCode.schemaMismatch
            }
            store.setAppearance(nil, id: id)
            try? FileManager.default.removeItem(at: store.imageURL(appearanceId: id))
            return ""
        }
    }

    /// Accepted and ignored: this platform draws no ongoing notice.
    public func acceptServiceNotice(json: String) -> String {
        guard store.schemaMatches else {
            return RestrictionCode.schemaMismatch
        }
        return WireJSON.object(json) == nil ? RestrictionCode.invalidSpec : ""
    }

    public func appendEvent(_ event: RestrictionEvent) {
        store.withLock {
            if store.schemaMatches {
                store.appendEvents([event])
            }
        }
    }

    /// The newest events, oldest first, removed from the queue.
    public func drainEvents() -> String {
        store.withLock {
            let events = store.schemaMatches ? (store.drainEvents() ?? []) : []
            return WireJSON.text(events.map(\.jsonObject), fallback: "[]")
        }
    }

    // MARK: Writing the stores

    /// Writes the stores that differ from what should hold at `evaluation`, fills before clears so a
    /// hand-over from list stores to the all-apps store leaves no gap, reads each write back, and
    /// appends an event for every slot whose hold changed.
    func apply(at evaluation: Int, now: Int, tally: inout Tally, heldBefore known: [String: HeldSlot]? = nil,
               removedGenerations: [String: Int] = [:]) {
        let slots = store.slots()
        let plan = ShieldPlanner<Shields.App, Shields.Category, Shields.Web>(cap: cap)
            .plan(slots: slots, at: evaluation, calendar: calendar, previousNames: store.listNames()) { self.selection($0) }
        store.setListNames(plan.listNames)
        var readBack: [String: Contents] = [:]
        for name in ShieldStoreName.fixedSet {
            readBack[name] = shields.read(store: name)
        }
        let heldBefore = known ?? holding(store.held(), readBack)
        var written = Set<String>()
        var refused = Set<String>()
        var cleared = Set<String>()
        for name in ShieldStoreName.fixedSet {
            guard let wanted = plan.stores[name], readBack[name] != wanted else {
                continue
            }
            shields.write(store: name, contents: wanted)
            let after = shields.read(store: name)
            readBack[name] = after
            written.insert(name)
            if after.lacksAField(of: wanted) {
                refused.insert(name)
            }
        }
        for name in ShieldStoreName.fixedSet where plan.stores[name] == nil && !readBack[name]!.isEmpty {
            shields.write(store: name, contents: Contents())
            readBack[name] = Contents()
            cleared.insert(name)
        }
        var heldAfter: [String: HeldSlot] = [:]
        var degraded: [String: String] = [:]
        for slotId in plan.cappedSlots {
            degraded[slotId] = RestrictionReason.cap
        }
        for (slotId, stores) in plan.storesBySlot {
            if !stores.isDisjoint(with: refused) {
                degraded[slotId] = RestrictionReason.refused
                continue
            }
            heldAfter[slotId] = HeldSlot(stores: stores, generation: slots[slotId]?.spec.generation ?? 0)
        }
        let generationOf = { (slotId: String) -> Int in
            slots[slotId]?.spec.generation ?? removedGenerations[slotId] ?? heldBefore[slotId]?.generation ?? 0
        }
        var events: [RestrictionEvent] = []
        for slotId in heldAfter.keys.sorted() {
            if heldBefore[slotId] == nil {
                events.append(RestrictionEvent(kind: RestrictionEventKind.started, slotId: slotId,
                                               generation: generationOf(slotId), atUnix: now))
                tally.applied += 1
            } else if !heldAfter[slotId]!.stores.isDisjoint(with: written) {
                tally.applied += 1
            }
        }
        for slotId in heldBefore.keys.sorted() where heldAfter[slotId] == nil {
            events.append(RestrictionEvent(kind: RestrictionEventKind.ended, slotId: slotId, generation: generationOf(slotId),
                                           atUnix: now))
            tally.lifted += 1
        }
        let attributed = heldBefore.values.reduce(into: Set<String>()) { $0.formUnion($1.stores) }
        tally.lifted += cleared.subtracting(attributed).count
        let reported = store.degraded()
        for slotId in degraded.keys.sorted() where reported[slotId] != degraded[slotId] {
            events.append(RestrictionEvent(kind: RestrictionEventKind.degraded, slotId: slotId, generation: generationOf(slotId),
                                           atUnix: now, reason: degraded[slotId]!))
        }
        store.setDegraded(degraded)
        store.setHeld(heldAfter, at: evaluation)
        store.appendEvents(events)
    }

    /// The slots whose every store still reads back holding something.
    func holding(_ held: [String: HeldSlot], _ readBack: [String: Contents]) -> [String: HeldSlot] {
        held.filter { $0.value.stores.allSatisfy { !(readBack[$0]?.isEmpty ?? true) } }
    }

    // MARK: Registering windows

    struct WindowChange {
        var kept: [String: PlannedWindow]
        var starts: [PlannedWindow]
        var stops: [String]
    }

    /// The windows to keep, start and stop. A recorded window the system no longer lists, or lists
    /// resolving to other dates as after a time-zone change, is registered again under a new name; a
    /// listed window the store never recorded is stopped. `sparing` names a window kept whatever
    /// the plan says.
    func windowChange(slots: [String: SlotRecord], now: Int, listed: [String: PlannedWindow]?,
                      renewingOnce: Bool = false, sparing: String? = nil) -> WindowChange {
        let recorded = store.windows()
        var current = recorded
        var stops: [String] = []
        if renewingOnce {
            // A running window could only start again at once, so it keeps its registration.
            for (name, window) in recorded where !window.repeats && !(window.startUnix <= now && now < window.endUnix) {
                current.removeValue(forKey: name)
                stops.append(name)
            }
        }
        if let listed {
            for (name, window) in recorded where !(listed[name].map { $0.sameInterval(window) } ?? false) {
                current.removeValue(forKey: name)
                if listed[name] != nil {
                    stops.append(name)
                }
            }
            stops += listed.keys.filter { recorded[$0] == nil }
        }
        var kept: [String: PlannedWindow] = [:]
        var starts: [PlannedWindow] = []
        for window in WakePlanner.plan(slots: slots, now: now, calendar: calendar, registered: Array(current.values)) {
            if let name = current.keys.sorted().first(where: { current[$0]!.sameInterval(window) }) {
                kept[name] = current.removeValue(forKey: name)
            } else if WakePlanner.registrable(window, now: now, calendar: calendar) {
                starts.append(window)
            }
        }
        if let sparing, let window = current.removeValue(forKey: sparing) {
            kept[sparing] = window
        }
        return WindowChange(kept: kept, starts: starts, stops: stops + current.keys.sorted())
    }

    /// Writes the new set of names first, then stops the old and starts the new: a stopped window's
    /// end fires at once, and must find its name already replaced.
    func commitWindows(_ change: WindowChange, tally: inout Tally) {
        var next = change.kept
        let named = change.starts.map { (store.nextWindowName(kind: $0.kind), $0) }
        for (name, window) in named {
            next[name] = window
        }
        store.setWindows(next)
        if !change.stops.isEmpty {
            windows.stop(names: change.stops)
        }
        for (name, window) in named {
            switch windows.start(name: name, window: window) {
            case .started:
                tally.rearmed += 1
            case .tooMany:
                next.removeValue(forKey: name)
                tally.errors.append(RestrictionCode.tooManyWindows)
            case let .failed(text):
                next.removeValue(forKey: name)
                tally.errors.append(RestrictionCode.platform(text))
            }
        }
        if next.count != change.kept.count + named.count {
            store.setWindows(next)
        }
    }
}
