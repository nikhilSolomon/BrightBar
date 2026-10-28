import SwiftUI

struct BrightnessView: View {
    @EnvironmentObject private var manager: DisplayManager
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderRow()
            if manager.displays.isEmpty {
                EmptyState()
            } else {
                if manager.displays.count > 1 {
                    AllDisplaysRow()
                    Divider()
                }
                ForEach(Array(manager.displays.enumerated()), id: \.element.id) { index, display in
                    DisplayRow(display: display)
                    if index < manager.displays.count - 1 { Divider() }
                }
            }
            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            FooterSection(onQuit: onQuit)
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct HeaderRow: View {
    @EnvironmentObject private var manager: DisplayManager

    var body: some View {
        HStack {
            SectionTitle(text: "Displays")
            Spacer()
            Button {
                manager.refresh()
            } label: {
                if manager.isRefreshing {
                    ProgressView().controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.borderless)
            .help("Re-read the monitors' current settings")
            .disabled(manager.isRefreshing)
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(manager.isRefreshing ? "Looking for displays…" : "No adjustable external displays")
                .font(.system(size: 12, weight: .medium))
            Text("Connect a monitor over HDMI, DisplayPort or USB‑C and make sure DDC/CI is turned on in its on‑screen menu. Some docks and hubs block DDC.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

/// One slider that moves every display together.
private struct AllDisplaysRow: View {
    @EnvironmentObject private var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("All displays")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                PercentLabel(fraction: manager.averageBrightnessFraction)
            }
            LevelSlider(
                value: manager.averageBrightnessFraction,
                onChange: { manager.setBrightnessForAll(fraction: $0) },
                onCommit: { manager.setBrightnessForAll(fraction: $0); manager.commit() },
                lowIcon: "sun.min", highIcon: "sun.max"
            )
        }
    }
}

private struct DisplayRow: View {
    @EnvironmentObject private var manager: DisplayManager
    let display: ControlledDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: display.kind == .builtin ? "laptopcomputer" : "display")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                PercentLabel(fraction: display.brightnessFraction)
            }
            LevelSlider(
                value: display.brightnessFraction,
                onChange: { manager.setBrightness(Int(($0 * Double(display.maxBrightness)).rounded()), for: display.id) },
                onCommit: { manager.setBrightness(Int(($0 * Double(display.maxBrightness)).rounded()), for: display.id); manager.commit() },
                lowIcon: "sun.min", highIcon: "sun.max"
            )
            if let contrast = display.contrast {
                LevelSlider(
                    value: Double(contrast) / Double(display.maxContrast),
                    onChange: { manager.setContrast(Int(($0 * Double(display.maxContrast)).rounded()), for: display.id) },
                    onCommit: { manager.setContrast(Int(($0 * Double(display.maxContrast)).rounded()), for: display.id); manager.commit() },
                    lowIcon: "circle.lefthalf.filled", highIcon: "circle.lefthalf.filled",
                    trailingText: "\(contrast)"
                )
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Contrast")
            }
        }
    }
}

/// A slider that owns its position while being dragged. The model value is only pulled in when
/// the user is not touching it, and changes are only pushed out while they are. Without this,
/// SwiftUI's macOS slider writes externally-changed values back through its binding, so a slider
/// bound to a derived value (the "All displays" average) would fire its setter whenever a
/// different slider moved.
private struct LevelSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void
    var lowIcon: String
    var highIcon: String
    var trailingText: String? = nil

    @State private var local: Double
    @State private var isEditing = false

    init(value: Double, onChange: @escaping (Double) -> Void, onCommit: @escaping (Double) -> Void,
         lowIcon: String, highIcon: String, trailingText: String? = nil) {
        self.value = value
        self.onChange = onChange
        self.onCommit = onCommit
        self.lowIcon = lowIcon
        self.highIcon = highIcon
        self.trailingText = trailingText
        _local = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lowIcon)
                .font(.system(size: 11))
                .frame(width: 16)
            Slider(value: $local, in: 0...1) { editing in
                isEditing = editing
                if !editing { onCommit(local) }
            }
            Image(systemName: highIcon)
                .font(.system(size: 13))
                .frame(width: 16)
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .onChange(of: local) { _, newValue in
            if isEditing { onChange(newValue) }
        }
        .onChange(of: value) { _, newValue in
            if !isEditing, local != newValue { local = newValue }
        }
    }
}

private struct PercentLabel: View {
    let fraction: Double
    var body: some View {
        Text("\(Int((fraction * 100).rounded()))%")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }
}

private struct FooterSection: View {
    var onQuit: () -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { _, newValue in LaunchAtLogin.set(newValue) }
            Spacer()
            HStack(spacing: 4) {
                Text("Toggle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(HotKey.displayString)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            }
            Button("Quit", action: onQuit)
                .font(.system(size: 11))
                .buttonStyle(.borderless)
        }
    }
}
