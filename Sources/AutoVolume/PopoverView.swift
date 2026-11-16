import SwiftUI
import AppKit

private enum Palette {
    static let indigo = Color(red: 0.40, green: 0.36, blue: 0.98)
    static let teal = Color(red: 0.13, green: 0.80, blue: 0.82)
    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            header
            graphCard
            statTiles
            if model.noAudioWarning { permissionCard }
            modePicker
            footer
        }
        .padding(16)
        .frame(width: 348)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Palette.gradient)
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Palette.indigo.opacity(0.35), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Auto Volume").font(.system(size: 15, weight: .semibold))
                statusLine
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.teal)
                .controlSize(.large)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let error = model.errorText {
            Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
        } else if model.isOn {
            HStack(spacing: 5) {
                Circle().fill(model.isSilent ? Color.gray : Palette.teal).frame(width: 6, height: 6)
                Text(model.isSilent ? "Listening…" : "Leveling · \(model.deviceName)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text("Off · sound plays normally").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Graph

    private var graphCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 30 seconds").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                legendDot(.secondary.opacity(0.7), "Original")
                legendDot(Palette.teal, "Leveled")
            }
            ZStack {
                LevelGraph(input: model.inHistory, output: model.outHistory)
                if !model.isOn || model.inHistory.isEmpty {
                    Text(model.isOn ? "Play something to see it work" : "Turn on to start leveling")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 92)
        }
        .padding(12)
        .card()
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: Stats

    private var statTiles: some View {
        HStack(spacing: 10) {
            tile(title: "Adjustment", value: gainText, caption: gainCaption, tint: gainTint)
            tile(title: "Level", value: model.isSilent ? "—" : String(format: "%.0f dB", model.outputDb),
                 caption: model.isSilent ? "no sound" : "was \(String(format: "%.0f", model.inputDb)) dB", tint: .primary)
        }
    }

    private var gainText: String {
        guard model.isOn, !model.isSilent else { return "—" }
        let g = model.gainDb
        return abs(g) < 0.5 ? "0 dB" : String(format: "%+.0f dB", g)
    }

    private var gainCaption: String {
        guard model.isOn, !model.isSilent else { return model.isOn ? "waiting for sound" : "paused" }
        if model.gainDb > 1.5 { return "boosting quiet parts" }
        if model.gainDb < -1.5 { return "calming loud parts" }
        return "already balanced"
    }

    private var gainTint: Color {
        guard model.isOn, !model.isSilent else { return .primary }
        return model.gainDb > 1.5 ? Palette.teal : (model.gainDb < -1.5 ? Palette.indigo : .primary)
    }

    private func tile(title: String, value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card()
    }

    // MARK: Permission

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No sound is reaching Auto Volume", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            Text("If something is playing, allow Auto Volume to capture system audio, then turn it off and on again.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                Button("Turn Off") { model.setOn(false) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Modes

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(LevelMode.allCases) { mode in
                    modeButton(mode)
                }
            }
            Text(model.mode.blurb)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modeButton(_ mode: LevelMode) -> some View {
        let selected = model.mode == mode
        return Button { withAnimation(.easeOut(duration: 0.15)) { model.setMode(mode) } } label: {
            HStack(spacing: 7) {
                Image(systemName: mode.symbol).font(.system(size: 12, weight: .medium))
                Text(mode.title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.6)
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Spacer()
                Toggle("Show in menu bar", isOn: Binding(get: { model.showGainInMenuBar }, set: { model.setShowGain($0) }))
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .controlSize(.small)
            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Auto Volume") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
        }
    }
}

private extension View {
    func card() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055))
        )
    }
}

/// Smooth two-line level graph: original (grey) vs leveled (gradient + fill).
struct LevelGraph: View {
    let input: [Float]
    let output: [Float]

    private let lo: Float = -60
    private let hi: Float = -6

    var body: some View {
        Canvas { ctx, size in
            // Reference line at the target level.
            let targetY = y(-23, size.height)
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: targetY))
            grid.addLine(to: CGPoint(x: size.width, y: targetY))
            ctx.stroke(grid, with: .color(Palette.teal.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            guard output.count > 1 else { return }

            let inPath = curve(input, size)
            ctx.stroke(inPath, with: .color(.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            let outPath = curve(output, size)
            var fill = outPath
            let lastX = x(output.count - 1, size.width)
            let firstX = x(0, size.width)
            fill.addLine(to: CGPoint(x: lastX, y: size.height))
            fill.addLine(to: CGPoint(x: firstX, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Palette.teal.opacity(0.30), Palette.teal.opacity(0.0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(outPath, with: .linearGradient(
                Gradient(colors: [Palette.indigo, Palette.teal]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }

    private func x(_ i: Int, _ width: CGFloat) -> CGFloat {
        let step = width / CGFloat(AppModel.historyLength - 1)
        return width - CGFloat(output.count - 1 - i) * step
    }

    private func y(_ db: Float, _ height: CGFloat) -> CGFloat {
        let t = CGFloat((min(hi, max(lo, db)) - lo) / (hi - lo))
        return height * (1 - t) * 0.94 + height * 0.03
    }

    private func curve(_ data: [Float], _ size: CGSize) -> Path {
        var p = Path()
        let pts = data.enumerated().map { CGPoint(x: x($0.offset, size.width), y: y($0.element, size.height)) }
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}
