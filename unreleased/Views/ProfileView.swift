import MessageUI
import SwiftUI

struct ProfileView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(ProjectStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(ProfileAvatarStore.self) private var avatarStore
    @Environment(MiniPlayerVisibility.self) private var miniPlayerVisibility

    @State private var showSignOutConfirm = false
    @State private var showHelpMail = false
    @State private var isAvatarOverlayPresented = false
    @State private var avatarExpansionProgress: CGFloat = 0
    @State private var avatarSourceFrame: CGRect = .zero
    @State private var avatarDragOffset: CGSize = .zero
    @State private var avatarDragDistance: CGFloat = 0
    @State private var showPhotoPicker = false
    @State private var isUploadingAvatar = false
    @State private var avatarUploadProgress: Double = 0
    @State private var avatarErrorMessage: String?
    @State private var avatarTapHapticTrigger = 0

    private let supportEmail = "me@designedbycarl.de"
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let avatarDismissThreshold: CGFloat = 120
    private let avatarDragResistance: CGFloat = 90

    var body: some View {
        ZStack {
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
                }
                .bottomChromeAwarePadding(resting: 40)
            }
            .blur(radius: 14 * avatarExpansionProgress * avatarDragBlurProgress)
            .allowsHitTesting(!isAvatarOverlayPresented)

            if isAvatarOverlayPresented {
                expandedAvatarOverlay
                    .zIndex(1)
            }
        }
        .sensoryFeedback(.increase, trigger: avatarTapHapticTrigger)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign Out?", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to sign in again to access your library.")
        }
        .sheet(isPresented: $showPhotoPicker) {
            SquarePhotoPicker(onImagePicked: uploadAvatar)
        }
        .alert("Couldn’t Update Photo", isPresented: avatarErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(avatarErrorMessage ?? "Please try again.")
        }
        .onDisappear {
            miniPlayerVisibility.show(for: .enlargedProfilePhoto)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Button {
                expandAvatar()
            } label: {
                ProfileAvatarView(size: 108)
                    .opacity(isAvatarOverlayPresented ? 0 : 1)
                    .animation(nil, value: isAvatarOverlayPresented)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        avatarSourceFrame = frame
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change profile photo")
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

    private var expandedAvatarOverlay: some View {
        GeometryReader { proxy in
            let targetSize = min(248, proxy.size.width - 80)
            let overlayFrame = proxy.frame(in: .global)
            let sourceCenter = CGPoint(
                x: avatarSourceFrame.midX - overlayFrame.minX,
                y: avatarSourceFrame.midY - overlayFrame.minY
            )
            let targetCenter = screenCenter(relativeTo: overlayFrame, fallbackSize: proxy.size)
            let buttonCenter = bottomActionCenter(relativeTo: overlayFrame, fallbackSize: proxy.size)
            let currentSize = interpolate(from: avatarSourceFrame.width, to: targetSize)
            let currentScale = currentSize / targetSize
            let currentCenter = CGPoint(
                x: interpolate(from: sourceCenter.x, to: targetCenter.x),
                y: interpolate(from: sourceCenter.y, to: targetCenter.y)
            )
            let buttonProgress = min(max((avatarExpansionProgress - 0.58) / 0.42, 0), 1)

            ZStack(alignment: .topLeading) {
                Button {
                    avatarTapHapticTrigger += 1
                    collapseAvatar()
                } label: {
                    Color.black
                        .opacity(0.18 * avatarExpansionProgress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close profile photo")

                ProfileAvatarView(size: targetSize)
                    .scaleEffect(currentScale)
                    .shadow(
                        color: .black.opacity(0.2 * avatarExpansionProgress),
                        radius: 24 * avatarExpansionProgress,
                        y: 12 * avatarExpansionProgress
                    )
                    .offset(avatarDragOffset)
                    .position(currentCenter)
                    .gesture(avatarDismissGesture)

                ProfilePhotoActionButton(
                    isUploading: isUploadingAvatar,
                    progress: avatarUploadProgress,
                    action: { showPhotoPicker = true }
                )
                .opacity(buttonProgress * avatarDragBlurProgress)
                .blur(radius: 8 * (1 - avatarDragBlurProgress))
                .offset(y: 14 * (1 - buttonProgress))
                .position(
                    x: buttonCenter.x,
                    y: buttonCenter.y
                )
            }
        }
    }

    private func interpolate(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * avatarExpansionProgress
    }

    private func screenCenter(relativeTo overlayFrame: CGRect, fallbackSize: CGSize) -> CGPoint {
        let screenBounds = activeWindowScene?.screen.bounds

        guard let screenBounds else {
            return CGPoint(x: fallbackSize.width / 2, y: fallbackSize.height / 2)
        }
        return CGPoint(
            x: screenBounds.midX - overlayFrame.minX,
            y: screenBounds.midY - overlayFrame.minY
        )
    }

    private func bottomActionCenter(relativeTo overlayFrame: CGRect, fallbackSize: CGSize) -> CGPoint {
        guard let scene = activeWindowScene else {
            return CGPoint(x: fallbackSize.width / 2, y: fallbackSize.height - 46)
        }

        let safeAreaBottom = scene.windows.first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
        return CGPoint(
            x: scene.screen.bounds.midX - overlayFrame.minX,
            y: scene.screen.bounds.maxY - overlayFrame.minY - safeAreaBottom - 46
        )
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
    }

    private var avatarDismissGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard avatarExpansionProgress > 0.98, !isUploadingAvatar else { return }
                avatarDragDistance = hypot(value.translation.width, value.translation.height)
                avatarDragOffset = rubberBanded(value.translation)
            }
            .onEnded { value in
                guard avatarExpansionProgress > 0.98, !isUploadingAvatar else {
                    avatarDragOffset = .zero
                    avatarDragDistance = 0
                    return
                }

                let distance = hypot(value.translation.width, value.translation.height)
                if distance >= avatarDismissThreshold {
                    avatarTapHapticTrigger += 1
                    collapseAvatar()
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        avatarDragOffset = .zero
                        avatarDragDistance = 0
                    }
                }
            }
    }

    private var avatarDragBlurProgress: CGFloat {
        1 - min(avatarDragDistance / avatarDismissThreshold, 1)
    }

    /// Preserves drag direction while progressively reducing movement at distance.
    private func rubberBanded(_ translation: CGSize) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0 else { return .zero }

        let resistedDistance = avatarDragResistance * log1p(distance / avatarDragResistance)
        let scale = resistedDistance / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }

    private func expandAvatar() {
        guard !isAvatarOverlayPresented, !avatarSourceFrame.isEmpty else { return }
        avatarTapHapticTrigger += 1
        avatarExpansionProgress = 0
        avatarDragDistance = 0
        miniPlayerVisibility.hide(for: .enlargedProfilePhoto)
        isAvatarOverlayPresented = true
        Task { @MainActor in
            await Task.yield()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                avatarExpansionProgress = 1
            }
        }
    }

    private var avatarErrorBinding: Binding<Bool> {
        Binding(
            get: { avatarErrorMessage != nil },
            set: { if !$0 { avatarErrorMessage = nil } }
        )
    }

    private func collapseAvatar() {
        guard !isUploadingAvatar else { return }
        withAnimation(
            .spring(response: 0.3, dampingFraction: 0.84),
            completionCriteria: .logicallyComplete
        ) {
            avatarExpansionProgress = 0
            avatarDragOffset = .zero
        } completion: {
            avatarDragDistance = 0
            isAvatarOverlayPresented = false
            miniPlayerVisibility.show(for: .enlargedProfilePhoto)
        }
    }

    private func uploadAvatar(_ image: UIImage) {
        let previousAvatar = avatarStore.image
        avatarStore.setImage(image)
        avatarUploadProgress = 0
        withAnimation(.smooth(duration: 0.28)) {
            isUploadingAvatar = true
        }

        Task {
            do {
                let optimizedAvatar = try await auth.updateProfilePhoto(image) { progress in
                    withAnimation(.smooth(duration: 0.2)) {
                        avatarUploadProgress = progress
                    }
                }
                avatarStore.setImage(optimizedAvatar)
                avatarUploadProgress = 1
                withAnimation(.smooth(duration: 0.22)) {
                    isUploadingAvatar = false
                    avatarUploadProgress = 0
                }
                collapseAvatar()
            } catch {
                avatarStore.setImage(previousAvatar)
                withAnimation(.smooth(duration: 0.22)) {
                    isUploadingAvatar = false
                    avatarUploadProgress = 0
                }
                avatarErrorMessage = error.localizedDescription
            }
        }
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

        case "eq":
            NavigationLink(value: EqualizerRoute()) {
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
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .buttonStyle(.scale)
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
            .init(id: "eq", title: "EQ", icon: "slider.horizontal.3"),
            .init(id: "storage", title: "Storage & Sync", icon: "icloud"),
            .init(id: "help", title: "Help & Support", icon: "questionmark.circle"),
            .init(id: "about", title: "About", icon: "info.circle"),
        ]
    }
}

