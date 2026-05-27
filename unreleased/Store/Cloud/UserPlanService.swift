import FirebaseFirestore
import Foundation

/// Listens to the `users/{userID}` Firestore document and delivers `UserPlan` updates.
///
/// The document is written manually from the Firebase console.
/// Fields read:
///   - `plan`           – String matching a `PlanTier` raw value (e.g. "premium")
///   - `planExpiresAt`  – Firestore Timestamp (optional); nil means the plan never expires
final class UserPlanService {
    private var listener: ListenerRegistration?

    func start(userID: String, onUpdate: @escaping @MainActor (UserPlan) -> Void) {
        stop()
        let ref = CloudPaths.userDocument(userID: userID)
        listener = ref.addSnapshotListener { [weak self] snapshot, error in
            guard self != nil else { return }
            if let error {
                print("UserPlanService: listener error — \(error)")
                return
            }
            let plan = Self.decode(snapshot: snapshot)
            Task { @MainActor in onUpdate(plan) }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Decoding

    private static func decode(snapshot: DocumentSnapshot?) -> UserPlan {
        guard let data = snapshot?.data(),
              let planString = data["plan"] as? String,
              let tier = PlanTier(rawValue: planString)
        else {
            return .default
        }

        let expiresAt: Date?
        if let ts = data["planExpiresAt"] as? Timestamp {
            expiresAt = ts.dateValue()
        } else {
            expiresAt = nil
        }

        return UserPlan(tier: tier, expiresAt: expiresAt)
    }
}
