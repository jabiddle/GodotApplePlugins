import XCTest
@testable import ScreenTimeCore

/// The stores an instant asks for: which store holds what, which exceptions ride where, names that
/// never move while held, and the caps in every class.
final class ShieldPlannerTests: XCTestCase {
    let now = at(2026, 10, 12, 10, 0)
    var lists: [String: Selection] = [:]

    func plan(_ slots: [String: RestrictionSpec], names: [String: String] = [:], cap: Int = 50)
        -> ShieldPlan<String, String, String> {
        ShieldPlanner<String, String, String>(cap: cap).plan(
            slots: slots.mapValues { SlotRecord(spec: $0) }, at: now, calendar: testCalendar, previousNames: names
        ) { self.lists[$0] }
    }

    func running(_ mode: RestrictionMode = .blockAll, list: String = "", except: String = "", allWeb: Bool = false,
                 retained: RetainedBlock? = nil) -> RestrictionSpec {
        onceSpec(now - 600, now + 3600, mode: mode, list: list, except: except, allWeb: allWeb, retained: retained)
    }

    func test_the_all_apps_store_excepts_only_what_every_all_apps_block_excepts() {
        lists = ["e1": Selection(apps: ["a", "b"]), "e2": Selection(apps: ["b", "c"])]
        let result = plan(["one": running(except: "e1"), "two": running(except: "e2")])
        XCTAssertEqual(result.stores[ShieldStoreName.all], Contents(categories: .all(except: ["b"])))
        XCTAssertEqual(result.storesBySlot["one"], [ShieldStoreName.all])
    }

    func test_an_all_apps_block_with_no_exceptions_list_excepts_nothing() {
        lists = ["e1": Selection(apps: ["a"])]
        let result = plan(["one": running(except: "e1"), "two": running()])
        XCTAssertEqual(result.stores[ShieldStoreName.all]?.categories, .all(except: []))
    }

    func test_block_all_web_also_shields_every_website() {
        XCTAssertTrue(plan(["one": running(allWeb: true)]).stores[ShieldStoreName.all]!.allWebDomains)
        XCTAssertFalse(plan(["one": running()]).stores[ShieldStoreName.all]!.allWebDomains)
        lists = ["l": Selection(apps: ["x"])]
        XCTAssertNil(plan(["one": running(.blockSelection, list: "l", allWeb: true)]).stores[ShieldStoreName.all],
                     "a block of one list ignores the key")
    }

    func test_a_lists_websites_move_to_a_store_of_their_own_while_all_apps_are_shielded() {
        lists = ["l": Selection(apps: ["x"], web: ["w"])]
        let result = plan(["all": running(), "list": running(.blockSelection, list: "l")])
        XCTAssertEqual(result.stores[ShieldStoreName.web], Contents(webDomains: ["w"]))
        XCTAssertEqual(Set(result.stores.keys), [ShieldStoreName.all, ShieldStoreName.web])
        XCTAssertEqual(result.storesBySlot["list"], [ShieldStoreName.all, ShieldStoreName.web])
    }

    func test_an_app_a_due_list_blocks_is_not_excepted_by_the_all_apps_store() {
        lists = ["allowed": Selection(apps: ["x", "y"]), "l": Selection(apps: ["x"])]
        let result = plan(["all": running(except: "allowed"), "list": running(.blockSelection, list: "l")])
        XCTAssertEqual(result.stores[ShieldStoreName.all]?.categories, .all(except: ["y"]))
    }

    func test_a_list_store_leaves_allowed_apps_out_and_carries_no_exceptions_without_categories() {
        lists = ["l": Selection(apps: ["x", "y"]), "allowed": Selection(apps: ["y"])]
        let result = plan(["list": running(.blockSelection, list: "l", except: "allowed")])
        XCTAssertEqual(result.stores["list1"], Contents(apps: ["x"]))
    }

    func test_a_list_store_with_categories_carries_the_exceptions() {
        lists = ["l": Selection(categories: ["social"], web: ["w"]), "allowed": Selection(apps: ["y"])]
        let result = plan(["list": running(.blockSelection, list: "l", except: "allowed")])
        XCTAssertEqual(result.stores["list1"], Contents(categories: .specific(["social"], except: ["y"]), webDomains: ["w"]))
    }

