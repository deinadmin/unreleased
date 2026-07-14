import CoreImage.CIFilterBuiltins
import SwiftUI

struct ProjectShareSheet: View {
    let project: Project
    @Environment(AuthManager.self) private var auth
    @Environment(ProjectStore.self) private var store

    @State private var showQRCode = false
    @State private var qrImage: UIImage?
    @State private var didCopy = false
    @State private var copyHapticTick = 0
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var invitees: [InviteeInfo] = []
    @State private var pendingInvites: [PendingInviteInfo] = []
    @State private var loadedInvitees = false

    // Link enable/disable
    @State private var linkEnabled = true
    @State private var loadedLinkState = false
    @State private var isUpdatingLink = false

    // Invite by username
    @State private var searchText = ""
    @State private var searchResults: [UserSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var invitedUIDs: Set<String> = []
    @State private var invitingUIDs: Set<String> = []
    @FocusState private var searchFocused: Bool

    // Remove-listener / cancel-invite confirmation
    @State private var inviteeToRemove: InviteeInfo?
    @State private var pendingToCancel: PendingInviteInfo?

    private var deepLinkOwnerID: String? {
        project.ownerID ?? auth.signedInUserID
    }

    private var deepLink: String {
        guard let ownerID = deepLinkOwnerID else { return "" }
        return "unreleased://project/\(ownerID)/\(project.id.uuidString.lowercased())"
    }

    private var isOwner: Bool { !project.isShared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if isOwner {
                        inviteSection
                            .padding(.horizontal, 20)
                            .padding(.bottom, 28)
                    }

                    linkSection
                        .padding(.horizontal, 20)

                    if isOwner && loadedInvitees {
                        inviteesSection
                            .padding(.top, 28)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Share Project")
            .navigationSubtitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Remove Listener", isPresented: Binding(
            get: { inviteeToRemove != nil },
            set: { if !$0 { inviteeToRemove = nil } }
        )) {
            if let invitee = inviteeToRemove {
                Button("Remove @\(invitee.username)", role: .destructive) {
                    Task { await removeInvitee(invitee) }
                }
            }
            Button("Cancel", role: .cancel) { inviteeToRemove = nil }
        } message: {
            if let invitee = inviteeToRemove {
                Text("@\(invitee.username) will no longer have access to this project.")
            }
        }
        .alert("Cancel Invite", isPresented: Binding(
            get: { pendingToCancel != nil },
            set: { if !$0 { pendingToCancel = nil } }
        )) {
            if let pending = pendingToCancel {
                Button("Cancel Invite", role: .destructive) {
                    Task { await cancelInvite(pending) }
                }
            }
            Button("Keep Invite", role: .cancel) { pendingToCancel = nil }
        } message: {
            if let pending = pendingToCancel {
                Text("The invite sent to @\(pending.username) will be withdrawn.")
            }
        }
        .blur(radius: showQRCode ? 20 : 0)
        .overlay {
            qrOverlay
                .opacity(showQRCode ? 1 : 0)
                .allowsHitTesting(showQRCode)
        }
        .sensoryFeedback(.increase, trigger: copyHapticTick)
        .sensoryFeedback(.increase, trigger: showQRCode)
        .animation(.easeOut(duration: 0.28), value: showQRCode)
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: loadedInvitees)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: searchResults)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: pendingInvites)
        .animation(.easeInOut(duration: 0.2), value: linkEnabled)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .presentationBackground(Color(.systemBackground))
        .task { await load() }
    }

    // MARK: - Invite by username

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Invite people")

            searchField

            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(searchResults) { user in
                        searchResultRow(user)
                        if user.id != searchResults.last?.id {
                            Divider().padding(.leading, 16 + 32 + 12)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isSearching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Searching…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if !trimmedQuery.isEmpty {
                Text("No users found for “\(trimmedQuery)”")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.leading, 14)

            TextField("Search by username", text: $searchText)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .onChange(of: searchText) { _, new in scheduleSearch(new) }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
        .frame(height: 48)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func searchResultRow(_ user: UserSearchResult) -> some View {
        HStack(spacing: 12) {
            avatarCircle(initial: user.username.first.map(String.init) ?? "?", size: 32)

            Text("@\(user.username)")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)

            Spacer()

            inviteButton(for: user)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func inviteButton(for user: UserSearchResult) -> some View {
        if invitedUIDs.contains(user.id) {
            Label("Invited", systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
        } else if invitingUIDs.contains(user.id) {
            ProgressView().scaleEffect(0.8)
        } else {
            Button {
                Task { await invite(user) }
            } label: {
                Text("Invite")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Link section

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Share link")

            if isOwner {
                linkToggleRow
            }

            linkField

            if linkEnabled {
                actionButtons
                    .padding(.top, 2)
            }
        }
    }

    private var linkField: some View {
        Button {
            guard !deepLink.isEmpty, linkEnabled else { return }
            copyLink()
        } label: {
            HStack(spacing: 0) {
                Text(deepLink.isEmpty ? "Sign in to share" : deepLink)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(deepLink.isEmpty || !linkEnabled ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)

                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(didCopy ? .green : .secondary)
                    .frame(width: 52, height: 52)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 52)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(linkEnabled ? 1 : 0.55)
        .disabled(deepLink.isEmpty || !linkEnabled)
    }

    private func copyLink() {
        UIPasteboard.general.string = deepLink
        copyHapticTick &+= 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { didCopy = false }
        }
    }

    private var linkToggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { linkEnabled },
                set: { setLinkEnabled($0) }
            )) {
                Text("Enable share link")
                    .font(.system(size: 15))
            }
            .tint(Color(uiColor: .systemGreen))
            .disabled(!loadedLinkState || isUpdatingLink)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !linkEnabled {
                Text("Link disabled. People already in this project keep their access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard !deepLink.isEmpty else { return }
                presentShareSheet()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.primary)
            }
            .disabled(deepLink.isEmpty || !linkEnabled)

            Button {
                showQRCode = true
            } label: {
                Label("QR Code", systemImage: "qrcode")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.primary)
            }
            .disabled(deepLink.isEmpty || !linkEnabled)
        }
        .opacity(linkEnabled ? 1 : 0.55)
    }

    private func presentShareSheet() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
            var top = window.rootViewController
        else { return }

        // Walk to the top-most presented controller (this sheet is already presented).
        while let presented = top.presentedViewController {
            top = presented
        }

        let av = UIActivityViewController(activityItems: [deepLink], applicationActivities: nil)

        // iPad requires a source for the popover.
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }

        top.present(av, animated: true)
    }

    // MARK: - QR code

    private var qrOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.55)

            VStack(spacing: 20) {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(24)
                        .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                } else {
                    ProgressView()
                }

                Text("Tap to dismiss")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .offset(y: showQRCode ? 0 : 80)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: showQRCode)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { showQRCode = false }
    }

    // MARK: - Invitees (Listeners) section

    private var totalListenerCount: Int { invitees.count + pendingInvites.count }

    @ViewBuilder
    private var inviteesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(totalListenerCount == 0 ? "No listeners yet" : "Listeners")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if totalListenerCount > 0 {
                    Text("\(totalListenerCount)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if totalListenerCount == 0 {
                Text("Invite people above or share the link so others can join.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    // Pending invites first
                    ForEach(pendingInvites) { pending in
                        pendingInviteRow(pending)
                        if pending.id != pendingInvites.last?.id || !invitees.isEmpty {
                            Divider().padding(.leading, 20 + 28 + 12)
                        }
                    }
                    // Accepted listeners
                    ForEach(invitees) { invitee in
                        inviteeRow(invitee)
                        if invitee.id != invitees.last?.id {
                            Divider().padding(.leading, 20 + 28 + 12)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 20)
            }
        }
    }

    private func pendingInviteRow(_ pending: PendingInviteInfo) -> some View {
        HStack(spacing: 12) {
            avatarCircle(initial: String(pending.username.prefix(1)), size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("@\(pending.username)")
                    .font(.system(size: 15, weight: .medium))
                Text("Invite pending")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                pendingToCancel = pending
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func inviteeRow(_ invitee: InviteeInfo) -> some View {
        HStack(spacing: 12) {
            avatarCircle(initial: String(invitee.username.prefix(1)), size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("@\(invitee.username)")
                    .font(.system(size: 15, weight: .medium))
                Text("Joined \(invitee.acceptedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                inviteeToRemove = invitee
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Shared helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 4)
    }

    private func avatarCircle(initial: String, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemBackground))
                .frame(width: size, height: size)
            Text(initial.uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Actions

    private func load() async {
        qrImage = generateQRCode(deepLink)
        guard isOwner,
              let ownerID = auth.signedInUserID,
              let username = store.currentUsername
        else { return }

        // Write preview so recipients can see invite info before accepting.
        await ProjectInviteService.writePreview(
            project: project,
            ownerUID: ownerID,
            ownerUsername: username
        )

        // Load current link state, accepted invitees, and pending invites in parallel.
        async let previewTask = ProjectInviteService.fetchPreview(ownerUID: ownerID, projectID: project.id)
        async let inviteesTask = ProjectInviteService.fetchInvitees(ownerUID: ownerID, projectID: project.id)
        async let pendingTask = ProjectInviteService.fetchPendingInvites(ownerUID: ownerID, projectID: project.id)

        let preview = await previewTask
        let list = await inviteesTask
        let pending = await pendingTask

        withAnimation {
            linkEnabled = preview?.linkEnabled ?? true
            loadedLinkState = true
            invitees = list
            pendingInvites = pending
            loadedInvitees = true
        }
    }

    private func setLinkEnabled(_ enabled: Bool) {
        guard let ownerID = auth.signedInUserID else { return }
        let previous = linkEnabled
        withAnimation { linkEnabled = enabled }
        isUpdatingLink = true
        Task {
            do {
                try await ProjectInviteService.setLinkEnabled(enabled, ownerUID: ownerID, projectID: project.id)
            } catch {
                withAnimation { linkEnabled = previous }   // revert on failure
            }
            isUpdatingLink = false
        }
    }

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let results = await store.searchUsersToInvite(query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { searchResults = results }
                isSearching = false
            }
        }
    }

    private func invite(_ user: UserSearchResult) async {
        invitingUIDs.insert(user.id)
        do {
            let notificationID = try await store.inviteUser(user, to: project)
            let newPending = PendingInviteInfo(
                id: user.id,
                username: user.username,
                invitedAt: Date(),
                notificationID: notificationID.isEmpty ? nil : notificationID
            )
            withAnimation {
                _ = invitedUIDs.insert(user.id)
                pendingInvites.append(newPending)
            }
        } catch {
            print("ProjectShareSheet: invite failed — \(error)")
        }
        invitingUIDs.remove(user.id)
    }

    private func cancelInvite(_ pending: PendingInviteInfo) async {
        guard let ownerID = auth.signedInUserID else { return }
        await ProjectInviteService.cancelInvite(
            ownerUID: ownerID,
            projectID: project.id,
            inviteeUID: pending.id,
            notificationID: pending.notificationID
        )
        withAnimation {
            pendingInvites.removeAll { $0.id == pending.id }
            invitedUIDs.remove(pending.id)
        }
    }

    private func removeInvitee(_ invitee: InviteeInfo) async {
        guard let ownerID = auth.signedInUserID else { return }
        try? await ProjectInviteService.removeInvitee(
            ownerUID: ownerID,
            projectID: project.id,
            inviteeUID: invitee.id
        )
        withAnimation { invitees.removeAll { $0.id == invitee.id } }
    }

    // MARK: - QR generation

    private func generateQRCode(_ string: String) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
