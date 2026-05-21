import SwiftUI

struct ProfileView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player

    @State private var showSignOutConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 32)
                    .padding(.bottom, 36)

                settingsSection
                    .padding(.horizontal, 20)

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

            Text(auth.displayName)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)

            if let label = auth.accountLabel {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
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
                    ProfileSettingsRow(row: row)

                    if index < placeholderSettings.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    }

    private func signOut() {
        player.stop()
        store.configureSync(userID: nil)
        auth.signOut()
    }

    private var placeholderSettings: [ProfileSettingsRow.Model] {
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

// MARK: - Settings row

private struct ProfileSettingsRow: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let icon: String
    }

    let row: Model

    var body: some View {
        Button {} label: {
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
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.72)
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
