import SwiftUI

struct StorageSyncView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AuthManager.self) private var auth

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                storageSection
                syncSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .bottomChromeAwarePadding(resting: 40)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("Storage & Sync")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: DeleteTracksRoute.self) { _ in
            DeleteTracksView()
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        settingsSection(title: "Storage") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.formattedTotalUsed)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("used of \(store.formattedStorageLimit)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(store.formattedFreeStorage)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(store.storageUsedFraction > 0.9 ? .red : .primary)
                        Text("available")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                StorageProgressBar(fraction: store.storageUsedFraction)

                HStack(spacing: 16) {
                    Label {
                        Text("\(store.projects.count) \(store.projects.count == 1 ? "project" : "projects")")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))

                    Label {
                        Text("\(totalTrackCount) \(totalTrackCount == 1 ? "track" : "tracks")")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                syncStatusRow

                if auth.isSignedIn {
                    cardDivider

                    if let email = auth.accountLabel {
                        settingsRow(icon: "person.circle", title: "Account", value: email)
                        cardDivider
                    }

                    settingsRow(
                        icon: "music.note.list",
                        title: "Projects",
                        value: "\(store.projects.count)"
                    )
                    cardDivider

                    settingsRow(
                        icon: "waveform",
                        title: "Tracks",
                        value: "\(totalTrackCount)"
                    )
                    cardDivider

                    NavigationLink(value: DeleteTracksRoute()) {
                        HStack(spacing: 12) {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(width: 28)
                            Text("Delete tracks")
                                .font(.system(size: 16))
                                .foregroundStyle(.red)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    cardDivider

                    settingsRow(
                        icon: "icloud.and.arrow.up",
                        title: "Uploaded to cloud",
                        value: "\(uploadedTrackCount) of \(totalTrackCount)"
                    )
                    cardDivider

                    settingsRow(
                        icon: "arrow.down.circle",
                        title: "Downloaded offline",
                        value: "\(downloadedTrackCount) of \(totalTrackCount)"
                    )
                }
            }
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            if !auth.isSignedIn {
                Text("Sign in to sync your library across devices.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var syncStatusRow: some View {
        HStack(spacing: 12) {
            syncStatusIcon
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(syncStatusTitle)
                    .font(.system(size: 16))
                if let detail = syncStatusDetail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

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
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }

    private var cardDivider: some View {
        Divider()
            .padding(.leading, 56)
    }

    private var totalTrackCount: Int {
        store.projects.flatMap(\.tracks).count
    }

    private var uploadedTrackCount: Int {
        store.projects.flatMap(\.tracks).filter { $0.storagePath != nil }.count
    }

    private var downloadedTrackCount: Int {
        store.projects.flatMap(\.tracks).filter { $0.isDownloaded }.count
    }

    @ViewBuilder
    private var syncStatusIcon: some View {
        switch store.syncStatus {
        case .offline:
            Image(systemName: "icloud.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
        case .syncing:
            SyncingIcon()
        case .synced:
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.icloud.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.red)
        }
    }

    private var syncStatusTitle: String {
        switch store.syncStatus {
        case .offline: return auth.isSignedIn ? "Offline" : "Not signed in"
        case .syncing: return "Syncing…"
        case .synced: return "Up to date"
        case .error: return "Sync error"
        }
    }

    private var syncStatusDetail: String? {
        switch store.syncStatus {
        case .offline: return auth.isSignedIn ? "Changes will sync when you're back online." : "Sign in to enable cloud sync."
        case .syncing:
            let pending = store.pendingCloudUploadCount
            if pending > 0 {
                return "Uploading \(pending) \(pending == 1 ? "track" : "tracks") to the cloud."
            }
            return "Syncing your latest changes."
        case .synced: return "Your library is synced to the cloud."
        case .error(let msg): return msg
        }
    }

    @ViewBuilder
    private func settingsRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 16))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Storage progress bar

private struct StorageProgressBar: View {
    let fraction: Double

    private var barColor: Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(.systemFill))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(barColor)
                    .frame(width: max(10, geo.size.width * CGFloat(fraction)))
                    .animation(.easeInOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Animated sync icon

private struct SyncingIcon: View {
    var body: some View {
        TwoToneCircleSpinner(diameter: 18, lineWidth: 2)
    }
}

#Preview {
    NavigationStack {
        StorageSyncView()
    }
    .environment(ProjectStore())
    .environment(AuthManager())
}
