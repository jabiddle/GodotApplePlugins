//
//  RevenueCatManager.swift
//  GodotApplePlugins
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import RevenueCat

class RevenueCatDelegate: NSObject, PurchasesDelegate {
    weak var manager: RevenueCatManager?
    
    init(manager: RevenueCatManager) {
        self.manager = manager
        super.init()
    }
    
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        guard let manager = manager else { return }
        let infoDict = manager.encodeCustomerInfo(info: customerInfo)
        DispatchQueue.main.async {
            manager.customer_info_updated.emit(infoDict)
        }
    }
}

@Godot
class RevenueCatManager: RefCounted, @unchecked Sendable {
    
    @Signal("info") var customer_info_updated: SignalWithArguments<VariantDictionary>
    @Signal("product_id", "error") var purchase_completed: SignalWithArguments<String, String>
    @Signal("info", "error") var restore_completed: SignalWithArguments<VariantDictionary, String>
    @Signal("products") var products_received: SignalWithArguments<VariantDictionary>
    @Signal("offerings", "error") var offerings_received: SignalWithArguments<VariantDictionary, String>
    
    private var rcDelegate: RevenueCatDelegate?
    
    @Callable
    func configure(apiKey: String, appUserId: String) {
        if appUserId.isEmpty {
            Purchases.configure(withAPIKey: apiKey)
        } else {
            Purchases.configure(withAPIKey: apiKey, appUserID: appUserId)
        }
        
        let delegate = RevenueCatDelegate(manager: self)
        self.rcDelegate = delegate
        Purchases.shared.delegate = delegate
    }
    
    @Callable
    func get_customer_info() {
        Purchases.shared.getCustomerInfo { [weak self] (customerInfo, error) in
            guard let self = self else { return }
            
            if let error = error {
                print("RevenueCat GetCustomerInfo Error: \(error.localizedDescription)")
                return
            }
            
            if let info = customerInfo {
                let infoDict = self.encodeCustomerInfo(info: info)
                DispatchQueue.main.async {
                    self.customer_info_updated.emit(infoDict)
                }
            }
        }
    }
    
    @Callable
    func get_products(productIds: VariantArray) {
        var ids: [String] = []
        for i in 0..<Int(productIds.count) {
            if let stringId = String(productIds[i]) {
                ids.append(stringId)
            }
        }
        
        Purchases.shared.getProducts(ids) { [weak self] products in
            guard let self = self else { return }
            
            let productsDict = VariantDictionary()
            for product in products {
                let pDict = VariantDictionary()
                pDict[Variant("product_id")] = Variant(product.productIdentifier)
                pDict[Variant("title")] = Variant(product.localizedTitle)
                pDict[Variant("description")] = Variant(product.localizedDescription)
                pDict[Variant("price")] = Variant(NSDecimalNumber(decimal: product.price).doubleValue)
                pDict[Variant("price_string")] = Variant(product.localizedPriceString)
                
                productsDict[Variant(product.productIdentifier)] = Variant(pDict)
            }
            
            DispatchQueue.main.async {
                self.products_received.emit(productsDict)
            }
        }
    }
    
    @Callable
    func get_offerings() {
        Purchases.shared.getOfferings { [weak self] (offerings, error) in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async { self.offerings_received.emit(VariantDictionary(), error.localizedDescription) }
                return
            }
            
            let offDict = VariantDictionary()
            if let current = offerings?.current {
                let currentDict = VariantDictionary()
                for package in current.availablePackages {
                    let pDict = VariantDictionary()
                    pDict[Variant("identifier")] = Variant(package.identifier)
                    pDict[Variant("product_id")] = Variant(package.storeProduct.productIdentifier)
                    pDict[Variant("title")] = Variant(package.storeProduct.localizedTitle)
                    pDict[Variant("description")] = Variant(package.storeProduct.localizedDescription)
                    pDict[Variant("price")] = Variant(NSDecimalNumber(decimal: package.storeProduct.price).doubleValue)
                    pDict[Variant("price_string")] = Variant(package.storeProduct.localizedPriceString)
                    
                    currentDict[Variant(package.identifier)] = Variant(pDict)
                }
                offDict[Variant("current")] = Variant(currentDict)
            }
            
            DispatchQueue.main.async { self.offerings_received.emit(offDict, "") }
        }
    }
    
    @Callable
    func purchase_product(productId: String) {
        Purchases.shared.getProducts([productId]) { [weak self] products in
            guard let self = self else { return }
            
            guard let product = products.first else {
                DispatchQueue.main.async { self?.purchase_completed.emit(productId, "Product not found") }
                return
            }
            
            Purchases.shared.purchase(product: product) { (transaction, customerInfo, error, userCancelled) in
                if userCancelled {
                    DispatchQueue.main.async { self?.purchase_completed.emit(productId, "User cancelled") }
                    return
                }
                
                if let error = error {
                    DispatchQueue.main.async { self?.purchase_completed.emit(productId, error.localizedDescription) }
                    return
                }
                
                if let info = customerInfo {
                    let infoDict = self?.encodeCustomerInfo(info: info) ?? VariantDictionary()
                    DispatchQueue.main.async {
                        self?.customer_info_updated.emit(infoDict)
                        self?.purchase_completed.emit(productId, "")
                    }
                }
            }
        }
    }
    
    @Callable
    func restore_purchases() {
        Purchases.shared.restorePurchases { [weak self] (customerInfo, error) in
            guard let self = self else { return }
            
            if let error = error {
                let emptyDict = VariantDictionary()
                DispatchQueue.main.async { self.restore_completed.emit(emptyDict, error.localizedDescription) }
                return
            }
            
            if let info = customerInfo {
                let infoDict = self.encodeCustomerInfo(info: info)
                DispatchQueue.main.async {
                    self.restore_completed.emit(infoDict, "")
                    self.customer_info_updated.emit(infoDict)
                }
            }
        }
    }
    
    @Callable
    func login(appUserId: String) {
        Purchases.shared.logIn(appUserId) { [weak self] (customerInfo, created, error) in
            guard let self = self else { return }
            if let info = customerInfo {
                let infoDict = self.encodeCustomerInfo(info: info)
                DispatchQueue.main.async { self.customer_info_updated.emit(infoDict) }
            }
        }
    }
    
    @Callable
    func log_out() {
        Purchases.shared.logOut { [weak self] (customerInfo, error) in
            guard let self = self else { return }
            if let info = customerInfo {
                let infoDict = self.encodeCustomerInfo(info: info)
                DispatchQueue.main.async { self.customer_info_updated.emit(infoDict) }
            }
        }
    }
    
    func encodeCustomerInfo(info: CustomerInfo) -> VariantDictionary {
        let dict = VariantDictionary()
        
        let activeEntitlements = VariantArray()
        for (key, _) in info.entitlements.active {
            activeEntitlements.append(Variant(key))
        }
        dict[Variant("active_entitlements")] = Variant(activeEntitlements)
        
        let activeSubscriptions = VariantArray()
        for sub in info.activeSubscriptions {
            activeSubscriptions.append(Variant(sub))
        }
        dict[Variant("active_subscriptions")] = Variant(activeSubscriptions)
        
        let allPurchasedProductIdentifiers = VariantArray()
        for pid in info.allPurchasedProductIdentifiers {
            allPurchasedProductIdentifiers.append(Variant(pid))
        }
        dict[Variant("all_purchased_product_identifiers")] = Variant(allPurchasedProductIdentifiers)
        
        dict[Variant("original_app_user_id")] = Variant(info.originalAppUserId)
        
        return dict
    }
}