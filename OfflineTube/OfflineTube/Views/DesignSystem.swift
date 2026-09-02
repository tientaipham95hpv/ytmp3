import SwiftUI
import UIKit

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
    var isVideo = false
    var cornerRadius: CGFloat = 12

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                ZStack {
                    image.resizable().scaledToFill().blur(radius: 20).opacity(0.38)
                    Rectangle().fill(.black.opacity(0.08))
                    image.resizable().scaledToFit().padding(2)
                }
            case .failure: placeholder
            case .empty: placeholder.overlay { ProgressView().controlSize(.small) }
            @unknown default: placeholder
            }
        }
        .background(Color.secondary.opacity(0.08))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(colors: [.accentColor.opacity(0.35), .secondary.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay { Image(systemName: isVideo ? "play.rectangle.fill" : "music.note").font(.title).foregroundStyle(.white.opacity(0.8)) }
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
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
