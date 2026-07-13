import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var preferences = PushNotificationManager.Preferences.defaults
    @State private var hasLoadedPreferences = false

    private var hasSystemPermission: Bool {
        switch authStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    private var categoriesEnabled: Bool {
        hasSystemPermission && preferences.enabled
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                generalSection
                projectActivitySection
                    .disabled(!categoriesEnabled)
                    .opacity(categoriesEnabled ? 1 : 0.45)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    private var generalSection: some View {
        settingsSection(title: "General") {
            settingRow(
                icon: hasSystemPermission ? "bell.badge" : "bell.slash",
                iconColor: hasSystemPermission ? .green : .red,
                title: "Notifications",
                subtitle: generalSubtitle
            ) {
                Toggle("", isOn: generalBinding)
                    .labelsHidden()
                    .tint(Color(uiColor: .systemGreen))
            }
        }
    }

    private var projectActivitySection: some View {
        settingsSection(title: "Project activity") {
            settingRow(
                icon: "person.badge.plus",
                iconColor: .secondary,
                title: "New project invites",
                subtitle: "When someone invites you to collaborate on a project."
            ) {
                Toggle("", isOn: preferenceBinding(\.projectInvites))
                    .labelsHidden()
                    .tint(Color(uiColor: .systemGreen))
            }
        }
    }

    private var generalSubtitle: String {
        if !hasSystemPermission {
            return "Enable notification permission in Settings to receive alerts."
        }
        return preferences.enabled
            ? "Choose which alerts you want to receive."
            : "All notification categories are paused."
    }

    private var generalBinding: Binding<Bool> {
        Binding(
            get: { hasSystemPermission && preferences.enabled },
            set: { newValue in
                guard hasSystemPermission else {
                    openSystemSettings()
                    return
                }
                preferences.enabled = newValue
                savePreferences()
            }
        )
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<PushNotificationManager.Preferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                preferences[keyPath: keyPath] = newValue
                savePreferences()
            }
        )
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func settingRow<Trailing: View>(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func load() async {
        async let status: Void = refreshStatus()
        preferences = await PushNotificationManager.shared.loadPreferences()
        hasLoadedPreferences = true
        await status
    }

    private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authStatus = settings.authorizationStatus
    }

    private func savePreferences() {
        let value = preferences
        Task { await PushNotificationManager.shared.savePreferences(value) }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    NavigationStack { NotificationSettingsView() }
}
