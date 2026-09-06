import SwiftUI

struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockManager
    let showsUnlockControls: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("OfflineTube Locked")
                    .font(.title2.bold())
                if showsUnlockControls {
                    Text("Authenticate with \(appLock.biometryDisplayName) to access your Library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        appLock.unlock()
                    } label: {
                        if appLock.isAuthenticating {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Unlock", systemImage: "faceid").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appLock.isAuthenticating)
                    if let error = appLock.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 420)
        }
        .accessibilityAddTraits(.isModal)
    }
}
