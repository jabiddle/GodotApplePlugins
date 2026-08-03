#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@preconcurrency import SwiftGodotRuntime

@Godot
class DeepLinkManager: RefCounted, @unchecked Sendable {
    
    @Signal var quickActionReceived: SignalWithArguments<String>
    @Signal var universalLinkReceived: SignalWithArguments<String>
    @Signal var customUrlReceived: SignalWithArguments<String>
    
    nonisolated(unsafe) static var shared: DeepLinkManager?
    
    // Store pending actions for cold launches before GDScript connects to the signals
    nonisolated(unsafe) static var pendingQuickAction: String?
    nonisolated(unsafe) static var pendingUniversalLink: String?
    nonisolated(unsafe) static var pendingCustomURL: String?
    
    required init(_ context: InitContext) {
        super.init(context)
        Self.shared = self
        Self.swizzleAppDelegate()
    }
    
    static func swizzleAppDelegate() {
        Task { @MainActor in
#if os(iOS)
            guard let delegate = UIApplication.shared.delegate else { return }
            let delegateClass: AnyClass = object_getClass(delegate)!
            
            swizzleQuickActions(delegateClass: delegateClass)
            swizzleUniversalLinks(delegateClass: delegateClass)
            swizzleCustomURLSchemes(delegateClass: delegateClass)
#elseif os(macOS)
            guard let delegate = NSApplication.shared.delegate else { return }
            let delegateClass: AnyClass = object_getClass(delegate)!
            
            swizzleUniversalLinks(delegateClass: delegateClass)
            swizzleCustomURLSchemes(delegateClass: delegateClass)
#endif
        }
    }
    
    // MARK: - Quick Actions
    
#if os(iOS)
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
    
    // MARK: - Custom URL Schemes
    
    private static func swizzleCustomURLSchemes(delegateClass: AnyClass) {
        let originalSelector = #selector(UIApplicationDelegate.application(_:open:options:))
        let originalMethod = class_getInstanceMethod(delegateClass, originalSelector)
        
        typealias OpenURLBlock = @convention(block) (AnyObject, UIApplication, URL, [UIApplication.OpenURLOptionsKey : Any]) -> Bool
        
        let block: OpenURLBlock = { (sself, app, url, options) in
            DeepLinkManager.handleCustomURL(url.absoluteString)
            
            if let origMethod = originalMethod {
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, UIApplication, URL, [UIApplication.OpenURLOptionsKey : Any]) -> Bool
                let imp = method_getImplementation(origMethod)
                let originalCallable = unsafeBitCast(imp, to: OriginalFunction.self)
                let originalResult = originalCallable(sself, originalSelector, app, url, options)
                return originalResult || true
            }
            
            return true
        }
        
        let newImp = imp_implementationWithBlock(block)
        
        if let origMethod = originalMethod {
            method_setImplementation(origMethod, newImp)
        } else {
            let types = "c@:@@@" // char (BOOL) return, self, cmd, app, url, options
            class_addMethod(delegateClass, originalSelector, newImp, types)
        }
    }
#endif
    
#if os(macOS)
    // MARK: - Universal Links (macOS)
    
    private static func swizzleUniversalLinks(delegateClass: AnyClass) {
        let originalSelector = #selector(NSApplicationDelegate.application(_:continue:restorationHandler:))
        let originalMethod = class_getInstanceMethod(delegateClass, originalSelector)
        
        typealias ContinueActivityBlock = @convention(block) (AnyObject, NSApplication, NSUserActivity, @escaping ([NSUserActivityRestoring]) -> Void) -> Bool
        
        let block: ContinueActivityBlock = { (sself, app, userActivity, restorationHandler) in
            var handled = false
            
            if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
                DeepLinkManager.handleUniversalLink(url.absoluteString)
                handled = true
            }
            
            if let origMethod = originalMethod {
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, NSApplication, NSUserActivity, @escaping ([NSUserActivityRestoring]) -> Void) -> Bool
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
    
    // MARK: - Custom URL Schemes (macOS)
    
    private static func swizzleCustomURLSchemes(delegateClass: AnyClass) {
        let originalSelector = #selector(NSApplicationDelegate.application(_:open:))
        let originalMethod = class_getInstanceMethod(delegateClass, originalSelector)
        
        typealias OpenURLBlock = @convention(block) (AnyObject, NSApplication, [URL]) -> Void
        
        let block: OpenURLBlock = { (sself, app, urls) in
            for url in urls {
                DeepLinkManager.handleCustomURL(url.absoluteString)
            }
            
            if let origMethod = originalMethod {
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, NSApplication, [URL]) -> Void
                let imp = method_getImplementation(origMethod)
                let originalCallable = unsafeBitCast(imp, to: OriginalFunction.self)
                originalCallable(sself, originalSelector, app, urls)
            }
        }
        
        let newImp = imp_implementationWithBlock(block)
        
        if let origMethod = originalMethod {
            method_setImplementation(origMethod, newImp)
        } else {
            let types = "v@:@@" // void return, self, cmd, app, urls
            class_addMethod(delegateClass, originalSelector, newImp, types)
        }
    }
#endif
    
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
    
    @Callable
    func check_pending_custom_url() -> String {
        let link = Self.pendingCustomURL ?? ""
        Self.pendingCustomURL = nil
        return link
    }
    
    @Callable
    func set_quick_actions(jsonArray: String) {
#if os(iOS)
        guard let data = jsonArray.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        
        let shortcutItems: [UIApplicationShortcutItem] = items.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let title = dict["title"] as? String, !title.isEmpty
            else { return nil }
            
            let subtitle = dict["subtitle"] as? String
            let iconKey = dict["icon"] as? String ?? ""
            let sfIcon = dict["sf_icon"] as? String ?? ""
            let icon = Self.resolveShortcutIcon(iconKey: iconKey, sfIcon: sfIcon)
            
            return UIApplicationShortcutItem(
                type: id,
                localizedTitle: title,
                localizedSubtitle: subtitle?.isEmpty == false ? subtitle : nil,
                icon: icon,
                userInfo: nil
            )
        }
        
        // UIApplication must be accessed on the main thread.
        DispatchQueue.main.async {
            UIApplication.shared.shortcutItems = shortcutItems
        }
#endif
    }
    
#if os(iOS)
    /// Maps a platform-agnostic icon key string from GDScript to a native
    /// `UIApplicationShortcutIcon`. Prioritizes a custom bundled asset if available,
    /// and falls back to an Apple SF Symbol (`sfIcon`) if the custom asset is missing.
    private static func resolveShortcutIcon(iconKey: String, sfIcon: String) -> UIApplicationShortcutIcon? {
        // Check if the custom asset actually exists in the iOS app bundle
        if !iconKey.isEmpty, UIImage(named: iconKey) != nil {
            return UIApplicationShortcutIcon(templateImageName: iconKey)
        }
        
        // Fall back to Apple SF Symbol
        if !sfIcon.isEmpty {
            if #available(iOS 13.0, *) {
                return UIApplicationShortcutIcon(systemImageName: sfIcon)
            }
        }
        
        return nil
    }
#endif
    
    static func handleQuickAction(_ type: String) {
        if let shared = shared {
            shared.quickActionReceived.emit(type)
        } else {
            pendingQuickAction = type
        }
    }
    
    static func handleUniversalLink(_ url: String) {
        if let shared = shared {
            shared.universalLinkReceived.emit(url)
        } else {
            pendingUniversalLink = url
        }
    }
    
    static func handleCustomURL(_ url: String) {
        if let shared = shared {
            shared.customUrlReceived.emit(url)
        } else {
            pendingCustomURL = url
        }
    }
}
