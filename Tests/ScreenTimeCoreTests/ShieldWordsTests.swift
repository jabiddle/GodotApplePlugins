import XCTest
@testable import ScreenTimeCore

/// One block screen from the host's appearances: a block's own words, two blocks joined by their
/// order with the later end, and the fallback screen for an app no block matches or a block with
/// no appearance; composed without the store's lock.
final class ShieldWordsTests: XCTestCase {
    let now = at(2026, 10, 12, 22, 30)

    func appearance(_ name: String, order: Int, until: String, fallback: Bool = false) -> [String: Any] {
        ["title": "Only " + name, "subtitle": "Until " + until, "name": name, "until": until, "name_order": order,
         "fallback": fallback, "joined_title": "Held by {names}", "joined_subtitle": "Held until {until}.",
         "name_separator": ", ", "name_last_separator": " and "]
    }

    func compose(_ slots: [String: RestrictionSpec], _ appearances: [String: [String: Any]],
                 covers: (RestrictionBlock) -> Bool = { _ in true }) -> ComposedShield? {
        ShieldWords.compose(slots: slots.mapValues { SlotRecord(spec: $0) }, appearances: appearances, at: now,
                            calendar: testCalendar, covers: covers)
    }

    func test_one_covering_block_shows_its_own_words() {
        let shield = compose(["one": onceSpec(now - 60, now + 600, appearance: "first")],
                             ["first": appearance("First", order: 0, until: "soon", fallback: true)])
        XCTAssertEqual(shield, ComposedShield(appearanceId: "first", slotId: "one", title: "Only First", subtitle: "Until soon"))
    }

    func test_two_covering_blocks_are_named_in_order_with_the_later_end() {
        let slots = ["late": dailySpec([1], 22 * 60, 7 * 60, appearance: "night"),
                     "early": onceSpec(now - 60, now + 600, appearance: "first")]
        let appearances = ["first": appearance("First", order: 0, until: "soon", fallback: true),
                           "night": appearance("Night", order: 1, until: "07:00")]
        let shield = compose(slots, appearances)
        XCTAssertEqual(shield, ComposedShield(appearanceId: "first", slotId: "early", title: "Held by First and Night",
                                              subtitle: "Held until 07:00."))
    }

    func test_three_blocks_join_with_the_separator_and_the_last_separator() {
        let slots = ["a": onceSpec(now - 60, now + 900, appearance: "a"), "b": onceSpec(now - 60, now + 600, appearance: "b"),
                     "c": onceSpec(now - 60, now + 300, appearance: "c")]
        let appearances = ["a": appearance("A", order: 2, until: "a"), "b": appearance("B", order: 0, until: "b"),
                           "c": appearance("C", order: 1, until: "c")]
        let shield = compose(slots, appearances)
        XCTAssertEqual(shield?.title, "Held by B, C and A")
        XCTAssertEqual(shield?.subtitle, "Held until a.", "the latest end, which is not the first-named block's")
        XCTAssertEqual(shield?.slotId, "b")
    }

    func test_a_covering_block_without_an_appearance_shows_the_fallback_words_and_names_its_slot() {
        let slots = ["z": onceSpec(now - 60, now + 600, appearance: "missing"), "y": onceSpec(now - 60, now + 600, appearance: "gone")]
        let shield = compose(slots, ["first": appearance("First", order: 0, until: "soon", fallback: true)])
        XCTAssertEqual(shield, ComposedShield(appearanceId: "first", slotId: "y", title: "Only First", subtitle: "Until soon"),
                       "the lowest of the covering slots, so the button still routes to a block")
    }

    func test_a_covering_block_with_an_appearance_is_named_before_one_without() {
        let slots = ["a": onceSpec(now - 60, now + 600, appearance: "night"), "b": onceSpec(now - 60, now + 600, appearance: "missing")]
        let appearances = ["first": appearance("First", order: 0, until: "soon", fallback: true),
                           "night": appearance("Night", order: 1, until: "07:00")]
        XCTAssertEqual(compose(slots, appearances),
                       ComposedShield(appearanceId: "night", slotId: "a", title: "Only Night", subtitle: "Until 07:00"))
    }

    func test_an_app_no_block_matches_gets_the_fallback_screen_naming_no_slot() {
        let shield = compose(["one": onceSpec(now - 60, now + 600, mode: .blockSelection, list: "l", appearance: "night")],
                             ["first": appearance("First", order: 0, until: "soon", fallback: true),
                              "night": appearance("Night", order: 1, until: "07:00")],
                             covers: { _ in false })
        XCTAssertEqual(shield, ComposedShield(appearanceId: "first", slotId: "", title: "Only First", subtitle: "Until soon"))
    }

