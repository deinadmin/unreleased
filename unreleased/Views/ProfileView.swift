import MessageUI
import SwiftUI

struct ProfileView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player

    @State private var showSignOutConfirm = false
    @State private var showHelpMail = false

    private let supportEmail = "me@designedbycarl.de"
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 32)
                    .padding(.bottom, 36)

                myPlanSection
                    .padding(.horizontal, 20)

                settingsSection
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                signOutButton
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign Out?", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to sign in again to access your library.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            ProfileAvatarView(photoURL: auth.photoURL, size: 108)
                .padding(.bottom, 6)

            Text(primaryLabel)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)

            // Show the email as a secondary line only when a username is the primary.
            if store.currentUsername != nil, let email = auth.accountLabel {
                Text(email)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    /// `@username` when set; email as fallback; otherwise the OAuth display name.
    private var primaryLabel: String {
        if let username = store.currentUsername {
            return "@\(username)"
        }
        return auth.accountLabel ?? auth.displayName
    }

    // MARK: - My Plan

    private var myPlanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Plan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                planHeaderRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                if let expiry = store.currentPlan.expiryDescription {
                    Divider()
                        .padding(.leading, 56)

                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .center)

                        Text(expiry)
                            .font(.system(size: 14))
                            .foregroundStyle(store.currentPlan.isExpired ? .red : .secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var planHeaderRow: some View {
        let plan = store.currentPlan
        let tier = plan.effectiveTier
        return HStack(spacing: 12) {
            Image(systemName: tier.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tier.tintColor)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(tier.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(tier.storageDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(tier.displayName.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tier.tintColor.opacity(0.14), in: Capsule())
                .foregroundStyle(tier.tintColor)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(placeholderSettings.enumerated()), id: \.element.id) { index, row in
                    settingsRow(for: row)

                    if index < placeholderSettings.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .sheet(isPresented: $showHelpMail) {
            if MFMailComposeViewController.canSendMail() {
                MailComposeView(
                    toRecipients: [supportEmail],
                    subject: "Feedback iOS App unreleased v\(appVersion)",
                    onDismiss: { showHelpMail = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func settingsRow(for row: ProfileSettingsRowLabel.Model) -> some View {
        switch row.id {
        case "notifications":
            NavigationLink(value: NotificationSettingsRoute()) {
                ProfileSettingsRowLabel(row: row)
            }
            .buttonStyle(.plain)

        case "storage":
            NavigationLink(value: StorageSyncRoute()) {
                ProfileSettingsRowLabel(row: row)
            }
            .buttonStyle(.plain)

        case "help":
            Button {
                if MFMailComposeViewController.canSendMail() {
                    showHelpMail = true
                } else if let url = URL(string: "mailto:\(supportEmail)?subject=Feedback%20iOS%20App%20unreleased%20v\(appVersion)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                ProfileSettingsRowLabel(row: row)
            }
            .buttonStyle(.plain)

        case "about":
            NavigationLink(value: AboutRoute()) {
                ProfileSettingsRowLabel(row: row)
            }
            .buttonStyle(.plain)

        default:
            Button {} label: {
                ProfileSettingsRowLabel(row: row)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.72)
        }
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            showSignOutConfirm = true
        } label: {
            Text("Sign Out")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.scale)
        .padding(.bottom, 30)
    }

    private func signOut() {
        player.stop()
        store.configureSync(userID: nil)
        store.clearLocalLibrary()
        auth.signOut()
    }

    private var placeholderSettings: [ProfileSettingsRowLabel.Model] {
        [
            .init(id: "notifications", title: "Notifications", icon: "bell"),
            .init(id: "appearance", title: "Appearance", icon: "circle.lefthalf.filled"),
            .init(id: "storage", title: "Storage & Sync", icon: "icloud"),
            .init(id: "help", title: "Help & Support", icon: "questionmark.circle"),
            .init(id: "about", title: "About", icon: "info.circle"),
        ]
    }
}

// MARK: - Avatar

private struct ProfileAvatarView: View {
    let photoURL: URL?
    var size: CGFloat = 108

    var body: some View {
        Group {
            if let photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder
                            .overlay {
                                ProgressView()
                            }
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle()
                .fill(Color(.secondarySystemBackground))
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(Color(.tertiaryLabel))
        }
    }
}

// MARK: - Settings row label

private struct ProfileSettingsRowLabel: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let icon: String
    }

    let row: Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            Text(row.title)
                .font(.system(size: 16))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        ProfileView()
    }
    .environment(AuthManager())
    .environment(ProjectStore())
    .environment(AudioPlayer(store: ProjectStore()))
}
