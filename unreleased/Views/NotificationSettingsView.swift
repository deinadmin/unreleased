import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                permissionSection
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                categoriesSection
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    // MARK: - Permission section

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permission")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                switch authStatus {
                case .denied:
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        permissionRow(
                            icon: "bell.slash",
                            iconColor: .red,
                            title: "Notifications Disabled",
                            subtitle: "Tap to open Settings and enable notifications.",
                            trailing: AnyView(
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            )
                        )
                    }
                    .buttonStyle(.plain)

                case .notDetermined:
                    Button {
                        Task {
                            PushNotificationManager.shared.registerForPushNotifications()
                            // Brief wait for the system prompt to be processed.
                            try? await Task.sleep(for: .milliseconds(600))
                            await refreshStatus()
                        }
                    } label: {
                        permissionRow(
                            icon: "bell",
                            iconColor: .secondary,
                            title: "Enable Notifications",
                            subtitle: "Get notified about project invites and activity.",
                            trailing: AnyView(
                                Text("Enable")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                            )
                        )
                    }
                    .buttonStyle(.plain)

                default:
                    permissionRow(
                        icon: "bell.badge",
                        iconColor: .green,
                        title: "Notifications Enabled",
                        subtitle: "You'll be notified for the activity listed below.",
                        trailing: AnyView(EmptyView())
                    )
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        trailing: AnyView
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Categories section

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You'll be notified about")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("New project invite")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        Text("When someone invites you to collaborate on a project.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Helpers

    private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authStatus = settings.authorizationStatus
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
}
