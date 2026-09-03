import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MetadataEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Bindable var item: MediaItem

    @State private var title: String
    @State private var artist: String
    @State private var notes: String
    @State private var photoItem: PhotosPickerItem?
    @State private var artworkData: Data?
    @State private var resetArtwork = false
    @State private var showFileImporter = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(item: MediaItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _artist = State(initialValue: item.channel)
        _notes = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            editorForm
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave || isSaving)
                }
            }
            .overlay { if isSaving { ProgressView().padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
        .onChange(of: photoItem) { _, value in loadPhoto(value) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in loadFile(result) }
        .alert("Couldn’t update metadata", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var editorForm: some View {
        Form {
            metadataSection
            artworkSection
            notesSection
        }
    }

    private var metadataSection: some View {
        Section("Metadata") {
            TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
            TextField("Artist / Channel", text: $artist, axis: .vertical).lineLimit(1...3)
        }
    }

    private var artworkSection: some View {
        Section("Artwork") {
            artworkPreview.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            Button { showFileImporter = true } label: {
                Label("Choose from Files", systemImage: "folder")
            }
            Button {
                artworkData = nil
                resetArtwork = true
            } label: {
                Label("Reset to Original Artwork", systemImage: "arrow.counterclockwise")
            }
            .disabled(item.customArtworkFilename == nil && artworkData == nil)
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $notes).frame(minHeight: 110)
        } header: {
            Text("Notes")
        } footer: {
            Text("Changes apply only to your local Library and never modify the online source.")
        }
    }

    @ViewBuilder private var artworkPreview: some View {
        if let artworkData, let image = UIImage(data: artworkData) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxHeight: 230).clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            ArtworkView(
                url: item.thumbnailURL,
                localURL: resetArtwork ? item.originalArtworkURL : item.artworkURL,
                isVideo: item.isVideo,
                cornerRadius: 18
            ).frame(width: 230, height: 170)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadPhoto(_ value: PhotosPickerItem?) {
        guard let value else { return }
        Task {
            do {
                guard let data = try await value.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard data.count <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                artworkData = data
                resetArtwork = false
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadFile(_ result: Result<URL, Error>) {
        Task {
            do {
                artworkData = try await FileStore.loadArtworkData(from: result.get())
                resetArtwork = false
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                if resetArtwork {
                    try FileStore.removeCustomArtwork(item)
                } else if let artworkData {
                    let filename = try await FileStore.saveCustomArtwork(data: artworkData, itemID: item.id)
                    try FileStore.removeCustomArtwork(item)
                    item.customArtworkFilename = filename
                }
                item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                item.channel = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                item.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                CloudSyncService.markChanged(item)
                try modelContext.save()
                player.metadataDidChange(for: item)
                Haptics.success()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

struct BatchMetadataEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    let items: [MediaItem]

    @State private var selection = Set<UUID>()
    @State private var replaceArtist = false
    @State private var artist = ""
    @State private var replaceNotes = false
    @State private var notes = ""
    @State private var replaceArtwork = false
    @State private var resetArtwork = false
    @State private var artworkData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            batchForm
            .navigationTitle("Batch Edit Metadata").navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(!canApply || isSaving)
                }
            }
            .overlay { if isSaving { ProgressView().padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
        .onChange(of: photoItem) { _, value in loadPhoto(value) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in loadFile(result) }
        .alert("Couldn’t update metadata", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var batchForm: some View {
        Form {
            selectionSection
            changesSection
        }
    }

    private var selectionSection: some View {
        Section {
            Button(selection.count == items.count ? "Deselect All" : "Select All") {
                selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
            ForEach(items) { item in selectionRow(item) }
        } header: {
            Text("Selected: \(selection.count)")
        }
    }

    private func selectionRow(_ item: MediaItem) -> some View {
        Button { toggle(item.id) } label: {
            HStack {
                ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo)
                    .frame(width: 54, height: 40)
                VStack(alignment: .leading) {
                    Text(item.title).lineLimit(1)
                    Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
            }
        }.buttonStyle(.plain)
    }

    private var changesSection: some View {
        Section {
            Toggle("Replace Artist / Channel", isOn: $replaceArtist)
            if replaceArtist { TextField("Artist / Channel", text: $artist) }
            Toggle("Replace Notes", isOn: $replaceNotes)
            if replaceNotes { TextEditor(text: $notes).frame(minHeight: 80) }
            Toggle("Replace Artwork", isOn: $replaceArtwork)
            if replaceArtwork { artworkChanges }
        } header: {
            Text("Batch Changes")
        } footer: {
            Text("Batch title editing is intentionally unavailable because each media item needs its own title.")
        }
    }

    private var artworkChanges: some View {
        Group {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            Button { showFileImporter = true } label: {
                Label("Choose from Files", systemImage: "folder")
            }
            Toggle("Reset to Original Artwork", isOn: $resetArtwork)
        }
    }

    private var canApply: Bool {
        guard !selection.isEmpty else { return false }
        let validArtist = replaceArtist && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validNotes = replaceNotes
        let validArtwork = replaceArtwork && (resetArtwork || artworkData != nil)
        return validArtist || validNotes || validArtwork
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func loadPhoto(_ value: PhotosPickerItem?) {
        guard let value else { return }
        Task {
            do {
                guard let data = try await value.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                guard data.count <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                artworkData = data; resetArtwork = false
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func loadFile(_ result: Result<URL, Error>) {
        Task {
            do {
                artworkData = try await FileStore.loadArtworkData(from: result.get())
                resetArtwork = false
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply() {
        isSaving = true
        let selectedItems = items.filter { selection.contains($0.id) }
        Task {
            do {
                for item in selectedItems {
                    if replaceArtist { item.channel = artist.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if replaceNotes {
                        let value = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.notes = value.isEmpty ? nil : value
                    }
                    if replaceArtwork {
                        if resetArtwork {
                            try FileStore.removeCustomArtwork(item)
                        } else if let artworkData {
                            let filename = try await FileStore.saveCustomArtwork(data: artworkData, itemID: item.id)
                            try FileStore.removeCustomArtwork(item)
                            item.customArtworkFilename = filename
                        }
                    }
                    CloudSyncService.markChanged(item)
                    player.metadataDidChange(for: item)
                }
                try modelContext.save()
                Haptics.success(); dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
