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
}

// MARK: - Invitee info

/// A user who has accepted a project invite.
/// Stored at `users/{ownerID}/projects/{projectID}/invitees/{inviteeUID}`.
struct InviteeInfo: Identifiable {
    let id: String   // invitee UID
    let username: String
    let acceptedAt: Date
}
