import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@preconcurrency import SwiftGodotRuntime

#if os(iOS)

/// Bridges UIKit's deep link callbacks into `DeepLinkQueue`.
///
/// Godot 4.7's iOS entry point is a SwiftUI app (`drivers/apple_embedded/app.swift`:
/// `@main struct SwiftUIApp` with `@UIApplicationDelegateAdaptor` and a `WindowGroup`), and the
/// export template's `Info.plist` carries a `UIApplicationSceneManifest`. The process therefore
/// runs on the UIScene lifecycle, where **none** of the `UIApplicationDelegate` deep link
/// callbacks are ever invoked — everything is delivered to the scene delegate instead.
///
/// Godot backs both the application delegate and the scene delegate with the same class
/// (`application:configurationForConnectingSceneSession:options:` sets
/// `config.delegateClass` to itself) and fans every callback out over a *class-level* `services`
/// array. Registering once here therefore covers both callback families, with no swizzling.
final class DeepLinkService: NSObject, UIApplicationDelegate, UIWindowSceneDelegate, @unchecked Sendable {

    static let shared = DeepLinkService()

    /// Godot renamed the delegate class after 4.7, so resolve it by name at runtime rather than
    /// linking against it — it lives in the host binary, not in this framework.
    private static let delegateClassNames = [
        "GDTApplicationDelegate", // Godot 4.7
        "GDTAppDelegateIOS",      // Godot master
        "GDTAppDelegate",
    ]

    /// Called from `pluginSetupHook` at `.core` init level.
    ///
    /// That runs inside `application:didFinishLaunchingWithOptions:` (which is what calls
    /// `apple_embedded_main()` -> `Main::setup()` -> GDExtension load), so we are registered
    /// before the scene connects and in time for every cold-launch payload. It is, however, too
    /// late to ever read `launchOptions` — nothing here may depend on them.
    static func register() {
        guard let delegateClass = resolveDelegateClass() else {
            fail("no app delegate class found (tried \(delegateClassNames.joined(separator: ", ")))")
            return
        }

        let addService = NSSelectorFromString("addService:")
        guard let method = class_getClassMethod(delegateClass, addService) else {
            fail("\(NSStringFromClass(delegateClass)) has no +addService:")
            return
        }

        typealias AddServiceFunction = @convention(c) (AnyClass, Selector, AnyObject) -> Void
        let addServiceFunction = unsafeBitCast(
            method_getImplementation(method),
            to: AddServiceFunction.self
        )
        addServiceFunction(delegateClass, addService, shared)

        // Read the registry back. If our object is not in it the fan-out will never reach us, and
        // that is the difference between "we were never called" and "we were called with nothing".
        let services = readServices(from: delegateClass)
        let registered = services?.contains(where: { ($0 as AnyObject) === shared }) ?? false
        guard registered else {
            fail("+addService: accepted but the service is not in \(NSStringFromClass(delegateClass)).services "
                 + "(count \(services?.count ?? -1))")
            return
        }

        installWarmQuickActionShim(on: delegateClass)
    }

    /// Registration can only fail if the host engine changed shape underneath us, and the symptom
    /// is every quick action and deep link vanishing without a trace. Worth a line in the log.
    private static func fail(_ reason: String) {
        NSLog("DeepLinkService FAILED: %@ — quick actions and deep links will not reach GDScript.", reason)
    }

    private static func resolveDelegateClass() -> AnyClass? {
        for name in delegateClassNames {
            if let cls = NSClassFromString(name) {
                return cls
            }
        }
        return nil
    }

    /// Reads `+[<delegateClass> services]`, Godot's class-level service registry.
    private static func readServices(from delegateClass: AnyClass) -> [AnyObject]? {
        let selector = NSSelectorFromString("services")
        guard let method = class_getClassMethod(delegateClass, selector) else { return nil }

        typealias ServicesFunction = @convention(c) (AnyClass, Selector) -> NSArray?
        let servicesFunction = unsafeBitCast(
            method_getImplementation(method),
            to: ServicesFunction.self
        )
        guard let array = servicesFunction(delegateClass, selector) else { return nil }
        return array as? [AnyObject]
    }

    /// Godot's delegate does not fan out `windowScene:performActionForShortcutItem:completionHandler:`,
    /// so warm-launch quick actions currently reach no service at all. Add it ourselves.
    ///
    /// This is purely additive — never a swizzle — so there is no original implementation to
    /// chain to and no way to recurse. If the method ever appears upstream the guard below makes
    /// this inert and `windowScene(_:performActionFor:completionHandler:)` below takes over.
    @discardableResult
    private static func installWarmQuickActionShim(on delegateClass: AnyClass) -> Bool {
        let selector = NSSelectorFromString("windowScene:performActionForShortcutItem:completionHandler:")
        guard class_getInstanceMethod(delegateClass, selector) == nil else { return false }

        typealias PerformActionBlock = @convention(block) (
            AnyObject, UIWindowScene, UIApplicationShortcutItem, @escaping (Bool) -> Void
        ) -> Void

        let block: PerformActionBlock = { _, _, shortcutItem, completionHandler in
            DeepLinkQueue.shared.enqueue(.quickAction, shortcutItem.type)
            completionHandler(true)
        }

        // v = void return, @ = self, : = _cmd, @ = scene, @ = shortcut item, @? = block
        return class_addMethod(delegateClass, selector, imp_implementationWithBlock(block), "v@:@@@?")
    }

