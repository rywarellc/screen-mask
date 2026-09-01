import AVFoundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import ScreenMaskKit

let dropLog = Logger(subsystem: "local.screenmask", category: "drop")

struct ContentView: View {
    @State private var model = AppModel()
    @State private var isTargeted = false
    @FocusState private var stageFocused: Bool

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
            ToolbarItem(placement: .navigation) {
                Button("Close Video", systemImage: "xmark.circle") { model.closeVideo() }
                    .disabled(!model.hasVideo || model.isExporting)
                    .help("Close this video and start over. Its masks are kept.")
            }
            ToolbarItem {
                Button("Export…", systemImage: "square.and.arrow.up") { exportVideo() }
                    .disabled(!model.hasVideo || model.isExporting)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            receive(providers)
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
                        .pointerStyle(model.isPickingColor ? .rectSelection : nil)
                } else {
                    placeholder
                }

                if model.isPickingColor {
                    VStack {
                        HStack(spacing: 10) {
                            Image(systemName: "eyedropper")
                            Text("Click anywhere in the video to sample a colour")
                            Button("Cancel") { model.isPickingColor = false }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 18)
                        Spacer()
                    }
                    .allowsHitTesting(true)
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

    /// Accepts `.fileURL` only. A QuickTime movie doesn't conform to
    /// `public.video`, and matching on `public.movie` buys nothing over the file
    /// URL every Finder drag carries — so the narrow, always-present type is the
    /// reliable one to register for.
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(fileURLType)
        }) else {
            dropLog.error("drop rejected: no provider carried a file URL")
            model.errorMessage = "That doesn't look like a file this app can open."
            return false
        }

        dropLog.info("drop accepted: \(provider.registeredTypeIdentifiers, privacy: .public)")
        provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { data, error in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                dropLog.error("drop failed to decode a URL: \(String(describing: error), privacy: .public)")
                Task { @MainActor in
                    model.errorMessage = "Couldn't read the dropped file. Try Open Video… instead."
                }
                return
            }
            dropLog.info("drop resolved: \(url.path, privacy: .public)")
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
