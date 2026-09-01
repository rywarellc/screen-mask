import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import ScreenMaskKit

struct ContentView: View {
    @State private var model = AppModel()
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            stage
            Divider()
            Inspector(model: model)
                .frame(width: 280)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open Video…", systemImage: "folder") { openVideo() }
            }
            ToolbarItem {
                Button("Export…", systemImage: "square.and.arrow.up") { exportVideo() }
                    .disabled(!model.hasVideo || model.isExporting)
            }
        }
        .onDrop(of: [.movie, .video, .fileURL], isTargeted: $isTargeted) { providers in
            load(from: providers)
        }
        .overlay {
            if model.isExporting { exportOverlay }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if model.hasVideo {
                    PlayerView(player: model.player)
                        .aspectRatio(model.aspectRatio, contentMode: .fit)
                        .overlay {
                            // Aspect-locked above, so this overlay is exactly the
                            // video rect and normalizing is a plain divide.
                            GeometryReader { geo in
                                RegionOverlay(model: model, size: geo.size)
                            }
                        }
                        .padding(12)
                } else {
                    placeholder
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                }
            }

            if model.hasVideo {
                Divider()
                transport
                Timeline(model: model)
                    .frame(height: 34)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Drop a video here")
                .font(.title3)
            Text("Then drag rectangles over anything you want hidden.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Video…") { openVideo() }
                .padding(.top, 4)
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])

            Text(timecode(model.currentTime))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.01)
            )

            Text(timecode(model.duration))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: model.exportProgress)
                    .frame(width: 220)
                Text("Exporting… \(Int(model.exportProgress * 100))%")
                    .font(.callout)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - File handling

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.open(url) }
    }

    private func load(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in await model.open(url) }
        }
        return true
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        let stem = model.url?.deletingPathExtension().lastPathComponent ?? "video"
        panel.nameFieldStringValue = "\(stem)-masked.mov"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await model.export(to: destination) }
    }
}