private struct ProfilePhotoActionButton: View {
    let isUploading: Bool
    let progress: Double
    let action: () -> Void

    private let size = CGSize(width: 240, height: 48)
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    private var clampedProgress: CGFloat {
        guard isUploading else { return 0 }
        return CGFloat(min(max(progress, 0), 1))
    }

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    shape.fill(Color.primary.opacity(0.12))

                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: proxy.size.width * clampedProgress)
                        .frame(maxHeight: .infinity)

                    buttonContent
                        .foregroundStyle(Color.primary)

                    buttonContent
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: proxy.size.width * clampedProgress)
                        }
                }
                .clipShape(shape)
                .animation(.smooth(duration: 0.2), value: clampedProgress)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
        }
        .buttonStyle(.scale)
        .disabled(isUploading)
        .accessibilityLabel(isUploading ? "Uploading profile photo" : "Choose new profile photo")
        .accessibilityValue(isUploading ? "\(Int(clampedProgress * 100)) percent" : "")
    }

    private var buttonContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 14, weight: .semibold))
            Text(isUploading ? "Uploading…" : "Choose New Photo")
                .contentTransition(.interpolate)
        }
        .font(.system(size: 15, weight: .medium))
        .frame(width: size.width, height: size.height)
        .animation(.smooth(duration: 0.28), value: isUploading)
    }
}

// MARK: - Avatar

private struct ProfileAvatarView: View {
    @Environment(ProfileAvatarStore.self) private var avatarStore
    var size: CGFloat = 108

    var body: some View {
        Group {
            if let image = avatarStore.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
                    .overlay {
                        if avatarStore.isLoading {
                            ProgressView()
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .compositingGroup()
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
    .environment(ProfileAvatarStore())
    .environment(ProjectStore())
    .environment(AudioPlayer(store: ProjectStore()))
    .environment(MiniPlayerVisibility())
}