    // MARK: - Scene lifecycle (the paths UIKit actually uses)

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Every cold launch arrives here, whatever the payload was.
        if let shortcutItem = connectionOptions.shortcutItem {
            DeepLinkQueue.shared.enqueue(.quickAction, shortcutItem.type)
        }
        for context in connectionOptions.urlContexts {
            ingest(url: context.url)
        }
        for activity in connectionOptions.userActivities {
            ingest(userActivity: activity)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            ingest(url: context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        ingest(userActivity: userActivity)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        DeepLinkQueue.shared.enqueue(.quickAction, shortcutItem.type)
        completionHandler(true)
    }

    // MARK: - Application lifecycle
    //
    // Dead paths under the scene lifecycle, kept because Godot already fans them out for free and
    // they cost nothing: they cover a future non-scene host. `DeepLinkQueue` de-duplicates, so a
    // payload arriving on both a scene and an application callback is delivered once.

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        DeepLinkQueue.shared.enqueue(.quickAction, shortcutItem.type)
        completionHandler(true)
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        return ingest(userActivity: userActivity)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        return ingest(url: url)
    }

    // MARK: - Ingestion

    @discardableResult
    private func ingest(url: URL) -> Bool {
        DeepLinkQueue.shared.enqueue(.customURL, url.absoluteString)
        // Forward it, but never claim it. Godot ORs every service's result together, and other
        // services own their own schemes (Google Sign-In's reversed client ID, for one). GDScript
        // ignores routes it does not recognise.
        return false
    }

    @discardableResult
    private func ingest(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL
        else { return false }

        DeepLinkQueue.shared.enqueue(.universalLink, url.absoluteString)
        // Claim this one: returning false makes iOS bounce the link straight back out to Safari.
        return true
    }
}

#elseif os(macOS)

/// macOS has no equivalent of `GDTApplicationDelegate.addService:` — `GodotApplicationDelegate`
/// in `platform/macos` is a plain `NSApplicationDelegate` with no service registry — so the
/// delegate still has to be patched at runtime here.
///
/// Unlike the previous implementation, this captures the original implementation *before*
/// replacing it. `method_setImplementation` mutates the very `Method` a later
/// `method_getImplementation` would read, so reading it from inside the replacement block hands
/// back the replacement and recurses until the stack runs out.
final class DeepLinkService: NSObject, @unchecked Sendable {

    static let shared = DeepLinkService()

    /// ObjC encodes `BOOL` as `signed char` on x86_64 but as C `bool` on arm64.
    #if arch(x86_64)
    private static let boolEncoding = "c"
    #else
    private static let boolEncoding = "B"
    #endif

    static func register() {
        guard let delegateClass = NSClassFromString("GodotApplicationDelegate") else {
            NSLog("DeepLinkService FAILED: could not resolve GodotApplicationDelegate — deep links are disabled.")
            return
        }

        installUniversalLinkHook(on: delegateClass)
        installCustomURLHook(on: delegateClass)
    }

    /// Installs a new implementation for `selector` on `cls`, handing the block builder whatever
    /// implementation was in effect beforehand so it can chain to it.
    private static func replaceMethod(
        _ selector: Selector,
        on cls: AnyClass,
        fallbackTypes: String,
        makeBlock: (IMP?) -> Any
    ) {
        // Resolved up front — see the note on the type above.
        let existing: IMP? = class_respondsToSelector(cls, selector)
            ? class_getMethodImplementation(cls, selector)
            : nil

        let declaredOnClass = class_getInstanceMethod(cls, selector)
        let types = declaredOnClass
            .flatMap { method_getTypeEncoding($0) }
            .map { String(cString: $0) } ?? fallbackTypes

        let imp = imp_implementationWithBlock(makeBlock(existing))

        // Succeeds unless `cls` itself declares the selector. When only a superclass declares it
        // this adds a proper override rather than repointing the superclass's method for every
        // other subclass in the process.
        if !class_addMethod(cls, selector, imp, types) {
            if let method = class_getInstanceMethod(cls, selector) {
                method_setImplementation(method, imp)
            }
        }
    }

    private static func installUniversalLinkHook(on cls: AnyClass) {
        let selector = #selector(NSApplicationDelegate.application(_:continue:restorationHandler:))

        typealias ContinueBlock = @convention(block) (
            AnyObject, NSApplication, NSUserActivity, @escaping ([any NSUserActivityRestoring]) -> Void
        ) -> Bool
        typealias ContinueFunction = @convention(c) (
            AnyObject, Selector, NSApplication, NSUserActivity,
            @escaping ([any NSUserActivityRestoring]) -> Void
        ) -> Bool

        replaceMethod(selector, on: cls, fallbackTypes: "\(boolEncoding)@:@@@?") { original in
            let block: ContinueBlock = { receiver, app, userActivity, restorationHandler in
                var handled = false
                if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
                   let url = userActivity.webpageURL {
                    DeepLinkQueue.shared.enqueue(.universalLink, url.absoluteString)
                    handled = true
                }

                if let original {
                    let callable = unsafeBitCast(original, to: ContinueFunction.self)
                    let originalResult = callable(receiver, selector, app, userActivity, restorationHandler)
                    return handled || originalResult
                }
                return handled
            }
            return block
        }
    }

    private static func installCustomURLHook(on cls: AnyClass) {
        let selector = #selector(NSApplicationDelegate.application(_:open:))

        typealias OpenBlock = @convention(block) (AnyObject, NSApplication, [URL]) -> Void
        typealias OpenFunction = @convention(c) (AnyObject, Selector, NSApplication, [URL]) -> Void

        replaceMethod(selector, on: cls, fallbackTypes: "v@:@@") { original in
            let block: OpenBlock = { receiver, app, urls in
                for url in urls {
                    DeepLinkQueue.shared.enqueue(.customURL, url.absoluteString)
                }
                if let original {
                    let callable = unsafeBitCast(original, to: OpenFunction.self)
                    callable(receiver, selector, app, urls)
                }
            }
            return block
        }
    }
}

#endif
