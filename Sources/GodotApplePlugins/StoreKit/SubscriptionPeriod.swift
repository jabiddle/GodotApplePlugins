//
//  SubscriptionPeriod.swift
//  GodotApplePlugins
//
//  Created by Miguel de Icaza on 12/14/25.
//


@preconcurrency import SwiftGodotRuntime
import StoreKit
import SwiftUI

class StoreProductSubscriptionPeriod: RefCounted, @unchecked Sendable {
    var period: Product.SubscriptionPeriod?
    convenience init(_ period: Product.SubscriptionPeriod) {
        self.init()
        self.period = period
    }

    enum Unit: Int, CaseIterable {
        case day
        case month
        case week
        case year
    }
    @Export var value: Int { period?.value ?? 0 }
    @Export var unit: Unit {
        switch period?.unit {
        case .day: return .day
        case .month: return .month
        case .week: return .week
        case .year: return .year
            // should not happen, but to make the compiler happy
        default: return .day
        }
    }
    @Export var unitLocalized: String { period?.unit.localizedDescription ?? "" }

    @Callable static func get_every_six_months() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.everySixMonths)
    }
    @Callable static func get_every_three_days() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.everyThreeDays)
    }
    @Callable static func get_every_three_months() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.everyThreeMonths)
    }
    @Callable static func get_every_two_months() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.everyTwoMonths)
    }
    @Callable static func get_every_two_weeks() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.everyTwoWeeks)
    }
    @Callable static func get_monthly() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.monthly)
    }
    @Callable static func get_weekly() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.weekly)
    }
    @Callable static func get_yearly() -> StoreProductSubscriptionPeriod {
        StoreProductSubscriptionPeriod(Product.SubscriptionPeriod.yearly)
    }
}