    func test_coverage_follows_the_lists_the_exceptions_and_the_web_key() {
        let h = Harness(now: now)
        h.approve()
        h.put("allowed", apps: ["kept"])
        h.put("l", apps: ["x"], categories: ["social"], web: ["site"])
        let all = RestrictionBlock(mode: .blockAll, exceptSelectionId: "allowed")
        let allWeb = RestrictionBlock(mode: .blockAll, blocksAllWeb: true)
        let list = RestrictionBlock(mode: .blockSelection, selectionId: "l", exceptSelectionId: "allowed")
        XCTAssertTrue(h.enforcer.coverage(app: "any", category: nil, web: nil)(all))
        XCTAssertFalse(h.enforcer.coverage(app: "kept", category: nil, web: nil)(all))
        XCTAssertTrue(h.enforcer.coverage(app: nil, category: "games", web: nil)(all), "a category alone under all apps")
        XCTAssertTrue(h.enforcer.coverage(app: "x", category: nil, web: nil)(list))
        XCTAssertTrue(h.enforcer.coverage(app: "y", category: "social", web: nil)(list))
        XCTAssertFalse(h.enforcer.coverage(app: "kept", category: "social", web: nil)(list))
        XCTAssertFalse(h.enforcer.coverage(app: "y", category: "games", web: nil)(list))
        XCTAssertTrue(h.enforcer.coverage(app: nil, category: nil, web: "site")(list))
        XCTAssertFalse(h.enforcer.coverage(app: nil, category: nil, web: "site")(all))
        XCTAssertTrue(h.enforcer.coverage(app: nil, category: nil, web: "anywhere")(allWeb))
    }

    func test_a_block_screen_names_its_block_and_a_button_on_it_is_dated_and_queued() {
        let h = Harness(now: now)
        h.approve()
        XCTAssertEqual(h.enforcer.setAppearance(id: "first", json: WireJSON.text(appearance("First", order: 0, until: "soon", fallback: true)),
                                                image: nil), "")
        _ = h.set("one", onceSpec(now - 60, now + 600, generation: 5, appearance: "first"))
        _ = h.drain()
        let shield = h.enforcer.composeShield(covers: h.enforcer.coverage(app: "x", category: nil, web: nil))
        XCTAssertEqual(shield?.slotId, "one")
        h.enforcer.recordShieldButton(slotId: shield!.slotId, button: "secondary")
        XCTAssertEqual(h.drain(), [RestrictionEvent(kind: RestrictionEventKind.shieldButton, slotId: "one", generation: 5, atUnix: now,
                                                    button: "secondary")])
        let unmatched = h.enforcer.composeShield { _ in false }
        XCTAssertEqual(unmatched?.slotId, "")
        XCTAssertEqual(unmatched?.appearanceId, "first")
    }

    func test_a_block_screen_is_composed_while_another_process_holds_the_lock() {
        let h = Harness(now: now)
        h.approve()
        XCTAssertEqual(h.enforcer.setAppearance(id: "first", json: WireJSON.text(appearance("First", order: 0, until: "soon", fallback: true)),
                                                image: nil), "")
        _ = h.set("one", onceSpec(now - 60, now + 600, appearance: "first"))
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ending = DispatchSemaphore(value: 0)
        Thread {
            h.store.withLock {
                holding.signal()
                // Bounded, so a composition that waits for the lock fails below rather than hanging.
                _ = release.wait(timeout: .now() + 2)
                ending.signal()
            }
        }.start()
        holding.wait()
        let shield = h.enforcer.composeShield(covers: h.enforcer.coverage(app: "x", category: nil, web: nil))
        let waited = ending.wait(timeout: .now()) == .success
        release.signal()
        if !waited {
            ending.wait()
        }
        XCTAssertFalse(waited, "the configuration extension cannot open the lock's file, so composing never waits for it")
        XCTAssertEqual(shield?.slotId, "one")
        XCTAssertEqual(shield?.title, "Only First")
    }

    func test_a_covering_block_with_no_appearance_names_its_slot_though_none_is_the_fallback() {
        let shield = compose(["z": onceSpec(now - 60, now + 600, appearance: "missing")], [:])
        XCTAssertEqual(shield, ComposedShield(appearanceId: "", slotId: "z", title: "", subtitle: ""))
        XCTAssertNil(compose(["z": onceSpec(now - 60, now + 600, appearance: "missing")], [:], covers: { _ in false }))
    }

    func test_with_no_due_block_covering_the_slots_the_last_write_held_are_named_as_it_saw_them() {
        let slots = ["ended": SlotRecord(spec: onceSpec(now - 3600, now - 60, appearance: "night")),
                     "list": SlotRecord(spec: onceSpec(now - 60, now + 600, mode: .blockSelection, list: "l", appearance: "first"))]
        let appearances = ["first": appearance("First", order: 0, until: "soon", fallback: true),
                           "night": appearance("Night", order: 1, until: "07:00")]
        let shield = { (held: Set<String>, heldAt: Int) in
            ShieldWords.compose(slots: slots, appearances: appearances, at: self.now, calendar: testCalendar, held: held,
                                heldAt: heldAt, covers: { $0.mode == .blockAll })
        }
        XCTAssertEqual(shield(["ended", "list"], now - 120),
                       ComposedShield(appearanceId: "night", slotId: "ended", title: "Only Night", subtitle: "Until 07:00"))
        XCTAssertEqual(shield(["ended", "list"], 0)?.slotId, "", "a store that recorded no instant names nothing held")
        XCTAssertEqual(shield(["list"], now - 120)?.slotId, "", "a slot the last write did not hold explains no shield")
    }

