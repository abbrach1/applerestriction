import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: FirebaseAuthService

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    enum Field { case email, password }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0, green: 0.25, blue: 0.1), Color(red: 0, green: 0.45, blue: 0.2)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo + Title
                VStack(spacing: 12) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 72))
                        .foregroundStyle(.white)

                    Text("B-SAFE")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Kosher Internet Filter")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.85))
                }

                // Login Card
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(.gray)
                                .frame(width: 20)
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.gray)
                                .frame(width: 20)
                            SecureField("Password", text: $password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { Task { await signIn() } }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let error = auth.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red.mix(with: .white, by: 0.3))
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await signIn() }
                    } label: {
                        Group {
                            if auth.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Sign In")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white)
                        .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 24)

                Spacer()

                Text("Contact your administrator to get access")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 8)
            }
        }
    }

    private func signIn() async {
        focusedField = nil
        await auth.signIn(email: email, password: password)
    }
}
