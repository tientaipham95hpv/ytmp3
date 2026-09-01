import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var showPlayer = false
    @State private var showSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                DownloadView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        }
                    }
            }
            .tabItem { Label("Download", systemImage: "arrow.down.circle") }

            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentItem != nil {
                MiniPlayerView { showPlayer = true }
            }
        }
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("backendURL") private var backendURL = "http://127.0.0.1:8000"

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("https://api.example.com", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Trên iPhone thật, dùng địa chỉ HTTPS hoặc IP LAN của máy chạy backend; 127.0.0.1 chỉ phù hợp khi API ở cùng thiết bị/môi trường mô phỏng.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cài đặt")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}
