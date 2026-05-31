import CoreImage.CIFilterBuiltins
import SwiftUI

struct ProjectShareSheet: View {
    let project: Project
    @Environment(AuthManager.self) private var auth
    @Environment(ProjectStore.self) private var store

    @State private var showQRCode = false
    @State private var qrImage: UIImage?
    @State private var didCopy = false
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var invitees: [InviteeInfo] = []
    @State private var loadedInvitees = false

    private var deepLinkOwnerID: String? {
        project.ownerID ?? auth.signedInUserID
    }

    private var deepLink: String {
        guard let ownerID = deepLinkOwnerID else { return "" }
        return "unreleased://project/\(ownerID)/\(project.id.uuidString.lowercased())"
    }

    private var isOwner: Bool { !project.isShared }

    var body: some View {
        VStack(spacing: 0) {
            header
            linkField
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            actionButtons
                .padding(.horizontal, 20)

            if showQRCode {
                qrSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if isOwner && loadedInvitees {
                inviteesSection
                    .padding(.top, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: showQRCode)
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: loadedInvitees)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .task {
            qrImage = generateQRCode(deepLink)
            guard isOwner,
                  let ownerID = auth.signedInUserID,
                  let username = store.currentUsername
            else { return }
            // Write preview so recipients can see invite info before accepting.
            async let _ = ProjectInviteService.writePreview(
                project: project,
                ownerUID: ownerID,
                ownerUsername: username
            )
            // Fetch current invitees.
            let list = await ProjectInviteService.fetchInvitees(ownerUID: ownerID, projectID: project.id)
            withAnimation { invitees = list; loadedInvitees = true }
            if !list.isEmpty { selectedDetent = .large }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Share Project")
                .font(.headline)
            Text(project.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Link field

    private var linkField: some View {
        HStack(spacing: 0) {
            Text(deepLink.isEmpty ? "Sign in to share" : deepLink)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(deepLink.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)

            Button {
                guard !deepLink.isEmpty else { return }
                UIPasteboard.general.string = deepLink
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { didCopy = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { didCopy = false }
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(didCopy ? .green : .secondary)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(deepLink.isEmpty)
        }
        .frame(height: 52)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard !deepLink.isEmpty else { return }
                let av = UIActivityViewController(activityItems: [deepLink], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = scene.windows.first {
                    window.rootViewController?.present(av, animated: true)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.primary)
            }

            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    showQRCode.toggle()
                    selectedDetent = showQRCode ? .large : .medium
                }
            } label: {
                Label(showQRCode ? "Hide QR Code" : "QR Code", systemImage: "qrcode")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        showQRCode ? Color.primary : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .foregroundStyle(showQRCode ? Color(UIColor.systemBackground) : .primary)
            }
        }
    }

    // MARK: - QR code

    @ViewBuilder
    private var qrSection: some View {
        if let qrImage {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .padding(20)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .padding(.top, 24)
        } else {
            ProgressView().padding(.top, 24)
        }
    }

    // MARK: - Invitees section

    @ViewBuilder
    private var inviteesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(invitees.isEmpty ? "No listeners yet" : "Listeners")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !invitees.isEmpty {
                    Text("\(invitees.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if invitees.isEmpty {
                Text("Share the link above so others can accept your project invite.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
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

    private func inviteeRow(_ invitee: InviteeInfo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: 28, height: 28)
                Text(String(invitee.username.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("@\(invitee.username)")
                    .font(.system(size: 15, weight: .medium))
                Text("Joined \(invitee.acceptedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await removeInvitee(invitee) }
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
