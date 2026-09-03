import SwiftUI
import SwiftData

struct DownloadView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var viewModel = DownloadViewModel()
    @FocusState private var isURLFieldFocused: Bool
    @State private var showScheduler = false
    @State private var scheduledAt = Date().addingTimeInterval(3600)
    @State private var scheduledWiFiOnly = true
    @State private var scheduledChargingOnly = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    TextField("Dán link YouTube", text: $viewModel.urlText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isURLFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { fetchInfo() }
                    Button("Lấy info") { fetchInfo() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isLoadingInfo || viewModel.isDownloading)
                }

                if viewModel.isLoadingInfo { ProgressView("Đang đọc metadata…") }
                if let info = viewModel.mediaInfo { metadataCard(info) }

                if viewModel.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: viewModel.progress)
                        Text(viewModel.statusText).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message = viewModel.completedMessage {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("OfflineTube")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Xong") { isURLFieldFocused = false }
            }
        }
        .confirmationDialog(
            "Possible duplicate found",
            isPresented: $viewModel.showDuplicateWarning,
            titleVisibility: .visible
        ) {
            if let existing = viewModel.duplicateMatches.first {
                Button("Play Existing") { player.play(existing) }
            }
            Button("Download Anyway") { viewModel.downloadAnyway(modelContext: modelContext) }
            Button("Replace Existing", role: .destructive) { viewModel.replaceExisting(modelContext: modelContext) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let existing = viewModel.duplicateMatches.first {
                Text("“\(existing.title)” already exists (\(existing.quality), \(existing.fileSize.formattedBytes)). Replace deletes the selected existing copy only after the new download is saved.")
            }
        }
        .sheet(isPresented: $showScheduler) {
            NavigationStack {
                Form {
                    Section("Download Later") {
                        DatePicker("Start after", selection: $scheduledAt, in: Date()...)
                        Toggle("Wi‑Fi Only", isOn: $scheduledWiFiOnly)
                        Toggle("Only When Charging", isOn: $scheduledChargingOnly)
                    }
                    Section {
                        Text("iOS may suspend the app. The item remains queued and starts the next time the app gets execution time and all selected conditions are met.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Schedule Download").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScheduler = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            showScheduler = false
                            Task { await viewModel.download(modelContext: modelContext, scheduledAt: scheduledAt,
                                wifiOnly: scheduledWiFiOnly, chargingOnly: scheduledChargingOnly, ignoreWindow: false) }
                        }
                    }
                }
            }
        }
    }

    private func fetchInfo() {
        isURLFieldFocused = false
        Task { await viewModel.fetchInfo() }
    }

    @ViewBuilder
    private func metadataCard(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AsyncImage(url: info.thumbnail.flatMap(URL.init(string:))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay { Image(systemName: "play.rectangle") } }
            }
            .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 14))

            Text(info.title).font(.headline)
            Text("\(info.channel) • \(formatDuration(info.duration))").font(.subheadline).foregroundStyle(.secondary)

            Picker("Loại", selection: $viewModel.mediaKind) {
                ForEach(DownloadViewModel.MediaKind.allCases) { kind in Text(kind.title).tag(kind) }
            }.pickerStyle(.segmented)

            Picker("Chất lượng", selection: $viewModel.quality) {
                ForEach(viewModel.mediaKind == .audio ? viewModel.audioQualities : viewModel.videoQualities, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }.pickerStyle(.menu)

            Menu {
                Button { startDownload(ignoreWindow: true) } label: { Label("Download Now", systemImage: "bolt.fill") }
                Button { startDownload(ignoreWindow: false) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                Button { scheduledAt = Date().addingTimeInterval(3600); showScheduler = true } label: { Label("Download Later", systemImage: "calendar.badge.clock") }
            } label: {
                Label("Download Options", systemImage: viewModel.mediaKind == .audio ? "waveform" : "video").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isDownloading)
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func startDownload(ignoreWindow: Bool) {
        isURLFieldFocused = false
        Task { await viewModel.download(modelContext: modelContext, ignoreWindow: ignoreWindow) }
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
