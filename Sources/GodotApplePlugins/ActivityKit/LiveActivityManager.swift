import Foundation
#if os(iOS)
import ActivityKit
#endif
@preconcurrency import SwiftGodotRuntime

@Godot
class LiveActivityManager: RefCounted, @unchecked Sendable {
    
    required init(_ context: InitContext) {
        super.init(context)
    }

    @Callable
    func start_activity(attributesJson: String, stateJson: String, staleDateEpoch: Double) -> Variant? {
#if os(iOS)
        if #available(iOS 16.1, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                return Variant("Live Activities are not enabled.")
            }
            
            let attributes = GenericLiveActivityAttributes(attributesJson: attributesJson)
            let contentState = GenericLiveActivityAttributes.ContentState(stateJson: stateJson)
            
            do {
                if #available(iOS 16.2, *) {
                    let staleDate = staleDateEpoch > 0 ? Date(timeIntervalSince1970: staleDateEpoch) : nil
                    let content = ActivityContent(state: contentState, staleDate: staleDate)
                    _ = try Activity<GenericLiveActivityAttributes>.request(
                        attributes: attributes,
                        content: content,
                        pushType: nil
                    )
                } else {
                    _ = try Activity<GenericLiveActivityAttributes>.request(
                        attributes: attributes,
                        contentState: contentState,
                        pushType: nil
                    )
                }
                return nil
            } catch {
                return Variant(error.localizedDescription)
            }
        }
#endif
        return Variant("ActivityKit not available.")
    }

    @Callable
    func update_activity(stateJson: String, staleDateEpoch: Double) {
#if os(iOS)
        if #available(iOS 16.1, *) {
            Task {
                for activity in Activity<GenericLiveActivityAttributes>.activities {
                    let newState = GenericLiveActivityAttributes.ContentState(stateJson: stateJson)
                    
                    if #available(iOS 16.2, *) {
                        let staleDate = staleDateEpoch > 0 ? Date(timeIntervalSince1970: staleDateEpoch) : nil
                        let content = ActivityContent(state: newState, staleDate: staleDate)
                        await activity.update(content)
                    } else {
                        await activity.update(using: newState)
                    }
                }
            }
        }
#endif
    }

    @Callable
    func end_activity(stateJson: String, staleDateEpoch: Double) {
#if os(iOS)
        if #available(iOS 16.1, *) {
            Task {
                for activity in Activity<GenericLiveActivityAttributes>.activities {
                    let newState = GenericLiveActivityAttributes.ContentState(stateJson: stateJson)
                    
                    if #available(iOS 16.2, *) {
                        let staleDate = staleDateEpoch > 0 ? Date(timeIntervalSince1970: staleDateEpoch) : nil
                        let content = ActivityContent(state: newState, staleDate: staleDate)
                        await activity.end(content, dismissalPolicy: .immediate)
                    } else {
                        await activity.end(using: newState, dismissalPolicy: .immediate)
                    }
                }
            }
        }
#endif
    }
}
