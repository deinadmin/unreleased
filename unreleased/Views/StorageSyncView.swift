import SwiftUI

struct StorageSyncView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AuthManager.self) private var auth

    var body: some View {
        List {
            storageSection
            syncSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage & Sync")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: DeleteTracksRoute.self) { _ in
            DeleteTracksView()
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
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
            .padding(.vertical, 6)
        } header: {
            Text("Storage")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            HStack {
                syncStatusIcon
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(syncStatusTitle)
                        .font(.system(size: 16))
                    if let detail = syncStatusDetail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            if auth.isSignedIn {
                if let email = auth.accountLabel {
                    settingsRow(icon: "person.circle", title: "Account", value: email)
                }

                settingsRow(
                    icon: "music.note.list",
                    title: "Projects",
                    value: "\(store.projects.count)"
                )

                settingsRow(
                    icon: "waveform",
                    title: "Tracks",
                    value: "\(totalTrackCount)"
                )

                NavigationLink(value: DeleteTracksRoute()) {
                    Label("Delete tracks", systemImage: "trash")
                        .font(.system(size: 16))
                }

                settingsRow(
                    icon: "icloud.and.arrow.up",
                    title: "Uploaded to cloud",
                    value: "\(uploadedTrackCount) of \(totalTrackCount)"
                )

                settingsRow(
                    icon: "arrow.down.circle",
                    title: "Downloaded offline",
                    value: "\(downloadedTrackCount) of \(totalTrackCount)"
                )
            }
        } header: {
            Text("Sync")
        } footer: {
            if !auth.isSignedIn {
                Text("Sign in to sync your library across devices.")
            }
        }
    }

    // MARK: - Helpers

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
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 16))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
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
