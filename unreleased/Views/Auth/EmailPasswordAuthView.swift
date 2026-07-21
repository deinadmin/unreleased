import SwiftUI

struct EmailPasswordAuthView: View {
    @Environment(AuthManager.self) private var auth

    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false
    @State private var didSendResetEmail = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email, password
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            AuthAppMark(size: 88, cornerRadius: 22)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 32)

            Text(isCreatingAccount ? "Create your account" : "Sign in with email")
                .font(AuthChrome.headlineFont)
                .padding(.bottom, 10)

            Text(isCreatingAccount
                 ? "Use email and a password to keep your projects synced."
                 : "Welcome back. Enter the email and password for your account.")
                .font(AuthChrome.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)

            VStack(spacing: 12) {
                authField(
                    placeholder: "Email",
                    text: $email,
                    contentType: .emailAddress,
                    keyboard: .emailAddress,
                    field: .email
                )

                authField(
                    placeholder: "Password",
                    text: $password,
                    contentType: isCreatingAccount ? .newPassword : .password,
                    keyboard: .default,
                    field: .password,
                    isSecure: true
                )
            }

            if !isCreatingAccount {
                Button {
                    Task { await sendPasswordReset() }
                } label: {
                    Text("Forgot password?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .disabled(auth.isLoading || !email.contains("@"))
            }

            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    isCreatingAccount.toggle()
                    auth.clearError()
                }
            } label: {
                Text(isCreatingAccount
                     ? "Already have an account? Sign in"
                     : "New here? Create an account")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, isCreatingAccount ? 20 : 12)

            Spacer(minLength: 24)

                AuthPrimaryButton(
                    title: isCreatingAccount ? "Create account" : "Sign in",
                    isEnabled: canSubmit,
                    isLoading: auth.isLoading
                ) {
                    Task { await submit() }
                }
            }
            .padding(.horizontal, AuthChrome.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .containerRelativeFrame(.vertical, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = nil
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AuthChrome.pageBackground.ignoresSafeArea())
        .toolbarVisibility(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .defaultFocus($focusedField, .email)
        .alert("Sign In", isPresented: errorBinding) {
            Button("OK") { auth.clearError() }
        } message: {
            Text(auth.errorMessage ?? "")
        }
        .alert("Check your inbox", isPresented: $didSendResetEmail) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We sent a password reset link to \(email).")
        }
    }

    @ViewBuilder
    private func authField(
        placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType?,
        keyboard: UIKeyboardType,
        field: Field,
        isSecure: Bool = false
    ) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .textContentType(contentType)
        .font(.system(size: 17, weight: .medium))
        .focused($focusedField, equals: field)
        .submitLabel(field == .email ? .next : .go)
        .onSubmit {
            if field == .email {
                focusedField = .password
            } else {
                Task { await submit() }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AuthChrome.controlHeight)
        .background(
            AuthChrome.elevatedFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AuthChrome.borderColor, lineWidth: 1)
        }
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6
    }

    private func submit() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCreatingAccount {
            await auth.createAccount(email: trimmedEmail, password: password)
        } else {
            await auth.signIn(email: trimmedEmail, password: password)
        }
    }

    private func sendPasswordReset() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await auth.sendPasswordReset(to: trimmedEmail) else { return }
        didSendResetEmail = true
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { auth.errorMessage != nil },
            set: { if !$0 { auth.clearError() } }
        )
    }
}

#Preview {
    NavigationStack {
        EmailPasswordAuthView()
    }
    .environment(AuthManager())
}
