import XCTest
@testable import ScreenTimeCore

/// One block screen from the host's appearances: a block's own words, two blocks joined by their
/// order with the later end, and the fallback screen for an app no block matches.
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
        let slots = ["a": onceSpec(now - 60, now + 600, appearance: "a"), "b": onceSpec(now - 60, now + 900, appearance: "b"),
                     "c": onceSpec(now - 60, now + 300, appearance: "c")]
        let appearances = ["a": appearance("A", order: 2, until: "a"), "b": appearance("B", order: 0, until: "b"),
                           "c": appearance("C", order: 1, until: "c")]
        let shield = compose(slots, appearances)
        XCTAssertEqual(shield?.title, "Held by B, C and A")
        XCTAssertEqual(shield?.subtitle, "Held until b.")
        XCTAssertEqual(shield?.slotId, "b")
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

    func test_a_block_not_due_covers_nothing() {
        let shield = compose(["one": onceSpec(now + 60, now + 600, appearance: "night")],
                             ["night": appearance("Night", order: 1, until: "07:00")])
        XCTAssertNil(shield)
    }
}
