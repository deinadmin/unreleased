import Foundation

// MARK: - Invite preview

/// Small publicly-readable snapshot of a project used for invite prompt UI.
/// Stored at `users/{ownerID}/projectPreviews/{projectID}`.
struct ProjectPreview {
    let projectID: UUID
    let ownerUID: String
    let ownerUsername: String
    let projectName: String
    let gradient: GradientTheme
    let accentColorHex: String?
    /// When false the general share link no longer accepts new joins.
    /// Existing listeners keep their access. Defaults to true for older docs.
    let linkEnabled: Bool
}

// MARK: - Invitee info

/// A user who has accepted a project invite.
/// Stored at `users/{ownerID}/projects/{projectID}/invitees/{inviteeUID}`.
struct InviteeInfo: Identifiable {
    let id: String   // invitee UID
    let username: String
    let acceptedAt: Date
}

// MARK: - Pending invite info

/// A user who was explicitly invited by username but hasn't accepted yet.
/// Stored at `users/{ownerID}/projects/{projectID}/pendingInvites/{inviteeUID}`.
struct PendingInviteInfo: Identifiable, Equatable {
    let id: String              // invitee UID
    let username: String
    let invitedAt: Date
    /// ID of the in-app notification written to the recipient, used to delete
    /// it when the invite is cancelled.
    let notificationID: String?
}

// MARK: - User search

/// A user surfaced by username search when inviting people directly.
struct UserSearchResult: Identifiable, Hashable {
    let id: String      // user UID
    let username: String
}

// MARK: - Notifications

/// An in-app notification stored at `users/{recipientUID}/notifications/{id}`.
struct AppNotification: Identifiable, Equatable {
    enum Kind: String {
        case projectInvite
        case unknown

        nonisolated init(raw: String) {
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    let id: String
    let kind: Kind
    /// UID of the user who triggered the notification (the project owner for invites).
    let fromUID: String
    let fromUsername: String
    let projectID: UUID
    let projectName: String
    let createdAt: Date
    var read: Bool
}
