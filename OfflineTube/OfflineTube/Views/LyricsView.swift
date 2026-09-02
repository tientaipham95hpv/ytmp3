import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Bindable var item: MediaItem
    @AppStorage("lyricsProviderURL") private var providerURL = ""
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var isSearching = false
    @State private var errorMessage: String?

    private var lines: [LyricLine] { LRCParser.parse(item.lyricsText ?? "") }
    private var currentLineID: Int? { lines.last(where: { $0.time <= player.currentTime + 0.08 })?.id }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Lyrics", systemImage: "quote.bubble.fill").font(.headline)
                Spacer()
                if isSearching { ProgressView().controlSize(.small) }
                Menu {
                    Button { showImporter = true } label: { Label("Import .lrc from Files", systemImage: "folder") }
                    Button { showPaste = true } label: { Label("Paste Lyrics", systemImage: "doc.on.clipboard") }
                    if !providerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { search() } label: { Label("Find Lyrics", systemImage: "magnifyingglass") }
                    }
                    if item.lyricsText != nil {
                        Button(role: .destructive) { save(nil) } label: { Label("Remove Lyrics", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .accessibilityLabel("Lyrics Options")
            }
            if let value = item.lyricsText, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if lines.isEmpty { plainLyrics(value) } else { timedLyrics(lines) }
            } else {
                AppStateView(title: "No Lyrics", message: "Import an LRC file, paste lyrics, or configure a provider in Settings.", icon: "quote.bubble", actionTitle: "Paste Lyrics") { showPaste = true }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importLyrics(url)
        }
        .sheet(isPresented: $showPaste) { LyricsPasteView(initialText: item.lyricsText ?? "") { save($0) } }
    }

    private func plainLyrics(_ value: String) -> some View {
        ScrollView {
            Text(value).font(.title3.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(8).textSelection(.enabled).padding(.vertical, 8)
        }.frame(minHeight: 300)
    }

    private func timedLyrics(_ lines: [LyricLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lines) { line in
                        Button { player.seek(to: line.time) } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(line.id == currentLineID ? .title2.bold() : .title3.weight(.semibold))
                                .foregroundStyle(line.id == currentLineID ? Color.primary : .secondary)
                                .opacity(line.id == currentLineID ? 1 : 0.58)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(.easeInOut(duration: 0.2), value: currentLineID)
                        }.buttonStyle(.plain).id(line.id)
                    }
                    Color.clear.frame(height: 160)
                }.padding(.vertical, 120)
            }
            .frame(minHeight: 360)
            .onChange(of: currentLineID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func importLyrics(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
            save(value); Haptics.success()
        } catch { errorMessage = error.localizedDescription }
    }

    private func search() {
        isSearching = true; errorMessage = nil
        Task {
            defer { isSearching = false }
            do { save(try await LyricsService.shared.fetch(title: item.title, channel: item.channel)); Haptics.success() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func save(_ value: String?) {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.lyricsText = cleaned?.isEmpty == false ? cleaned : nil
        item.lyricsFormat = item.lyricsText.map { LRCParser.isTimed($0) ? "lrc" : "plain" }
        item.lyricsUpdatedAt = item.lyricsText == nil ? nil : Date()
        try? modelContext.save()
        showPaste = false; errorMessage = nil
    }
}

private struct LyricsPasteView: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText); self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text).font(.body).padding(12).navigationTitle("Paste Lyrics").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(text); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}
