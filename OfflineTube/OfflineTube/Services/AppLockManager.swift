import Foundation
import Combine
import LocalAuthentication

@MainActor
final class AppLockManager: ObservableObject {
    enum LockDelay: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .immediately: "Lock Immediately"
            case .oneMinute: "After 1 minute"
            case .fiveMinutes: "After 5 minutes"
            }
        }
    }

    private enum Keys {
        static let enabled = "appLockEnabled"
        static let delay = "appLockDelay"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var lockDelay: LockDelay
    @Published private(set) var isLocked: Bool
    @Published private(set) var isPrivacyShieldVisible = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var biometryDisplayName = "Face ID / Touch ID"
    @Published var errorMessage: String?

    private var leftActiveAt: Date?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Keys.enabled)
        isEnabled = enabled
        lockDelay = LockDelay(rawValue: defaults.integer(forKey: Keys.delay)) ?? .immediately
        isLocked = enabled
        refreshBiometryType()
    }

    func refreshBiometryType() {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: biometryDisplayName = "Face ID"
        case .touchID: biometryDisplayName = "Touch ID"
        case .opticID: biometryDisplayName = "Optic ID"
        case .none: biometryDisplayName = "Face ID / Touch ID"
        @unknown default: biometryDisplayName = "Biometrics"
        }
    }

    func requestEnable() {
        guard !isEnabled, !isAuthenticating else { return }
        authenticate(reason: "Authenticate to enable App Lock") { [weak self] success in
            guard let self, success else { return }
            self.isEnabled = true
            self.isLocked = false
            self.defaults.set(true, forKey: Keys.enabled)
        }
    }

    func disable() {
        isEnabled = false
        isLocked = false
        isPrivacyShieldVisible = false
        leftActiveAt = nil
        errorMessage = nil
        defaults.set(false, forKey: Keys.enabled)
    }

    func setLockDelay(_ delay: LockDelay) {
        lockDelay = delay
        defaults.set(delay.rawValue, forKey: Keys.delay)
    }

    func sceneDidBecomeInactive(at date: Date = Date()) {
        guard isEnabled, !isAuthenticating else { return }
        if leftActiveAt == nil { leftActiveAt = date }
        isPrivacyShieldVisible = true
        if lockDelay == .immediately { isLocked = true }
    }

    func sceneDidEnterBackground(at date: Date = Date()) {
        guard isEnabled, !isAuthenticating else { return }
        if leftActiveAt == nil { leftActiveAt = date }
        isPrivacyShieldVisible = true
    }

    func sceneDidBecomeActive(at date: Date = Date()) {
        defer {
            leftActiveAt = nil
            isPrivacyShieldVisible = false
        }
        guard isEnabled else {
            isLocked = false
            return
        }
        guard !isLocked, let leftActiveAt else { return }
        if date.timeIntervalSince(leftActiveAt) >= TimeInterval(lockDelay.rawValue) {
            isLocked = true
        }
    }

    func unlock() {
        guard isEnabled, isLocked, !isAuthenticating else { return }
        authenticate(
            policy: .deviceOwnerAuthentication,
            reason: "Unlock OfflineTube"
        ) { [weak self] success in
            if success { self?.isLocked = false }
        }
    }

    private func authenticate(
        policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics,
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var policyError: NSError?

        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            refreshBiometryType()
            errorMessage = message(for: policyError)
            completion(false)
            return
        }

        refreshBiometryType()
        errorMessage = nil
        isAuthenticating = true
        context.evaluatePolicy(policy, localizedReason: reason) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.errorMessage = nil
                } else {
                    self.errorMessage = self.message(for: error as NSError?)
                }
                completion(success)
            }
        }
    }

    private func message(for error: NSError?) -> String {
        guard let error else { return "Biometric authentication is unavailable. Check Face ID or Touch ID in Settings." }
        guard error.domain == LAError.errorDomain, let code = LAError.Code(rawValue: error.code) else {
            return "Authentication failed. Please try again."
        }
        switch code {
        case .biometryNotAvailable:
            return "Face ID or Touch ID is not available on this device."
        case .biometryNotEnrolled:
            return "Set up Face ID or Touch ID in Settings before enabling App Lock."
        case .biometryLockout:
            return "Biometric authentication is locked. Unlock your device, then try again."
        case .userCancel, .systemCancel, .appCancel:
            return "Authentication was cancelled."
        default:
            return "Authentication failed. Please try again."
        }
    }
}
