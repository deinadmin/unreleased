import SwiftUI

struct UsernamePickerSheet: View {
    @Environment(ProjectStore.self) private var store

    @State private var username = ""
    @State private var availability: AvailabilityState = .idle
    @State private var isSaving = false
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var sheetHeight: CGFloat = 420
    @FocusState private var fieldFocused: Bool

    private enum AvailabilityState: Equatable {
        case idle, checking, available, taken, invalid
        case checkFailed            // network/permission error during availability check
        case saveFailed(String)     // error returned by the actual save operation

        var isValid: Bool { self == .available }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking), (.available, .available),
                 (.taken, .taken), (.invalid, .invalid), (.checkFailed, .checkFailed):
                return true
            case (.saveFailed(let a), .saveFailed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            icon
                .padding(.top, 28)
                .padding(.bottom, 16)

            titleBlock
                .padding(.bottom, 24)

            inputField
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            hint
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            continueButton
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        // Measure content height and feed it into the detent.
        .background {
            GeometryReader { geo in
                Color.clear
                    .task(id: geo.size.height) {
                        guard geo.size.height > 100 else { return }
                        sheetHeight = geo.size.height
                    }
            }
        }
        .safeAreaPadding(.bottom)
        .presentationDetents([.height(sheetHeight)])
        .presentationBackground(Color(.secondarySystemBackground))
        .interactiveDismissDisabled(true)
        .presentationDragIndicator(.hidden)
        .onAppear { fieldFocused = true }
    }

    // MARK: - Subviews

    private var icon: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 64, height: 64)
            Image(systemName: "at")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 5) {
            Text("Choose a username")
                .font(.title3.bold())
            Text("Others see this when you share a project.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var inputField: some View {
        HStack(spacing: 4) {
            Text("@")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 16)

            TextField("username", text: $username)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onChange(of: username) { _, new in handleInput(new) }

            statusIndicator
                .frame(width: 44, height: 44)
        }
        .frame(height: 50)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch availability {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().scaleEffect(0.75)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .taken, .invalid, .saveFailed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
                .transition(.scale.combined(with: .opacity))
        case .checkFailed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var hint: some View {
        Group {
            switch availability {
            case .taken:
                Text("@\(username) is already taken.")
                    .foregroundStyle(.red)
            case .invalid:
                Text("3–20 characters. Letters, numbers, and underscores only.")
                    .foregroundStyle(.red)
            case .available:
                Text("@\(username) is available.")
                    .foregroundStyle(.green)
            case .checkFailed:
                Text("Couldn't check availability. Check your connection.")
                    .foregroundStyle(.orange)
            case .saveFailed(let message):
                Text(message)
                    .foregroundStyle(.red)
            default:
                Text("3–20 characters. Letters, numbers, and underscores only.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: availability)
    }

    private var continueButton: some View {
        let isReady = availability.isValid && !isSaving
        return Button {
            Task { await save() }
        } label: {
            ZStack {
                if isSaving {
                    ProgressView()
                        .tint(Color(UIColor.systemBackground))
                } else {
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                isReady ? Color.primary : Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .foregroundStyle(isReady ? Color(UIColor.systemBackground) : Color(UIColor.tertiaryLabel))
        }
        .disabled(!isReady)
        .animation(.easeInOut(duration: 0.2), value: isReady)
    }

    // MARK: - Logic

    private func handleInput(_ raw: String) {
        let cleaned = raw.lowercased()
        if raw != cleaned {
            username = cleaned
            return
        }
        availability = .idle
        debounceTask?.cancel()

        guard !cleaned.isEmpty else { return }

        guard isValidFormat(cleaned) else {
            availability = .invalid
            return
        }

        availability = .checking
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                let available = try await UserProfileService.isAvailable(cleaned)
                withAnimation { availability = available ? .available : .taken }
            } catch {
                withAnimation { availability = .checkFailed }
            }
        }
    }

    private func save() async {
        guard availability.isValid else { return }
        isSaving = true
        do {
            try await store.setUsername(username)
            // On success the store's currentUsername is set, dismissing the sheet.
        } catch let nsError as NSError where nsError.domain == "UserProfileService" && nsError.code == 409 {
            // The username was claimed between our availability check and the transaction.
            isSaving = false
            withAnimation { availability = .taken }
        } catch {
            isSaving = false
            withAnimation { availability = .saveFailed(error.localizedDescription) }
        }
    }

    private func isValidFormat(_ value: String) -> Bool {
        guard value.count >= 3, value.count <= 20 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
