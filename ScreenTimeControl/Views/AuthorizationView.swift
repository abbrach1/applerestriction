import SwiftUI

struct AuthorizationView: View {
    @EnvironmentObject var authManager: ActiveAuthorizationManager

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0, green: 0.3, blue: 0.1), Color(red: 0, green: 0.5, blue: 0.2)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 80))
                        .foregroundStyle(.white)

                    Text("AB Brachfeld")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Kosher iPhone Filter")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Protect this device with kosher content filtering and remote parental controls.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 16) {
                    Button {
                        Task { await authManager.requestAuthorization() }
                    } label: {
                        HStack {
                            Image(systemName: "iphone.badge.play")
                            Text("Set Up This Device")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white)
                        .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        Task { await authManager.requestParentAuthorization() }
                    } label: {
                        HStack {
                            Image(systemName: "person.2.fill")
                            Text("Set Up as Parent")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 32)

                if authManager.isRequesting {
                    ProgressView()
                        .tint(.white)
                }

                if let error = authManager.authorizationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal)
                }

                Spacer()

                Text("AB Brachfeld Kosher Filter · Powered by Apple Screen Time")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 8)
            }
        }
    }
}
