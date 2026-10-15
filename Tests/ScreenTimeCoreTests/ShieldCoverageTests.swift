import XCTest
@testable import ScreenTimeCore

/// A button on a block screen names a slot whenever something the bridge holds explains the shield,
/// so an empty slot means only an identity no held list matches (screen-time proposal §4.2).
/// Each case shields through the enforcer, then taps every way iOS hands an extension the item a
/// store shields: the app's token where a store lists it, its category where a category policy
/// covers it, as under a shield of every app, and a website's token.
final class ShieldCoverageTests: XCTestCase {
    let now = at(2026, 10, 12, 10, 0)

    enum Tap {
        case app(String)
        case category(String)
        case appInCategory(String, String)
        case web(String)
    }

    func harness() -> Harness {
        let h = Harness(now: now)
        h.approve()
        appear(h, "wide", order: 0, fallback: true)
        appear(h, "late", order: 1)
        appear(h, "day", order: 2)
        return h
    }

    func appear(_ h: Harness, _ id: String, order: Int, fallback: Bool = false) {
        let appearance: [String: Any] = ["title": "Only " + id, "subtitle": "", "name": id, "until": id, "name_order": order,
                                         "fallback": fallback, "joined_title": "Held by {names}", "joined_subtitle": "",
                                         "name_separator": ", ", "name_last_separator": " and "]
        requireSuccess(h.enforcer.setAppearance(id: id, json: WireJSON.text(appearance), image: nil))
    }

    /// Every way iOS can hand the extensions an app in `category` that the fake stores shield; none
    /// when no store shields it.
    func taps(_ h: Harness, app: String, category: String) -> [Tap] {
        let stores = Array(h.shields.stores.values)
        var taps: [Tap] = []
        if stores.contains(where: { $0.apps.contains(app) }) {
            taps.append(.app(app))
        }
        let byCategory = stores.contains { contents in
            switch contents.categories {
            case .none:
                return false
            case let .all(except):
                return !except.contains(app)
            case let .specific(categories, except):
                return categories.contains(category) && !except.contains(app)
            }
        }
        if byCategory {
            taps += [.category(category), .appInCategory(app, category)]
        }
        return taps
    }

    func webTaps(_ h: Harness, _ web: String) -> [Tap] {
        h.shields.stores.values.contains { $0.webDomains.contains(web) || $0.allWebDomains } ? [.web(web)] : []
    }

    func named(_ h: Harness, _ tap: Tap) -> String? {
        let covers: (RestrictionBlock) -> Bool
        switch tap {
        case let .app(app):
            covers = h.enforcer.coverage(app: app, category: nil, web: nil)
        case let .category(category):
            covers = h.enforcer.coverage(app: nil, category: category, web: nil)
        case let .appInCategory(app, category):
            covers = h.enforcer.coverage(app: app, category: category, web: nil)
        case let .web(web):
            covers = h.enforcer.coverage(app: nil, category: nil, web: web)
        }
        return h.enforcer.composeShield(covers: covers)?.slotId
    }

    func assertEveryTapNames(_ h: Harness, _ taps: [Tap], _ slot: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(taps.isEmpty, "a store shields the item", file: file, line: line)
        for tap in taps {
            XCTAssertEqual(named(h, tap), slot, "\(tap)", file: file, line: line)
        }
    }

