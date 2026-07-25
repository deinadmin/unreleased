import FirebaseAuth
import FirebaseFirestore
import Foundation
import UIKit
import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

/// Posted (with `ownerID`/`projectID` in `userInfo`) when the user taps a
/// project-invite push notification, so `ContentView` can route to the invite.
extension Notification.Name {
    static let projectInviteTapped = Notification.Name("projectInviteTapped")
}

enum PushUserInfoKey {
    static let ownerID = "ownerID"
    static let projectID = "projectID"
}

/// Owns push-notification registration, permission prompts, and FCM token storage.
///
/// FCM integration is compiled in only when the `FirebaseMessaging` package is
/// added to the target. Without it the app still requests authorization and
/// registers for APNs, but tokens won't be uploaded (so the Cloud Function has
/// nothing to send to until the dependency is added).
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private let tokenStateLock = NSLock()
    private var tokenUploadsEnabled = true

    /// A project invite tapped while the app wasn't ready to route it yet
    /// (e.g. cold launch, or before sign-in). `ContentView` drains this when it appears.
    private var pendingProjectLink: (ownerID: String, projectID: String)?

    /// Returns and clears any invite link captured from a notification tap.
    func consumePendingProjectLink() -> (ownerID: String, projectID: String)? {
        defer { pendingProjectLink = nil }
        return pendingProjectLink
    }

    /// Requests notification permission and registers for remote notifications.
    /// Safe to call multiple times (e.g. after sign-in).
    func registerForPushNotifications() {
        setTokenUploadsEnabled(true)
        #if canImport(FirebaseMessaging)
        Messaging.messaging().isAutoInitEnabled = true
        #endif

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error { print("PushNotificationManager: auth error — \(error)") }
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                #if canImport(FirebaseMessaging)
                Messaging.messaging().token { [weak self] token, error in
                    if let error {
                        print("PushNotificationManager: token refresh failed — \(error)")
                        return
                    }
                    guard let self, let token else { return }
                    self.uploadToken(token)
                }
                #endif
            }
        }
    }

    /// Detaches this installation from the current account before Firebase Auth
    /// signs out. The compare-and-delete transaction avoids clearing a token that
    /// a different device may have uploaded more recently.
    func detachFromCurrentUser() async {
        setTokenUploadsEnabled(false)

        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        pendingProjectLink = nil
        clearApplicationBadge()

        #if canImport(FirebaseMessaging)
        let messaging = Messaging.messaging()
        messaging.isAutoInitEnabled = false
        let token = messaging.fcmToken

        if let userID = Auth.auth().currentUser?.uid, let token {
            await removeToken(token, fromUserID: userID)
        }

        do {
            try await messaging.deleteToken()
        } catch {
            // If local invalidation fails, the server removes the stale token the
            // next time FCM reports it as invalid or unregistered.
            print("PushNotificationManager: token deletion failed — \(error)")
        }
        #endif

        await MainActor.run {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    /// Removes a badge left behind by an earlier push. The server uses a badge of
    /// one as a generic "there is an update" signal, so it must be cleared once
    /// the user opens the app rather than persisting across launches.
    func clearApplicationBadge() {
        Task {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(0)
            } catch {
                print("PushNotificationManager: couldn't clear badge — \(error)")
            }
        }
    }

    /// Persists the current push token to the signed-in user's private doc so the
    /// Cloud Function can look it up. No-op until a token and a signed-in user exist.
    func uploadToken(_ token: String) {
        guard areTokenUploadsEnabled else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = CloudPaths.userPrivateDocument(userID: uid, docID: "push")
        ref.setData([
            "fcmToken": token,
            "platform": "ios",
            "updatedAt": Timestamp(date: Date()),
        ], merge: true)
    }

    private var areTokenUploadsEnabled: Bool {
        tokenStateLock.withLock { tokenUploadsEnabled }
    }

    private func setTokenUploadsEnabled(_ enabled: Bool) {
        tokenStateLock.withLock {
            tokenUploadsEnabled = enabled
        }
    }

    private func removeToken(_ token: String, fromUserID userID: String) async {
        let ref = CloudPaths.userPrivateDocument(userID: userID, docID: "push")
        do {
            _ = try await Firestore.firestore().runTransaction { transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(ref)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }

                guard snapshot.get("fcmToken") as? String == token else {
                    return nil
                }

                transaction.updateData([
                    "fcmToken": FieldValue.delete(),
                    "platform": FieldValue.delete(),
                    "updatedAt": Timestamp(date: Date()),
                ], forDocument: ref)
                return nil
            }
        } catch {
            print("PushNotificationManager: server token removal failed — \(error)")
        }
    }

    struct Preferences {
        var enabled: Bool
        var projectInvites: Bool

        static let defaults = Preferences(enabled: true, projectInvites: true)
    }

    /// Loads the server-enforced notification preferences for the signed-in user.
    /// Missing values default to enabled so existing users keep their current behavior.
    func loadPreferences() async -> Preferences {
        guard let uid = Auth.auth().currentUser?.uid else { return .defaults }
        do {
            let snapshot = try await CloudPaths.userPrivateDocument(userID: uid, docID: "push").getDocument()
            return Preferences(
                enabled: snapshot.get("notificationsEnabled") as? Bool ?? true,
                projectInvites: snapshot.get("projectInvitesEnabled") as? Bool ?? true
            )
        } catch {
            print("PushNotificationManager: preference load failed — \(error)")
            return .defaults
        }
    }

    /// Persists preferences alongside the token read by the push Cloud Function.
    func savePreferences(_ preferences: Preferences) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try await CloudPaths.userPrivateDocument(userID: uid, docID: "push").setData([
                "notificationsEnabled": preferences.enabled,
                "projectInvitesEnabled": preferences.projectInvites,
                "updatedAt": Timestamp(date: Date()),
            ], merge: true)
        } catch {
            print("PushNotificationManager: preference save failed — \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Show the banner even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }

    /// Route a tapped invite to the deep-link handler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let ownerID = userInfo[PushUserInfoKey.ownerID] as? String,
           let projectID = userInfo[PushUserInfoKey.projectID] as? String {
            // Store for cold-launch / pre-sign-in drain.
            pendingProjectLink = (ownerID, projectID)
            // And notify any live observer (warm launch) so it routes immediately.
            NotificationCenter.default.post(
                name: .projectInviteTapped,
                object: nil,
                userInfo: [
                    PushUserInfoKey.ownerID: ownerID,
                    PushUserInfoKey.projectID: projectID,
                ]
            )
        }
        completionHandler()
    }
}

#if canImport(FirebaseMessaging)
// MARK: - MessagingDelegate (active when FirebaseMessaging is linked)

extension PushNotificationManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        uploadToken(fcmToken)
    }
}
#endif

/// App delegate used via `UIApplicationDelegateAdaptor` to receive APNs callbacks.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = PushNotificationManager.shared
        PushNotificationManager.shared.clearApplicationBadge()
        #if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = PushNotificationManager.shared
        #endif
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if canImport(FirebaseMessaging)
        // Hand the APNs token to FCM, which derives and reports an FCM token.
        Messaging.messaging().apnsToken = deviceToken
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("PushAppDelegate: remote registration failed — \(error)")
    }
}
