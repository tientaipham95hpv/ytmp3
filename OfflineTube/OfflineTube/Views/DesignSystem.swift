import SwiftUI
import UIKit

enum AppMetrics {
    static let page: CGFloat = 18
    static let section: CGFloat = 24
    static let card: CGFloat = 18
    static let compactCard: CGFloat = 12
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case vietnamese = "vi"
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .english ? "English" : "Vietnamese" }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case pink, red, orange, blue, purple, green
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .pink: "Pink"; case .red: "Red"; case .orange: "Orange"; case .blue: "Blue"; case .purple: "Purple"; case .green: "Green" }
    }
    var color: Color {
        switch self {
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        }
    }
}

struct ArtworkView: View {
    let url: String?
    var localURL: URL? = nil
    var isVideo = false
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let localURL, let image = UIImage(contentsOfFile: localURL.path) {
                artwork(Image(uiImage: image))
            } else {
                AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                artwork(image)
            case .failure: placeholder
            case .empty: placeholder.overlay { ProgressView().controlSize(.small) }
            @unknown default: placeholder
            }
                }
            }
        }
        .background(Color.secondary.opacity(0.08))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isVideo ? "Video artwork" : "Audio artwork")
    }

    private func artwork(_ image: Image) -> some View {
        ZStack {
            image.resizable().scaledToFill().blur(radius: 20).opacity(0.38)
            Rectangle().fill(.black.opacity(0.08))
            image.resizable().scaledToFit().padding(2)
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: [.accentColor.opacity(0.42), .secondary.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                ZStack {
                    Circle().fill(.ultraThinMaterial).frame(width: 54, height: 54)
                    Image(systemName: isVideo ? "play.rectangle.fill" : "music.note")
                        .font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
    }
}

struct AppStateView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let icon: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 72, height: 72).background(.tint.opacity(0.12), in: Circle())
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

struct SkeletonRow: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: AppMetrics.compactCard).fill(.quaternary).frame(width: 76, height: 54)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(maxWidth: 220).frame(height: 14)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(maxWidth: 130).frame(height: 11)
            }
        }
        .opacity(pulse ? 0.45 : 0.85)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.title2.bold())
            Spacer()
            if let action { Button("See All", action: action).font(.subheadline.weight(.semibold)) }
        }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Double {
    var mediaTime: String {
        let total = max(0, Int(isFinite ? self : 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    var remainingTime: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, self)) ?? "—"
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
