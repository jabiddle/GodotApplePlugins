import UIKit
@preconcurrency import SwiftGodotRuntime

@Godot
class DeepLinkManager: RefCounted, @unchecked Sendable {
    
    #signal("quick_action_received", arguments: ["type": String.self])
    #signal("universal_link_received", arguments: ["url": String.self])
    
    static var shared: DeepLinkManager?
    
    // Store pending actions for cold launches before GDScript connects to the signals
    static var pendingQuickAction: String?
    static var pendingUniversalLink: String?
    
    required init(_ context: InitContext) {
        super.init(context)
        Self.shared = self
        Self.swizzleAppDelegate()
    }
    
    static func swizzleAppDelegate() {
        guard let delegate = UIApplication.shared.delegate else { return }
        let delegateClass: AnyClass = object_getClass(delegate)!
        
        swizzleQuickActions(delegateClass: delegateClass)
        swizzleUniversalLinks(delegateClass: delegateClass)
    }
    
    // MARK: - Quick Actions
    
    private static func swizzleQuickActions(delegateClass: AnyClass) {
        let originalSelector = #selector(UIApplicationDelegate.application(_:performActionFor:completionHandler:))
        let originalMethod = class_getInstanceMethod(delegateClass, originalSelector)
        
        typealias PerformActionBlock = @convention(block) (AnyObject, UIApplication, UIApplicationShortcutItem, @escaping (Bool) -> Void) -> Void
        
        let block: PerformActionBlock = { (sself, app, shortcutItem, completionHandler) in
            DeepLinkManager.handleQuickAction(shortcutItem.type)
            
            if let origMethod = originalMethod {
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, UIApplication, UIApplicationShortcutItem, @escaping (Bool) -> Void) -> Void
                let imp = method_getImplementation(origMethod)
                let originalCallable = unsafeBitCast(imp, to: OriginalFunction.self)
                originalCallable(sself, originalSelector, app, shortcutItem, completionHandler)
            } else {
                completionHandler(true)
            }
        }
        
        let newImp = imp_implementationWithBlock(block)
        
        if let origMethod = originalMethod {
            method_setImplementation(origMethod, newImp)
        } else {
            let types = "v@:@@@?" // void return, self, cmd, app, shortcut, block
            class_addMethod(delegateClass, originalSelector, newImp, types)
        }
    }
    
    // MARK: - Universal Links
    
    private static func swizzleUniversalLinks(delegateClass: AnyClass) {
        let originalSelector = #selector(UIApplicationDelegate.application(_:continue:restorationHandler:))
        let originalMethod = class_getInstanceMethod(delegateClass, originalSelector)
        
        typealias ContinueActivityBlock = @convention(block) (AnyObject, UIApplication, NSUserActivity, @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool
        
        let block: ContinueActivityBlock = { (sself, app, userActivity, restorationHandler) in
            var handled = false
            
            if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
                DeepLinkManager.handleUniversalLink(url.absoluteString)
                handled = true
            }
            
            if let origMethod = originalMethod {
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, UIApplication, NSUserActivity, @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool
                let imp = method_getImplementation(origMethod)
                let originalCallable = unsafeBitCast(imp, to: OriginalFunction.self)
                let originalResult = originalCallable(sself, originalSelector, app, userActivity, restorationHandler)
                return handled || originalResult
            }
            
            return handled
        }
        
        let newImp = imp_implementationWithBlock(block)
        
        if let origMethod = originalMethod {
            method_setImplementation(origMethod, newImp)
        } else {
            let types = "c@:@@@?" // char (BOOL) return, self, cmd, app, userActivity, block
            class_addMethod(delegateClass, originalSelector, newImp, types)
        }
    }
    
    // MARK: - GDScript API
    
    @Callable
    func check_pending_quick_action() -> String {
        let action = Self.pendingQuickAction ?? ""
        Self.pendingQuickAction = nil
        return action
    }
    
    @Callable
    func check_pending_universal_link() -> String {
        let link = Self.pendingUniversalLink ?? ""
        Self.pendingUniversalLink = nil
        return link
    }
    
    static func handleQuickAction(_ type: String) {
        if let shared = shared {
            shared.emit(signal: DeepLinkManager.quickActionReceived, type)
        } else {
            pendingQuickAction = type
        }
    }
    
    static func handleUniversalLink(_ url: String) {
        if let shared = shared {
            shared.emit(signal: DeepLinkManager.universalLinkReceived, url)
        } else {
            pendingUniversalLink = url
        }
    }
}
