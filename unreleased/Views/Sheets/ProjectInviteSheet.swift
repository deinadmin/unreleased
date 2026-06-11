import SwiftUI

struct ProjectInviteSheet: View {
    let ownerUID: String
    let projectID: UUID
    var onAccepted: () async -> Void
    var onDeclined: () -> Void

    @Environment(ProjectStore.self) private var store

    @State private var preview: ProjectPreview?
    @State private var loadState: LoadState
    @State private var isAccepting = false
    /// False when the general link is disabled and the user wasn't directly invited.
    @State private var canJoin = true

    private enum LoadState { case loading, loaded, failed }

    @State private var sheetHeight: CGFloat = 200
    @ScaledMetric private var buttonHeight: CGFloat = 56

    init(
        ownerUID: String,
        projectID: UUID,
        preview: ProjectPreview? = nil,
        onAccepted: @escaping () async -> Void,
        onDeclined: @escaping () -> Void
    ) {
        self.ownerUID = ownerUID
        self.projectID = projectID
        self.onAccepted = onAccepted
        self.onDeclined = onDeclined
        // When a preview is preloaded, open straight into the resolved layout so
        // the sheet renders fully before it animates in (no late fade / resize).
        _preview = State(initialValue: preview)
        _loadState = State(initialValue: preview == nil ? .loading : .loaded)
    }

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
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sheetHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        sheetHeight = newValue
                    }
            }
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationBackground(Color(.systemBackground))
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
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
        }
    }

    private var linkDisabledView: some View {
        VStack(spacing: 12) {
            Text("This invite link is no longer active.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onDeclined) {
                Text("Dismiss")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: buttonHeight)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(PressableButtonStyle())
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onDeclined) {
                Text("Cancel")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: buttonHeight)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                Task { await accept() }
            } label: {
                ZStack {
                    if isAccepting {
                        ProgressView()
                            .tint(Color(UIColor.systemBackground))
                    } else {
                        Text("Accept")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Color(UIColor.systemBackground))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isAccepting)
        }
    }

    // MARK: - Actions

    private func loadPreview() async {
        // Fetch only when no preview was preloaded by the presenter.
        let result: ProjectPreview?
        if let preview {
            result = preview
        } else {
            result = await ProjectInviteService.fetchPreview(ownerUID: ownerUID, projectID: projectID)
            guard let result else {
                loadState = .failed
                return
            }
            preview = result
        }
        guard let result else { return }

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

        loadState = .loaded
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

/// Full-bleed button style that scales down on press and preserves the label's
/// own foreground color (no system accent tint).
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
