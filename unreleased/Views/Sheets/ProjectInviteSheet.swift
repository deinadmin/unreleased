import SwiftUI

struct ProjectInviteSheet: View {
    let ownerUID: String
    let projectID: UUID
    var onAccepted: () async -> Void
    var onDeclined: () -> Void

    @Environment(ProjectStore.self) private var store

    @State private var preview: ProjectPreview? = nil
    @State private var loadState: LoadState = .loading
    @State private var isAccepting = false
    /// False when the general link is disabled and the user wasn't directly invited.
    @State private var canJoin = true

    private enum LoadState { case loading, loaded, failed }

    var body: some View {
        VStack(spacing: 0) {
            switch loadState {
            case .loading:
                loadingView
            case .failed:
                failedView
            case .loaded:
                if let preview {
                    loadedView(preview: preview)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
        .presentationDragIndicator(.hidden)
        .task { await loadPreview() }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading invite…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Invite not found")
                .font(.headline)
            Text("This project may have been deleted or is no longer shared.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Dismiss", action: onDeclined)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func loadedView(preview: ProjectPreview) -> some View {
        VStack(spacing: 0) {
            coverRow(preview)
                .padding(.top, 32)
                .padding(.bottom, 24)

            inviteInfo(preview: preview)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)

            if canJoin {
                actionButtons
                    .padding(.horizontal, 20)
            } else {
                linkDisabledView
                    .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)
        }
    }

    private var linkDisabledView: some View {
        VStack(spacing: 12) {
            Text("This invite link is no longer active.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Dismiss", action: onDeclined)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Loaded subviews

    private func coverRow(_ preview: ProjectPreview) -> some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(preview.gradient.gradient)
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            VStack(spacing: 4) {
                Text(preview.projectName)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("by @\(preview.ownerUsername)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inviteInfo(preview: ProjectPreview) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Project invite")
                    .font(.system(size: 15, weight: .semibold))
                Text("Accept to add this project to your library and follow all future changes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Decline", action: onDeclined)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.primary)

            Button {
                Task { await accept() }
            } label: {
                ZStack {
                    if isAccepting {
                        ProgressView()
                            .tint(Color(UIColor.systemBackground))
                    } else {
                        Text("Accept")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Color(UIColor.systemBackground))
            }
            .disabled(isAccepting)
        }
    }

    // MARK: - Actions

    private func loadPreview() async {
        let result = await ProjectInviteService.fetchPreview(ownerUID: ownerUID, projectID: projectID)
        guard let result else {
            withAnimation { loadState = .failed }
            return
        }
        preview = result

        // Directly-invited users can always join, even if the general link is off.
        if result.linkEnabled {
            canJoin = true
        } else if let myUID = store.currentUserID {
            canJoin = await ProjectInviteService.hasPendingInvite(
                ownerUID: ownerUID, projectID: projectID, inviteeUID: myUID
            )
        } else {
            canJoin = false
        }

        withAnimation { loadState = .loaded }
    }

    private func accept() async {
        guard let username = store.currentUsername else { return }
        isAccepting = true
        do {
            try await ProjectInviteService.acceptInvite(
                ownerUID: ownerUID,
                projectID: projectID,
                recipientUID: store.currentUserID ?? "",
                recipientUsername: username
            )
        } catch {
            print("ProjectInviteSheet: accept failed — \(error)")
            isAccepting = false
            return
        }
        await onAccepted()
        isAccepting = false
    }
}