    func test_an_app_a_save_took_from_a_running_list_is_named_by_its_slots_retained_part() {
        let h = harness()
        h.put("night", apps: ["x"])
        h.put("night.was", apps: ["x", "y"], categories: ["games"])
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockSelection, selectionId: "night.was"), untilUnix: now + 1800)
        XCTAssertEqual(h.set("late", onceSpec(now - 600, now + 900, mode: .blockSelection, list: "night", appearance: "late",
                                             retained: retained)), "")
        assertEveryTapNames(h, taps(h, app: "y", category: "social"), "late")
        assertEveryTapNames(h, taps(h, app: "g", category: "games"), "late")

        h.now = now + 1200
        h.enforcer.wake()
        XCTAssertNil(RestrictionTime.periodEnd(h.store.slots()["late"]!.spec.window, at: h.now, calendar: testCalendar),
                     "the period's own block has ended, and only its retained part holds")
        assertEveryTapNames(h, taps(h, app: "y", category: "social"), "late")
    }

    func test_under_a_block_of_all_apps_a_category_names_that_block_and_one_whose_list_holds_the_category() {
        let h = harness()
        h.put("allowed", apps: ["kept"])
        h.put("night", apps: ["z"], categories: ["social"])
        XCTAssertEqual(h.set("wide", onceSpec(now - 60, now + 3600, except: "allowed", appearance: "wide")), "")
        XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", except: "allowed",
                                             appearance: "late")), "")
        assertEveryTapNames(h, taps(h, app: "q", category: "games"), "wide")
        assertEveryTapNames(h, taps(h, app: "s", category: "social"), "wide")
        let joined = h.enforcer.composeShield(covers: h.enforcer.coverage(app: nil, category: "social", web: nil))
        XCTAssertEqual(joined?.title, "Held by wide and late", "the list whose categories hold it covers it too")

        let lists = harness()
        lists.put("night", apps: ["z"], categories: ["social"])
        XCTAssertEqual(lists.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        assertEveryTapNames(lists, taps(lists, app: "s", category: "social"), "late")
        XCTAssertTrue(taps(lists, app: "q", category: "games").isEmpty)
    }

    func test_websites_are_named_by_a_block_of_all_websites_and_by_the_list_that_holds_them() {
        let h = harness()
        h.put("night", apps: ["z"], web: ["site"])
        XCTAssertEqual(h.set("wide", onceSpec(now - 60, now + 3600, allWeb: true, appearance: "wide")), "")
        XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        assertEveryTapNames(h, webTaps(h, "anywhere"), "wide")
        assertEveryTapNames(h, webTaps(h, "site"), "wide")

        let apps = harness()
        apps.put("night", apps: ["z"], web: ["site"])
        XCTAssertEqual(apps.set("wide", onceSpec(now - 60, now + 3600, appearance: "wide")), "")
        XCTAssertEqual(apps.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        assertEveryTapNames(apps, webTaps(apps, "site"), "late")
        XCTAssertTrue(webTaps(apps, "anywhere").isEmpty, "a block of all apps without the key leaves the web open")

        let lists = harness()
        lists.put("night", web: ["site"])
        XCTAssertEqual(lists.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        assertEveryTapNames(lists, webTaps(lists, "site"), "late")
    }

    func test_an_app_every_block_excepts_is_shielded_by_no_store_so_no_tap_reaches_an_extension() {
        let h = harness()
        h.put("allowed", apps: ["kept"])
        h.put("night", apps: ["z"], categories: ["social"])
        XCTAssertEqual(h.set("wide", onceSpec(now - 60, now + 3600, except: "allowed", appearance: "wide")), "")
        XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", except: "allowed",
                                             appearance: "late")), "")
        XCTAssertTrue(taps(h, app: "kept", category: "games").isEmpty)
        XCTAssertEqual(named(h, .app("kept")), "", "and were one to arrive it would name no block")

        XCTAssertEqual(h.enforcer.clearRestriction(slotId: "wide"), "")
        XCTAssertTrue(taps(h, app: "kept", category: "social").isEmpty, "a list's categories carry the exception")
    }

    func test_a_shield_left_up_past_its_blocks_end_names_that_block_until_a_wake_lifts_it() {
        let h = harness()
        h.put("night", apps: ["x"])
        h.put("work", apps: ["w"])
        XCTAssertEqual(h.set("late", dailySpec([1], 9 * 60, 10 * 60 + 30, mode: .blockSelection, list: "night", appearance: "late")), "")
        XCTAssertEqual(h.set("day", onceSpec(now - 60, now + 7200, mode: .blockSelection, list: "work", appearance: "day")), "")
        XCTAssertEqual(h.store.heldAt, now)
        _ = h.drain()

        h.now = at(2026, 10, 12, 10, 40)
        let stale = taps(h, app: "x", category: "social")
        assertEveryTapNames(h, stale, "late")
        h.enforcer.recordShieldButton(slotId: named(h, .app("x")) ?? "", button: "secondary")

        h.enforcer.wake()
        XCTAssertEqual(h.store.heldAt, h.now)
        XCTAssertTrue(taps(h, app: "x", category: "social").isEmpty, "the wake lifts the shield")
        XCTAssertEqual(named(h, .app("x")), "", "a tap racing the lift names nothing, after the end the queue holds")
        XCTAssertEqual(h.drain().map { $0.kind + "@" + $0.slotId },
                       [RestrictionEventKind.shieldButton + "@late", RestrictionEventKind.ended + "@late"])
    }

    func test_a_retained_part_past_its_instant_still_in_the_store_names_its_slot() {
        let h = harness()
        h.put("night", apps: ["x"])
        h.put("night.was", apps: ["x", "y"])
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockSelection, selectionId: "night.was"), untilUnix: now + 60)
        XCTAssertEqual(h.set("late", onceSpec(now - 600, now + 3600, mode: .blockSelection, list: "night", appearance: "late",
                                             retained: retained)), "")
        h.now = now + 600
        assertEveryTapNames(h, taps(h, app: "y", category: "social"), "late")
    }

    func test_a_covering_block_is_named_though_no_appearance_is_written() {
        let h = Harness(now: now)
        h.approve()
        h.put("night", apps: ["x"])
        XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        let shield = h.enforcer.composeShield(covers: h.enforcer.coverage(app: "x", category: nil, web: nil))
        XCTAssertEqual(shield?.slotId, "late")
        XCTAssertEqual(shield?.appearanceId, "", "the system's own screen, since the host wrote no words")
        XCTAssertNil(h.enforcer.composeShield(covers: h.enforcer.coverage(app: "q", category: nil, web: nil)))
    }

    func test_a_due_list_the_extension_cannot_read_is_named_rather_than_reported_unmatched() {
        let h = harness()
        h.put("night", apps: ["x"])
        h.put("work", apps: ["w"])
        XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        XCTAssertEqual(h.set("day", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "work", appearance: "day")), "")
        try? Data("{\"sche".utf8).write(to: h.store.selectionURL("night"))
        XCTAssertTrue(h.store.schemaMatches, "a list's own file reads as absent, and the store stays readable")
        XCTAssertEqual(named(h, .app("x")), "late")
        XCTAssertEqual(named(h, .app("w")), "day", "a list that reads names its own block first")
    }

    func test_a_tap_over_a_store_that_cannot_be_read_records_nothing_so_it_never_asks_for_a_pick() {
        for torn in [Data("2".utf8), Data("v1".utf8)] {
            let h = harness()
            h.put("night", apps: ["x"])
            XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
            _ = h.drain()
            h.values.values[RestrictionStore.schemaKey] = torn
            let shield = h.enforcer.composeShield(covers: h.enforcer.coverage(app: "q", category: nil, web: nil))
            XCTAssertNil(shield)
            h.enforcer.recordShieldButton(slotId: shield?.slotId ?? "", button: "secondary")
            h.values.values[RestrictionStore.schemaKey] = Data("1".utf8)
            XCTAssertTrue(h.drain().isEmpty)
        }
    }

    func test_an_identity_no_held_list_matches_still_names_no_slot() {
        let h = harness()
        h.put("night", apps: ["x"])
        XCTAssertEqual(h.set("late", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "night", appearance: "late")), "")
        let shield = h.enforcer.composeShield(covers: h.enforcer.coverage(app: "x-renamed", category: nil, web: nil))
        XCTAssertEqual(shield?.slotId, "")
        XCTAssertEqual(shield?.appearanceId, "wide")
    }
}
