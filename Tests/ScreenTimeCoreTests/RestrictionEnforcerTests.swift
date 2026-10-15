import XCTest
@testable import ScreenTimeCore

/// The enforcer over fake stores and windows: what it writes, what it refuses, the events it
/// appends, and the access verdict.
final class RestrictionEnforcerTests: XCTestCase {
    let now = at(2026, 10, 12, 10, 0)

    func harness(approved: Bool = true) -> Harness {
        let harness = Harness(now: now)
        if approved {
            harness.approve()
        }
        return harness
    }

    func kinds(_ events: [RestrictionEvent]) -> [String] {
        events.map { $0.kind + ($0.reason.isEmpty ? "" : ":" + $0.reason) + "@" + $0.slotId }
    }

    func test_the_verdict_weighs_the_platform_against_the_record_and_the_marker() {
        XCTAssertEqual(AccessVerdict.status(apple: .approved, recorded: true, markerHolds: true), "approved")
        XCTAssertEqual(AccessVerdict.status(apple: .approved, recorded: false, markerHolds: true), "approved")
        XCTAssertEqual(AccessVerdict.status(apple: .approved, recorded: true, markerHolds: false), "denied",
                       "a running app still reads approved after a revocation")
        XCTAssertEqual(AccessVerdict.status(apple: .notDetermined, recorded: true, markerHolds: false), "denied",
                       "after a relaunch a revoked device reads never asked")
        XCTAssertEqual(AccessVerdict.status(apple: .denied, recorded: false, markerHolds: false), "denied")
        XCTAssertEqual(AccessVerdict.status(apple: .notDetermined, recorded: false, markerHolds: false), "not_determined")
        XCTAssertEqual(AccessVerdict.status(apple: .approved, recorded: false, markerHolds: false), "not_determined",
                       "a phone restored from a backup starts at set up")
        XCTAssertEqual(AccessVerdict.status(apple: .notDetermined, recorded: true, markerHolds: true), "")
    }

    func test_the_state_answers_the_record_and_no_requirements() {
        let fresh = harness(approved: false)
        let state = WireJSON.object(fresh.enforcer.authorizationState(apple: .notDetermined))!
        XCTAssertEqual(state["status"] as? String, "not_determined")
        XCTAssertEqual(state["was_approved"] as? Bool, false)
        XCTAssertEqual((state["requirements"] as? [Any])?.count, 0)
        fresh.approve()
        XCTAssertEqual(WireJSON.object(fresh.enforcer.authorizationState(apple: .approved))?["was_approved"] as? Bool, true)
    }

    func test_a_slot_set_applies_now_and_announces_its_start() {
        let h = harness()
        XCTAssertEqual(h.set("a", onceSpec(now - 60, now + 3600)), "")
        XCTAssertEqual(h.shields.stores[ShieldStoreName.all]?.categories, .all(except: []))
        XCTAssertEqual(kinds(h.drain()), ["restriction_started@a"])
        XCTAssertEqual(h.slot("a")["active"] as? Bool, true)
        XCTAssertEqual(h.slot("a")["due"] as? Bool, true)
        XCTAssertEqual(h.windows.running.values.map(\.kind), [PlannedWindow.release])
    }

    func test_a_slot_set_ahead_holds_nothing_until_its_start_window_wakes_the_enforcer() {
        let h = harness()
        XCTAssertEqual(h.set("a", onceSpec(now + 1800, now + 3600)), "")
        XCTAssertTrue(h.shields.stores.isEmpty)
        let opening = h.store.windows().first { $0.value.kind == PlannedWindow.start }!
        h.now = now + 1801
        h.enforcer.handleCallback(windowName: opening.key, isEnd: false)
        XCTAssertNotNil(h.shields.stores[ShieldStoreName.all])
        XCTAssertEqual(kinds(h.drain()), ["restriction_started@a"])
    }

