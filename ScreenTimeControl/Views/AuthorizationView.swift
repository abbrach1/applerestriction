import SwiftUI

struct AuthorizationView: View {
    @EnvironmentObject var authManager: AuthorizationManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "hourglass.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            VStack(spacing: 12) {
                Text("Screen Time Control")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Remotely manage Screen Time settings on this device. Authorization is required to control app restrictions and schedules.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 16) {
                Button {
                    Task { await authManager.requestAuthorization() }
                } label: {
                    HStack {
                        Image(systemName: "person.fill")
                        Text("Set Up for This Device")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    Task { await authManager.requestParentAuthorization() }
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                        Text("Set Up as Parent")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 32)

            if authManager.isRequesting {
                ProgressView("Requesting authorization...")
            }

            if let error = authManager.authorizationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }
}
