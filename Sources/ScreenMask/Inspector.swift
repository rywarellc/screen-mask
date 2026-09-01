import SwiftUI
import ScreenMaskKit

private enum StyleKind: String, CaseIterable, Identifiable {
    case pixelate = "Pixelate"
    case solid = "Solid"
    var id: String { rawValue }
}

struct Inspector: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Masks")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if model.regions.isEmpty {
                VStack(spacing: 6) {
                    Text("No masks yet")
                        .foregroundStyle(.secondary)
                    Text("Drag a rectangle on the video.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.regions) { region in
                        HStack(spacing: 8) {
                            Image(systemName: region.style == .solid ? "rectangle.fill" : "square.grid.3x3.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(region.name)
                                Text("\(timecode(region.start)) – \(timecode(region.end))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(region.id)
                    }
                }
                .listStyle(.inset)
            }

            if let region = model.selectedRegion {
                Divider()
                editor(for: region)
            }
        }
    }

    @ViewBuilder
    private func editor(for region: MaskRegion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                "Name",
                text: Binding(
                    get: { region.name },
                    set: { value in model.update(region.id) { $0.name = value } }
                )
            )
            .textFieldStyle(.roundedBorder)

            Picker(
                "Style",
                selection: Binding(
                    get: { region.style == .solid ? StyleKind.solid : .pixelate },
                    set: { kind in
                        model.update(region.id) {
                            $0.style = kind == .solid ? .solid : .pixelate(scale: 0.10)
                        }
                    }
                )
            ) {
                ForEach(StyleKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if case .pixelate(let scale) = region.style {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { scale },
                            set: { value in
                                model.update(region.id) { $0.style = .pixelate(scale: value) }
                            }
                        ),
                        in: 0.02...0.4
                    )
                }
                Text("Pixelation can leak short, predictable text. Use Solid for anything you publish.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Visible from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(timecode(region.start)) – \(timecode(region.end))")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                }
                HStack(spacing: 6) {
                    Button("Set In") {
                        model.update(region.id) { $0.start = min(model.currentTime, $0.end) }
                    }
                    Button("Set Out") {
                        model.update(region.id) { $0.end = max(model.currentTime, $0.start) }
                    }
                    Button("All") {
                        model.update(region.id) {
                            $0.start = 0
                            $0.end = model.duration
                        }
                    }
                }
                .controlSize(.small)
            }

            Divider()

            Button(role: .destructive) {
                model.delete(region.id)
            } label: {
                Label("Delete Mask", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(14)
    }
}

/// Region spans laid out against the whole timeline, so it's obvious which
/// parts of the video are covered and which are still exposed.
struct Timeline: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.duration, 0.01)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))

                ForEach(Array(model.regions.enumerated()), id: \.element.id) { index, region in
                    let x = (region.start / duration) * width
                    let w = max(((region.end - region.start) / duration) * width, 2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            model.selection == region.id
                                ? Color.accentColor.opacity(0.75)
                                : Color.accentColor.opacity(0.32)
                        )
                        .frame(width: w, height: 8)
                        .offset(x: x, y: CGFloat(index % 3) * 10 + 3)
                        .onTapGesture { model.selection = region.id }
                }

                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2)
                    .offset(x: (model.currentTime / duration) * width - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    model.seek(to: (value.location.x / width) * duration)
                }
            )
        }
    }
}