    func test_a_retained_part_rides_its_slots_own_list_store_until_its_instant() {
        lists = ["games": Selection(apps: ["g"]), "kept": Selection(apps: ["s"])]
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockSelection, selectionId: "kept"), untilUnix: now + 1800)
        let result = plan(["slot": running(.blockSelection, list: "games", retained: retained)])
        XCTAssertEqual(result.stores, ["list1": Contents(apps: ["g", "s"])])
        XCTAssertEqual(result.listNames, ["games": "list1"])
    }

    func test_a_retained_list_beside_an_all_apps_block_keeps_only_its_websites_apart() {
        lists = ["kept": Selection(apps: ["s"], web: ["w"])]
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockSelection, selectionId: "kept"), untilUnix: now + 1800)
        let result = plan(["slot": running(retained: retained)])
        XCTAssertEqual(Set(result.stores.keys), [ShieldStoreName.all, ShieldStoreName.web])
    }

    func test_a_list_keeps_its_store_name_while_it_stays_due() {
        let first = ShieldPlanner<String, String, String>.assignNames(keys: ["a", "b"], previous: [:])
        XCTAssertEqual(first, ["a": "list1", "b": "list2"])
        let second = ShieldPlanner<String, String, String>.assignNames(keys: ["b"], previous: first)
        XCTAssertEqual(second, ["b": "list2"])
        let third = ShieldPlanner<String, String, String>.assignNames(keys: ["b", "c"], previous: second)
        XCTAssertEqual(third, ["b": "list2", "c": "list1"])
    }

    func test_lists_past_eight_fold_into_the_last_name() {
        let keys = Set((0..<10).map { "k\($0)" })
        let names = ShieldPlanner<String, String, String>.assignNames(keys: keys, previous: [:])
        XCTAssertEqual(names["k7"], "list8")
        XCTAssertEqual(names["k8"], "list8")
        XCTAssertEqual(names["k9"], "list8")
        XCTAssertEqual(Set(names.values).count, 8)
    }

    func test_folded_lists_share_the_last_store() {
        var slots: [String: RestrictionSpec] = [:]
        for index in 0..<9 {
            lists["k\(index)"] = Selection(apps: ["app\(index)"])
            slots["s\(index)"] = running(.blockSelection, list: "k\(index)")
        }
        let result = plan(slots)
        XCTAssertEqual(result.stores["list8"]?.apps, ["app7", "app8"])
        XCTAssertTrue(result.cappedSlots.isEmpty)
    }

    func test_the_apps_cap_drops_the_later_list_and_names_its_slot() {
        lists = ["a": Selection(apps: tokens("a", 30)), "b": Selection(apps: tokens("b", 30))]
        let result = plan(["first": running(.blockSelection, list: "a"), "second": running(.blockSelection, list: "b")])
        XCTAssertEqual(Set(result.stores.keys), ["list1"])
        XCTAssertEqual(result.cappedSlots, ["second"])
        XCTAssertNil(result.storesBySlot["second"])
    }

    func test_the_categories_and_web_caps_count_across_stores() {
        lists = ["a": Selection(categories: tokens("c", 26)), "b": Selection(categories: tokens("d", 25))]
        XCTAssertEqual(plan(["first": running(.blockSelection, list: "a"), "second": running(.blockSelection, list: "b")])
            .cappedSlots, ["second"])
        lists = ["a": Selection(web: tokens("w", 40)), "b": Selection(web: tokens("v", 11))]
        XCTAssertEqual(plan(["first": running(.blockSelection, list: "a"), "second": running(.blockSelection, list: "b")])
            .cappedSlots, ["second"])
        lists = ["a": Selection(apps: tokens("a", 25)), "b": Selection(apps: tokens("b", 25))]
        XCTAssertTrue(plan(["first": running(.blockSelection, list: "a"), "second": running(.blockSelection, list: "b")])
            .cappedSlots.isEmpty, "fifty fits")
    }

    func test_the_exceptions_cap_counts_each_store_that_carries_them() {
        lists = ["allowed": Selection(apps: tokens("x", 30)), "a": Selection(categories: ["c1"]), "b": Selection(categories: ["c2"]),
                 "c": Selection(apps: ["plain"])]
        let result = plan(["first": running(.blockSelection, list: "a", except: "allowed"),
                           "second": running(.blockSelection, list: "b", except: "allowed"),
                           "third": running(.blockSelection, list: "c", except: "allowed")])
        XCTAssertEqual(result.cappedSlots, ["second"], "a list without categories needs no exceptions")
        XCTAssertNotNil(result.stores["list3"])
    }

    func test_the_web_cap_under_all_apps_drops_the_later_lists_websites_only() {
        lists = ["a": Selection(apps: ["x"], web: tokens("w", 30)), "b": Selection(apps: ["y"], web: tokens("v", 30))]
        let result = plan(["all": running(), "first": running(.blockSelection, list: "a"), "second": running(.blockSelection, list: "b")])
        XCTAssertEqual(result.stores[ShieldStoreName.web]?.webDomains.count, 30)
        XCTAssertEqual(result.cappedSlots, ["second"])
        XCTAssertEqual(result.storesBySlot["second"], [ShieldStoreName.all], "its apps stay under the all-apps store")
    }

    func test_a_slot_not_due_asks_for_nothing() {
        let later = onceSpec(now + 600, now + 3600)
        let result = plan(["later": later])
        XCTAssertTrue(result.stores.isEmpty)
        XCTAssertTrue(result.dueSlots.isEmpty)
    }
}
