import SwiftUI
import SwiftData

struct DownloadView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = DownloadViewModel()
    @FocusState private var isURLFieldFocused: Bool

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

            Button {
                isURLFieldFocused = false
                Task { await viewModel.download(modelContext: modelContext) }
            } label: {
                Label("Tải xuống", systemImage: viewModel.mediaKind == .audio ? "waveform" : "video")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isDownloading)
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
