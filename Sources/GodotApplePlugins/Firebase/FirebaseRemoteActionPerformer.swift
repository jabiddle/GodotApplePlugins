import Foundation
import FirebaseCore
import FirebaseAuth

/// Performs a remote notification's action as the signed-in Firebase user: one ID token, one
/// POST, and the outcome stored for the host to read at its next start.
///
/// ⚠️ An action can launch the app in the background with no script running, so nothing has
/// configured Firebase yet. The default app is configured here behind the same `FirebaseApp.app()`
/// guard `FirebaseCoreManager` uses — a second `configure()` is an uncatchable exception — and on
/// the main queue, where that manager runs too, so the two cannot race.
final class FirebaseRemoteActionPerformer: RemoteActionPerformer, @unchecked Sendable {

    static let shared = FirebaseRemoteActionPerformer()

    /// Inside the time the system gives a background launch, with the token's own refresh in it.
    private static let requestTimeout: TimeInterval = 15

    func perform(_ request: RemoteActionRequest, completion: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            if FirebaseApp.app() == nil {
                FirebaseApp.configure()
            }
            let store = RemoteActionStore.shared
            let signedIn = Auth.auth().currentUser
            // The host sends a failed tap again only under the uid its entry names, so the entry
            // carries the user's from before the endpoint, the token or the post can fail.
            let pending = store.recordPending(request, uid: signedIn?.uid ?? "")
            let finish: @Sendable (Int) -> Void = { status in
                store.settle(pending, httpStatus: status)
                completion()
            }
            guard let user = signedIn, let url = request.url(endpoint: store.endpoint) else {
                finish(0)
                return
            }
            user.getIDTokenForcingRefresh(false) { token, error in
                guard let token, error == nil else {
                    finish(0)
                    return
                }
                var post = URLRequest(url: url, timeoutInterval: FirebaseRemoteActionPerformer.requestTimeout)
                post.httpMethod = "POST"
                post.setValue("application/json", forHTTPHeaderField: "Content-Type")
                post.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                post.httpBody = Data(request.bodyJSON.utf8)
                URLSession.shared.dataTask(with: post) { _, response, _ in
                    finish((response as? HTTPURLResponse)?.statusCode ?? 0)
                }.resume()
            }
        }
    }
}
