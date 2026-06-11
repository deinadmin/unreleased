import SwiftUI

struct NotificationsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ProjectLinkRouter.self) private var linkRouter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.notifications.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: store.notifications)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.notifications) { notification in
                    Button {
                        open(notification)
                    } label: {
                        NotificationRow(notification: notification)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            store.deleteNotification(notification)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No notifications")
                .font(.system(size: 17, weight: .semibold))
            Text("Invites and project activity will show up here.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if store.unreadNotificationCount > 0 {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark all read") {
                    store.markAllNotificationsRead()
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
    }

    // MARK: - Actions

    private func open(_ notification: AppNotification) {
        store.markNotificationRead(notification)
        switch notification.kind {
        case .projectInvite:
            linkRouter.receive(ownerID: notification.fromUID, projectID: notification.projectID)
            // Already joined: navigateToProject() resets the entire nav stack, so NotificationsView
            // disappears naturally — calling dismiss() here would race and pop the newly pushed project.
            // New invite: dismiss so the invite sheet can present cleanly over the root.
            if !store.projects.contains(where: { $0.id == notification.projectID }) {
                dismiss()
            }
        case .unknown:
            break
        }
    }
}

// MARK: - Row

private struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(notification.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !notification.read {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 40, height: 40)
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var iconName: String {
        switch notification.kind {
        case .projectInvite: return "person.badge.plus"
        case .unknown: return "bell"
        }
    }

    private var title: AttributedString {
        switch notification.kind {
        case .projectInvite:
            var result = AttributedString("@\(notification.fromUsername)")
            result.foregroundColor = .primary
            var rest = AttributedString(" invited you to “\(notification.projectName)”")
            rest.foregroundColor = .primary
            result.append(rest)
            return result
        case .unknown:
            return AttributedString(notification.projectName)
        }
    }
}