    func test_a_daily_block_the_last_write_held_is_named_after_the_time_zone_moves() {
        let h = Harness(now: at(2026, 10, 12, 10, 0))
        h.approve()
        h.put("work", apps: ["x"])
        h.put("evening", apps: ["y"])
        for (id, json) in [("first", appearance("First", order: 0, until: "soon", fallback: true)),
                           ("work", appearance("Work", order: 1, until: "17:00")),
                           ("evening", appearance("Evening", order: 2, until: "23:00"))] {
            XCTAssertEqual(h.enforcer.setAppearance(id: id, json: WireJSON.text(json), image: nil), "")
        }
        let everyDay = [1, 2, 3, 4, 5, 6, 7]
        requireSuccess(h.set("work", dailySpec(everyDay, 9 * 60, 17 * 60, mode: .blockSelection, list: "work",
                                                 appearance: "work")))
        requireSuccess(h.set("evening", dailySpec(everyDay, 18 * 60, 23 * 60, mode: .blockSelection, list: "evening",
                                                    appearance: "evening")))
        _ = h.drain()
        XCTAssertEqual(h.store.held().keys.sorted(), ["work"])
        // Three hours west, 10:30 at the write's zone reads 07:30: neither now nor the write's instant
        // falls inside 09:00 to 17:00 there, while the stores still hold the period.
        var west = testCalendar
        west.timeZone = TimeZone(secondsFromGMT: 3600 - 3 * 3600)!
        h.enforcer.calendar = west
        h.now += 30 * 60
        let shield = { (app: String) in h.enforcer.composeShield(covers: h.enforcer.coverage(app: app, category: nil, web: nil)) }
        XCTAssertEqual(shield("x"), ComposedShield(appearanceId: "work", slotId: "work", title: "Only Work", subtitle: "Until 17:00"))
        XCTAssertEqual(shield("y")?.slotId, "", "a slot the last write did not hold explains no shield")
        XCTAssertEqual(ShieldWords.compose(slots: h.store.slots(), appearances: h.store.appearances(), at: h.now, calendar: west,
                                           held: ["work"], heldAt: h.now - 1800, covers: { _ in true })?.slotId, "work")
        var suspended = h.store.slots()
        suspended["work"]!.suspendedUntil = h.now
        XCTAssertEqual(ShieldWords.compose(slots: suspended, appearances: h.store.appearances(), at: h.now, calendar: west,
                                           held: ["work"], heldAt: h.now - 1800, covers: { _ in true })?.slotId, "",
                       "a slot suspended at the write held nothing then")
    }

    func test_a_due_block_that_covers_is_named_alone_before_any_the_last_write_held() {
        let slots = ["ended": SlotRecord(spec: onceSpec(now - 3600, now - 60, appearance: "night")),
                     "due": SlotRecord(spec: onceSpec(now - 60, now + 600, appearance: "first"))]
        let appearances = ["first": appearance("First", order: 0, until: "soon", fallback: true),
                           "night": appearance("Night", order: 1, until: "07:00")]
        let shield = ShieldWords.compose(slots: slots, appearances: appearances, at: now, calendar: testCalendar,
                                         held: ["ended", "due"], heldAt: now - 120, covers: { _ in true })
        XCTAssertEqual(shield, ComposedShield(appearanceId: "first", slotId: "due", title: "Only First", subtitle: "Until soon"))
    }

    func test_a_due_block_whose_list_cannot_be_read_is_named_only_when_nothing_else_covers() {
        let slots = ["a": SlotRecord(spec: onceSpec(now - 60, now + 600, mode: .blockSelection, list: "torn", appearance: "night")),
                     "b": SlotRecord(spec: onceSpec(now - 60, now + 600, mode: .blockSelection, list: "fine", appearance: "first"))]
        let appearances = ["first": appearance("First", order: 0, until: "soon", fallback: true),
                           "night": appearance("Night", order: 1, until: "07:00")]
        let shield = { (covers: (RestrictionBlock) -> Bool) in
            ShieldWords.compose(slots: slots, appearances: appearances, at: self.now, calendar: testCalendar,
                                unreadable: { $0.selectionId == "torn" }, covers: covers)?.slotId
        }
        XCTAssertEqual(shield { $0.selectionId == "fine" }, "b")
        XCTAssertEqual(shield { _ in false }, "a")
    }

    func test_a_block_not_due_covers_nothing() {
        let shield = compose(["one": onceSpec(now + 60, now + 600, appearance: "night")],
                             ["night": appearance("Night", order: 1, until: "07:00")])
        XCTAssertNil(shield)
    }
}
