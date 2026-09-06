import SwiftUI

struct OnboardingView: View {
    static let completedKey = "onboardingCompleted"

    @AppStorage(completedKey) private var onboardingCompleted = false
    @State private var selectedPage = 0

    private let onComplete: () -> Void
    private let pages = OnboardingPage.all

    init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: completeOnboarding)
                    .font(.body.weight(.semibold))
                    .accessibilityHint("Closes onboarding")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            TabView(selection: $selectedPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page, isActive: selectedPage == index)
                        .tag(index)
                        .padding(.horizontal, 28)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .animation(.easeInOut(duration: 0.25), value: selectedPage)

            Button(action: advance) {
                Text(selectedPage == pages.count - 1 ? "Get Started" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
        .interactiveDismissDisabled()
    }

    private func advance() {
        if selectedPage == pages.count - 1 {
            completeOnboarding()
        } else {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedPage += 1
            }
        }
    }

    private func completeOnboarding() {
        Haptics.success()
        onboardingCompleted = true
        onComplete()
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let isActive: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.13))
                    .frame(width: 156, height: 156)
                Circle()
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    .frame(width: 184, height: 184)
                Image(systemName: page.symbol)
                    .font(.system(size: 64, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }
            .scaleEffect(isActive ? 1 : 0.92)
            .opacity(isActive ? 1 : 0.65)
            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: isActive)
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(page.message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 54)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingPage {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String

    static let all: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to OfflineTube",
            message: "Your personal offline media player for music and videos you want to keep close.",
            symbol: "play.rectangle.on.rectangle.fill"
        ),
        OnboardingPage(
            title: "Download",
            message: "Paste a URL, choose an audio or video format, then download it for offline use.",
            symbol: "arrow.down.circle.fill"
        ),
        OnboardingPage(
            title: "Offline Player",
            message: "Enjoy your Library without a connection, keep playing in the background, and organize media into playlists.",
            symbol: "headphones.circle.fill"
        ),
        OnboardingPage(
            title: "Storage & Privacy",
            message: "Your media and app data stay on this device. Review usage or remove downloads anytime in Manage Storage.",
            symbol: "lock.iphone"
        )
    ]
}