    func test_reconcile_writes_nothing_when_nothing_drifted() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600))
        _ = h.drain()
        let writes = h.shields.writes.count
        let log = h.windows.log.count
        let answer = WireJSON.object(h.enforcer.reconcile(listed: h.windows.running))!
        XCTAssertEqual(h.shields.writes.count, writes)
        XCTAssertEqual(h.windows.log.count, log)
        XCTAssertEqual(answer["applied"] as? Int, 0)
        XCTAssertEqual(answer["lifted"] as? Int, 0)
        XCTAssertEqual(answer["rearmed"] as? Int, 0)
        XCTAssertEqual((answer["errors"] as? [Any])?.count, 0)
        XCTAssertTrue(h.drain().isEmpty)
    }

    func test_reconcile_writes_only_the_store_that_drifted_and_rearms_a_missing_window() {
        let h = harness()
        h.put("l", apps: ["x"])
        h.put("m", apps: ["y"])
        _ = h.set("first", dailySpec([1], 9 * 60, 11 * 60, mode: .blockSelection, list: "l"))
        _ = h.set("second", dailySpec([1], 9 * 60, 11 * 60, mode: .blockSelection, list: "m"))
        _ = h.drain()
        XCTAssertEqual(Set(h.shields.stores.keys), ["list1", "list2"])
        h.shields.stores["list1"] = nil
        XCTAssertEqual(h.windows.running.count, 1, "two slots at the same times share one wake window")
        h.windows.running = [:]
        let writes = h.shields.writes.count
        let answer = WireJSON.object(h.enforcer.reconcile(listed: h.windows.running))!
        XCTAssertEqual(h.shields.writes.count - writes, 1)
        XCTAssertEqual(h.shields.writes.last?.name, "list1")
        XCTAssertEqual(answer["applied"] as? Int, 1)
        XCTAssertEqual(answer["rearmed"] as? Int, 1)
        XCTAssertEqual(kinds(h.drain()), ["restriction_started@first"])
        XCTAssertEqual(h.windows.running.count, h.store.windows().count)
    }

    func test_reconcile_stops_a_listed_window_the_store_never_recorded_and_clears_a_stray_store() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600))
        h.windows.running["left.1"] = .daily(start: 60, end: 120)
        h.shields.stores["list5"] = Contents(apps: ["stray"])
        let answer = WireJSON.object(h.enforcer.reconcile(listed: h.windows.running))!
        XCTAssertNil(h.windows.running["left.1"])
        XCTAssertNil(h.shields.stores["list5"])
        XCTAssertEqual(answer["lifted"] as? Int, 1)
    }

    func test_a_store_that_reads_back_empty_is_reported_refused_once_and_the_save_still_succeeds() {
        let h = harness()
        h.shields.refusing = [ShieldStoreName.all]
        XCTAssertEqual(h.set("a", onceSpec(now - 60, now + 3600)), "")
        XCTAssertEqual(h.slot("a")["active"] as? Bool, false)
        XCTAssertEqual(kinds(h.drain()), ["restriction_degraded:refused@a"])
        h.enforcer.wake()
        XCTAssertTrue(h.drain().isEmpty, "a refusal is reported once, not at every wake")
    }

    func test_a_slot_past_a_cap_is_reported_degraded_once() {
        let h = harness()
        h.put("one", apps: tokens("a", 30))
        h.put("two", apps: tokens("b", 30))
        _ = h.set("first", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "one"))
        XCTAssertEqual(h.set("second", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "two")), "")
        XCTAssertEqual(kinds(h.drain()), ["restriction_started@first", "restriction_degraded:cap@second"])
        h.enforcer.wake()
        XCTAssertTrue(h.drain().isEmpty)
    }

    func test_setting_a_slot_again_keeps_its_suspension() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600))
        XCTAssertEqual(h.enforcer.suspendRestriction(slotId: "a", until: now + 1800), "")
        XCTAssertNil(h.shields.stores[ShieldStoreName.all])
        _ = h.set("a", onceSpec(now - 60, now + 4000, generation: 2))
        XCTAssertEqual(h.slot("a")["suspended_until"] as? Int, now + 1800)
        XCTAssertNil(h.shields.stores[ShieldStoreName.all])
        XCTAssertEqual(h.enforcer.resumeRestriction(slotId: "a"), "")
        XCTAssertNotNil(h.shields.stores[ShieldStoreName.all])
        XCTAssertEqual(h.enforcer.suspendRestriction(slotId: "missing", until: 1), "unknown_slot")
        XCTAssertEqual(h.enforcer.resumeRestriction(slotId: "missing"), "unknown_slot")
    }

    func test_clearing_a_slot_lifts_it_and_announces_the_end_with_its_generation() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600, generation: 7))
        _ = h.drain()
        XCTAssertEqual(h.enforcer.clearRestriction(slotId: "a"), "")
        XCTAssertTrue(h.shields.stores.isEmpty)
        XCTAssertEqual(h.drain(), [RestrictionEvent(kind: RestrictionEventKind.ended, slotId: "a", generation: 7, atUnix: now)])
        XCTAssertTrue(h.windows.running.isEmpty)
        XCTAssertEqual(h.enforcer.clearRestriction(slotId: "a"), "", "a slot not held is already cleared")
    }

    func test_a_spec_is_refused_malformed_first_then_unknown_or_too_large_then_without_access() {
        let h = harness(approved: false)
        XCTAssertEqual(h.enforcer.setRestriction(slotId: "a", json: "{}", apple: .approved), "invalid_spec")
        XCTAssertEqual(h.enforcer.setRestriction(slotId: "", json: specJSON(onceSpec(now, now + 60)), apple: .approved),
                       "invalid_spec")
        XCTAssertEqual(h.set("a", onceSpec(now, now + 60, mode: .blockSelection, list: "absent")), "unknown_selection")
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockAll, exceptSelectionId: "absent"), untilUnix: now)
        XCTAssertEqual(h.set("a", onceSpec(now, now + 60, retained: retained)), "unknown_selection")
        h.put("big", apps: tokens("a", 51))
        XCTAssertEqual(h.set("a", onceSpec(now, now + 60, mode: .blockSelection, list: "big")), "selection_too_large")
        XCTAssertEqual(h.set("a", onceSpec(now, now + 60, except: "big")), "selection_too_large")
        XCTAssertEqual(h.set("a", onceSpec(now, now + 60)), "not_authorized")
        h.approve()
        XCTAssertEqual(h.set("a", onceSpec(now, now + 60)), "")
    }

    func test_a_twenty_first_window_is_refused() {
        let h = harness()
        var code = ""
        var count = 0
        while code.isEmpty && count < 30 {
            count += 1
            code = h.set("s\(count)", onceSpec(now + count * 3600, now + count * 3600 + 1800))
        }
        XCTAssertEqual(code, "too_many_windows")
        XCTAssertEqual(count, 11, "each slot ahead takes a start and a release window")
        XCTAssertEqual(h.windows.running.count, 20)
        XCTAssertNil(h.slot("s11")["spec"], "the refused slot is not kept")
    }

    func test_a_callback_of_a_replaced_generation_does_nothing() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600))
        _ = h.drain()
        h.shields.stores = [:]
        let writes = h.shields.writes.count
        h.enforcer.handleCallback(windowName: "release.0", isEnd: true)
        XCTAssertEqual(h.shields.writes.count, writes)
        XCTAssertTrue(h.drain().isEmpty)
    }

    func test_the_new_generation_is_written_before_a_window_is_stopped() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600))
        var stillRecorded: [String] = []
        h.windows.onStop = { names in
            stillRecorded += names.filter { h.store.windows()[$0] != nil }
        }
        _ = h.set("a", onceSpec(now - 60, now + 5400, generation: 2))
        XCTAssertTrue(h.windows.log.contains { $0.hasPrefix("stop ") })
        XCTAssertTrue(stillRecorded.isEmpty, "a stop's end callback must find its name replaced")
    }

    func test_a_clock_or_zone_change_registers_every_window_that_does_not_repeat_again_under_a_new_name() {
        let h = harness()
        _ = h.set("ahead", onceSpec(now + 1800, now + 3600))
        _ = h.set("daily", dailySpec([1], 9 * 60, 10 * 60 + 45))
        let before = h.store.windows()
        h.enforcer.reregisterWindows()
        let after = h.store.windows()
        XCTAssertEqual(Set(after.values.filter(\.repeats).map(\.startMinute)), Set(before.values.filter(\.repeats).map(\.startMinute)))
        XCTAssertEqual(Set(after.keys.filter { before[$0]?.repeats == true }), Set(before.keys.filter { before[$0]!.repeats }),
                       "a daily window is a local time already and keeps its name")
        XCTAssertTrue(Set(after.keys.filter { !after[$0]!.repeats }).isDisjoint(with: before.keys))
        XCTAssertEqual(after.values.filter { !$0.repeats }.count, 2)
        XCTAssertEqual(h.windows.running.count, after.count)
    }

    func test_an_end_callback_a_second_early_evaluates_at_its_boundary_and_a_stale_one_at_the_clock() {
        let h = harness()
        let end = now + 3600
        _ = h.set("a", onceSpec(now - 60, end))
        _ = h.drain()
        let release = h.store.windows().first { $0.value.kind == PlannedWindow.release }!
        h.now = end - 1
        h.enforcer.handleCallback(windowName: release.key, isEnd: false)
        XCTAssertNil(h.shields.stores[ShieldStoreName.all], "the start of the release window lifts at its boundary")

        let other = harness()
        _ = other.set("a", onceSpec(now - 60, end))
        let stale = other.store.windows().first { $0.value.kind == PlannedWindow.release }!
        other.now = end - 300
        other.enforcer.handleCallback(windowName: stale.key, isEnd: false)
        XCTAssertNotNil(other.shields.stores[ShieldStoreName.all], "a callback far from its boundary never lifts early")
    }

    func test_without_the_marker_reconcile_and_rebuild_write_nothing_and_each_due_loss_is_reported_once() {
        let h = harness()
        _ = h.set("due", onceSpec(now - 60, now + 3600, generation: 4))
        _ = h.set("later", onceSpec(now + 1800, now + 3600))
        _ = h.drain()
        h.shields.marker = false
        let writes = h.shields.writes.count
        let answer = WireJSON.object(h.enforcer.reconcile(listed: nil))!
        XCTAssertEqual(answer["errors"] as? [String], ["not_authorized"])
        XCTAssertEqual(h.shields.writes.count, writes)
        XCTAssertEqual(h.drain(), [RestrictionEvent(kind: RestrictionEventKind.lost, slotId: "due", generation: 4, atUnix: 0,
                                                    reason: RestrictionReason.permission)])
        XCTAssertEqual(WireJSON.object(h.enforcer.rebuild())?["errors"] as? [String], ["not_authorized"])
        XCTAssertEqual(WireJSON.object(h.enforcer.authorizationState(apple: .approved))?["status"] as? String, "denied")
        XCTAssertTrue(h.drain().isEmpty, "the loss is reported at the first read that finds the marker gone, once")
        XCTAssertEqual(h.shields.writes.count, writes)
        h.enforcer.noteApproval()
        XCTAssertEqual(WireJSON.object(h.enforcer.authorizationState(apple: .approved))?["status"] as? String, "approved")
    }

    func test_rebuild_blocks_then_unblocks_every_name_raises_the_generation_and_applies_again() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 3600))
        _ = h.drain()
        h.shields.marker = true
        let generation = h.store.generation
        let writes = h.shields.writes.count
        let answer = WireJSON.object(h.enforcer.rebuild())!
        let rebuilt = Array(h.shields.writes[writes...])
        for name in ShieldStoreName.fixedSet {
            let order = rebuilt.enumerated().filter { $0.element.name == name }.map(\.element.contents)
            XCTAssertEqual(Array(order.prefix(2)), [Contents.everything, Contents()], name)
        }
        XCTAssertEqual(h.store.generation, generation + 1)
        XCTAssertTrue(h.windows.log.contains("stopAll"))
        XCTAssertNotNil(h.shields.stores[ShieldStoreName.all])
        XCTAssertEqual(answer["applied"] as? Int, 1)
        XCTAssertEqual(answer["lifted"] as? Int, 1)
        XCTAssertTrue(h.drain().isEmpty, "a block held before and after a rebuild is announced neither ended nor started")
        XCTAssertEqual(WireJSON.object(h.enforcer.restrictions())?["generation"] as? Int, generation + 1)
    }

    func test_a_store_at_another_version_is_never_written() {
        let h = harness()
        h.values.values[RestrictionStore.schemaKey] = Data("2".utf8)
        XCTAssertEqual(h.set("a", onceSpec(now - 60, now + 3600)), "schema_mismatch")
        XCTAssertEqual(h.enforcer.putSelection(Selection(apps: ["x"]), id: "l"), "schema_mismatch")
        XCTAssertEqual(WireJSON.object(h.enforcer.summary("l"))?["error"] as? String, "schema_mismatch")
        XCTAssertEqual(WireJSON.object(h.enforcer.restrictions())?["error"] as? String, "schema_mismatch")
        XCTAssertEqual(WireJSON.object(h.enforcer.reconcile(listed: nil))?["errors"] as? [String], ["schema_mismatch"])
        XCTAssertEqual(h.enforcer.setAppearance(id: "x", json: "{}", image: nil), "schema_mismatch")
        XCTAssertTrue(h.shields.writes.filter { $0.name != ShieldStoreName.marker }.isEmpty)
    }

    func test_the_queue_keeps_the_newest_two_hundred_and_a_drain_consumes_them() {
        let h = harness()
        for index in 0..<250 {
            h.enforcer.appendEvent(RestrictionEvent(kind: RestrictionEventKind.shieldButton, slotId: "s", generation: index,
                                                    atUnix: index, button: "secondary"))
        }
        let drained = h.drain()
        XCTAssertEqual(drained.count, 200)
        XCTAssertEqual(drained.first?.generation, 50)
        XCTAssertEqual(drained.last?.generation, 249)
        XCTAssertTrue(h.drain().isEmpty)
    }

    func test_lists_unite_intersect_copy_and_compare_without_names() {
        let h = harness()
        h.put("a", apps: ["x", "y"], categories: ["c"])
        h.put("b", apps: ["y", "z"], web: ["w"])
        XCTAssertEqual(h.enforcer.unionSelection(from: "a", into: "b"), "")
        XCTAssertEqual(h.enforcer.selection("b"), Selection(apps: ["x", "y", "z"], categories: ["c"], web: ["w"]))
        XCTAssertEqual(h.enforcer.unionSelection(from: "a", into: "new"), "", "uniting into an absent list creates it")
        XCTAssertEqual(h.enforcer.selection("new"), h.enforcer.selection("a"))
        XCTAssertEqual(h.enforcer.intersectSelection(from: "a", into: "b"), "")
        XCTAssertEqual(h.enforcer.selection("b"), Selection(apps: ["x", "y"], categories: ["c"]))
        XCTAssertEqual(h.enforcer.intersectSelection(from: "a", into: "absent"), "unknown_selection")
        XCTAssertEqual(h.enforcer.unionSelection(from: "absent", into: "b"), "unknown_selection")
        XCTAssertEqual(h.enforcer.copySelection(from: "absent", to: "c"), "unknown_selection")
        XCTAssertEqual(h.enforcer.copySelection(from: "a", to: "c"), "")
        h.put("d", apps: ["x", "q"], web: ["w1", "w2"])
        let diff = WireJSON.object(h.enforcer.diffSelections(base: "a", other: "d"))!
        XCTAssertEqual(diff["added"] as? [String: Int], ["apps": 1, "categories": 0, "web": 2])
        XCTAssertEqual(diff["removed"] as? [String: Int], ["apps": 1, "categories": 1, "web": 0])
        XCTAssertEqual(WireJSON.object(h.enforcer.diffSelections(base: "a", other: "absent"))?["error"] as? String,
                       "unknown_selection")
        let summary = WireJSON.object(h.enforcer.summary("d"))!
        XCTAssertEqual(summary["app_count"] as? Int, 2)
        XCTAssertEqual(summary["web_count"] as? Int, 2)
        XCTAssertEqual(summary["expired"] as? Bool, false)
        XCTAssertNil(summary["packages"])
        XCTAssertEqual(WireJSON.object(h.enforcer.summary("absent"))?["error"] as? String, "unknown_selection")
        XCTAssertEqual(h.enforcer.deleteSelection("a"), "")
        XCTAssertEqual(h.enforcer.deleteSelection("a"), "", "deleting a list not held succeeds")
        XCTAssertEqual(h.store.selectionIds(), ["b", "c", "d", "new"])
    }

    func test_a_list_changed_under_a_running_block_reaches_its_store_at_the_next_wake() {
        let h = harness()
        h.put("l", apps: ["x"])
        _ = h.set("a", onceSpec(now - 60, now + 3600, mode: .blockSelection, list: "l"))
        h.put("more", apps: ["y"])
        XCTAssertEqual(h.enforcer.unionSelection(from: "more", into: "l"), "")
        h.enforcer.wake()
        XCTAssertEqual(h.shields.stores["list1"]?.apps, ["x", "y"])
    }

    func test_the_restrictions_read_back_answers_every_field() {
        let h = harness()
        _ = h.set("a", onceSpec(now - 60, now + 600))
        _ = h.set("b", dailySpec([3], 600, 700))
        let all = h.restrictions()
        XCTAssertEqual(all["windows_in_use"] as? Int, h.windows.running.count)
        XCTAssertEqual(all["generation"] as? Int, 0)
        let a = h.slot("a")
        XCTAssertEqual(a["active"] as? Bool, true)
        XCTAssertEqual(a["padded"] as? Bool, true)
        XCTAssertEqual(a["suspended_until"] as? Int, 0)
        XCTAssertEqual((a["spec"] as? [String: Any])?["generation"] as? Int, 1)
        XCTAssertEqual(h.slot("b")["due"] as? Bool, false)
        XCTAssertEqual(h.slot("b")["active"] as? Bool, false)
        h.shields.stores = [:]
        XCTAssertEqual(h.slot("a")["active"] as? Bool, false, "active is what the stores read back")
    }

    func test_token_expiry_is_ignored_without_lists_and_marks_only_unrenewed_lists_expired() {
        let h = harness()
        var asked = 0
        h.shields.renewal = { selection in
            asked += 1
            return selection.apps.contains("stale") ? .failed : .renewed(selection)
        }
        h.enforcer.tokensDidExpire()
        XCTAssertEqual(asked, 0)
        h.put("good", apps: ["x"])
        h.put("bad", apps: ["stale"])
        h.enforcer.tokensDidExpire()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(WireJSON.object(h.enforcer.summary("bad"))?["expired"] as? Bool, true)
        XCTAssertEqual(WireJSON.object(h.enforcer.reconcile(listed: nil))?["expired_selections"] as? [String], ["bad"])
    }

    func test_an_appearance_needs_an_id_and_an_object_and_clears_with_its_image() {
        let h = harness()
        XCTAssertEqual(h.enforcer.setAppearance(id: "", json: "{}", image: nil), "invalid_spec")
        XCTAssertEqual(h.enforcer.setAppearance(id: "x", json: "[]", image: nil), "invalid_spec")
        XCTAssertEqual(h.enforcer.setAppearance(id: "x", json: #"{"title":"T"}"#, image: Data([1, 2])), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.store.imageURL(appearanceId: "x").path))
        XCTAssertEqual(h.store.appearances()["x"]?["title"] as? String, "T")
        XCTAssertEqual(h.enforcer.clearAppearance(id: "x"), "")
        XCTAssertNil(h.store.appearances()["x"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.store.imageURL(appearanceId: "x").path))
        XCTAssertEqual(h.enforcer.acceptServiceNotice(json: "{}"), "")
        XCTAssertEqual(h.enforcer.acceptServiceNotice(json: "nope"), "invalid_spec")
    }
}
