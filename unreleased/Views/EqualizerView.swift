import SwiftUI

struct EqualizerView: View {
    @Environment(AudioPlayer.self) private var player
    @State private var presetPrompt: PresetNamePrompt?
    @State private var presetName = ""
    @State private var hapticTrigger = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                EqualizerEditor(
                    gains: player.equalizerGains,
                    isEnabled: player.isEqualizerEnabled,
                    onGainChange: setEqualizerGain,
                    onActivate: { player.setEqualizerEnabled(true) },
                    onReset: player.resetEqualizer
                )

                enableSection
                presetSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .bottomChromeAwarePadding(resting: 36)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("EQ")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.increase, trigger: hapticTrigger)
        .alert(presetPromptTitle, isPresented: isShowingPresetPrompt) {
            if case .delete = presetPrompt {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    completePresetPrompt()
                }
            } else {
                TextField("Preset name", text: $presetName)
                Button("Cancel", role: .cancel) {}
                Button(presetPromptActionTitle) {
                    completePresetPrompt()
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } message: {
            Text(presetPromptMessage)
        }
    }

    private var enableSection: some View {
        Toggle(
            isOn: Binding(
                get: { player.isEqualizerEnabled },
                set: player.setEqualizerEnabled
            )
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Equalizer")
                    .font(.body.weight(.semibold))
                Text(player.isEqualizerEnabled ? "Applied to all playback" : "Turned off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth(duration: 0.25), value: player.isEqualizerEnabled)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presets")
                    .font(.headline)
                Spacer()
                Text(activePresetTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(EqualizerPreset.allCases.enumerated()), id: \.element.id) { index, preset in
                    EqualizerPresetRow(
                        preset: preset,
                        isSelected: player.activeEqualizerPreset == preset,
                        action: { applyPreset(preset) }
                    )

                    if index < EqualizerPreset.allCases.count - 1 || !player.customEqualizerPresets.isEmpty {
                        Divider()
                            .padding(.leading, 16)
                    }
                }

                ForEach(Array(player.customEqualizerPresets.enumerated()), id: \.element.id) { index, preset in
                    CustomEqualizerPresetRow(
                        preset: preset,
                        isSelected: player.activeCustomEqualizerPreset?.id == preset.id,
                        action: { applyPreset(preset) }
                    )
                    .contextMenu {
                        Button {
                            beginRenaming(preset)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            presetPrompt = .delete(preset)
                        } label: {
                            Label {
                                Text("Delete")
                            } icon: {
                                RedTrashMenuIcon()
                            }
                        }
                        .tint(.red)
                    }

                    if index < player.customEqualizerPresets.count - 1 {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                presetName = ""
                presetPrompt = .save
            } label: {
                Label("Save Current as New Preset", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.scale)
            .disabled(!canSaveCurrentPreset)
            .opacity(canSaveCurrentPreset ? 1 : 0.45)
        }
    }

    private var canSaveCurrentPreset: Bool {
        player.activeEqualizerPreset == nil && player.activeCustomEqualizerPreset == nil
    }

    private var isShowingPresetPrompt: Binding<Bool> {
        Binding(
            get: { presetPrompt != nil },
            set: { isPresented in
                if !isPresented {
                    presetPrompt = nil
                }
            }
        )
    }

    private var presetPromptTitle: String {
        switch presetPrompt {
        case .rename: "Rename EQ Preset"
        case .delete: "Delete EQ Preset?"
        case .save, .none: "Save EQ Preset"
        }
    }

    private var presetPromptActionTitle: String {
        if case .rename = presetPrompt { "Rename" } else { "Save" }
    }

    private var presetPromptMessage: String {
        switch presetPrompt {
        case let .delete(preset):
            "Are you sure you want to delete “\(preset.title)”?"
        case .rename:
            "Enter a new name for this preset."
        case .save, .none:
            "Save the current curve as a new preset."
        }
    }

    private func beginRenaming(_ preset: CustomEqualizerPreset) {
        presetName = preset.title
        presetPrompt = .rename(preset.id)
    }

    private func completePresetPrompt() {
        switch presetPrompt {
        case .save:
            player.saveCustomEqualizerPreset(named: presetName)
        case let .rename(id):
            player.renameCustomEqualizerPreset(id: id, to: presetName)
        case let .delete(preset):
            player.deleteCustomEqualizerPreset(id: preset.id)
        case .none:
            break
        }
    }

    private func setEqualizerGain(_ gain: Float, at index: Int) {
        guard player.equalizerGains.indices.contains(index),
              abs(player.equalizerGains[index] - gain) >= 0.05
        else { return }
        player.setEqualizerGain(gain, at: index)
        hapticTrigger &+= 1
    }

    private func applyPreset(_ preset: EqualizerPreset) {
        player.applyEqualizerPreset(preset)
        hapticTrigger &+= 1
    }

    private func applyPreset(_ preset: CustomEqualizerPreset) {
        player.applyCustomEqualizerPreset(preset)
        hapticTrigger &+= 1
    }

    private var activePresetTitle: String {
        player.activeEqualizerPreset?.title
            ?? player.activeCustomEqualizerPreset?.title
            ?? "Custom"
    }
}

private enum PresetNamePrompt: Equatable {
    case save
    case rename(CustomEqualizerPreset.ID)
    case delete(CustomEqualizerPreset)
}

private struct RedTrashMenuIcon: View {
    var body: some View {
        if let image = UIImage(systemName: "trash")?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal) {
            Image(uiImage: image)
        }
    }
}

private struct EqualizerEditor: View {
    let gains: [Float]
    let isEnabled: Bool
    let onGainChange: (Float, Int) -> Void
    let onActivate: () -> Void
    let onReset: () -> Void

    @State private var activeBandID: Int?

    private var displayedGains: [CGFloat] {
        EqualizerBand.all.indices.map { index in
            guard gains.indices.contains(index) else { return 0 }
            return CGFloat(gains[index])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shape your sound")
                        .font(.title2.weight(.bold))
                    Text("Drag any point up or down.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }

                Spacer(minLength: 12)

                Button("Reset", action: onReset)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(gains.allSatisfy { abs($0) < 0.05 })
            }

            InteractiveEqualizerChart(
                gains: displayedGains,
                isEnabled: isEnabled,
                activeBandID: $activeBandID,
                onGainChange: onGainChange,
                onActivate: onActivate
            )
            .frame(height: 300)
        }
        .animation(.smooth(duration: 0.38), value: isEnabled)
    }
}

private struct InteractiveEqualizerChart: View {
    @Environment(\.colorScheme) private var colorScheme

    let gains: [CGFloat]
    let isEnabled: Bool
    @Binding var activeBandID: Int?
    let onGainChange: (Float, Int) -> Void
    let onActivate: () -> Void

    private let topInset: CGFloat = 34
    private let bottomInset: CGFloat = 48
    private let horizontalInset: CGFloat = 30
    private let screenEdgeExtension: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let plotRect = CGRect(
                x: horizontalInset,
                y: topInset,
                width: max(1, proxy.size.width - horizontalInset * 2),
                height: max(1, proxy.size.height - topInset - bottomInset)
            )
            let extendedRect = CGRect(
                x: -screenEdgeExtension,
                y: plotRect.minY,
                width: proxy.size.width + screenEdgeExtension * 2,
                height: plotRect.height
            )
            let curveContentInset = plotRect.minX - extendedRect.minX
            let gridPlotRect = CGRect(
                x: curveContentInset,
                y: plotRect.minY,
                width: plotRect.width,
                height: plotRect.height
            )
            let points = chartPoints(in: plotRect)
            let curveAnimation: Animation? = activeBandID == nil
                ? .smooth(duration: 0.32)
                : nil

            ZStack(alignment: .topLeading) {
                EqualizerGrid(
                    plotRect: gridPlotRect,
                    horizontalExtent: 0...extendedRect.width
                )
                .frame(width: extendedRect.width, height: proxy.size.height)
                .offset(x: extendedRect.minX)

                EqualizerCurveShape(
                    gains: EqualizerGainVector(gains),
                    contentInset: curveContentInset,
                    fillToBottom: true
                )
                    .fill(
                        LinearGradient(
                            colors: [curveColor.opacity(isEnabled ? 0.25 : 0.1), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: extendedRect.width, height: extendedRect.height)
                    .offset(x: extendedRect.minX, y: extendedRect.minY)

                EqualizerCurveShape(
                    gains: EqualizerGainVector(gains),
                    contentInset: curveContentInset,
                    fillToBottom: false
                )
                    .stroke(
                        curveColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: extendedRect.width, height: extendedRect.height)
                    .offset(x: extendedRect.minX, y: extendedRect.minY)
                    .shadow(color: Color.accentColor.opacity(isEnabled ? 0.2 : 0), radius: 5)

                ForEach(EqualizerBand.all) { band in
                    let point = points[band.id]

                    Rectangle()
                        .fill(Color.accentColor.opacity(activeBandID == band.id ? 0.22 : 0.1))
                        .frame(width: 1, height: abs(plotRect.midY - point.y))
                        .position(
                            x: point.x,
                            y: min(plotRect.midY, point.y) + abs(plotRect.midY - point.y) / 2
                        )
                        .opacity(isEnabled ? 1 : 0)

                    Circle()
                        .fill(isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: activeBandID == band.id ? 24 : 18, height: activeBandID == band.id ? 24 : 18)
                        .overlay {
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 3)
                        }
                        .shadow(
                            color: Color.accentColor.opacity(activeBandID == band.id ? 0.35 : 0.12),
                            radius: activeBandID == band.id ? 7 : 3,
                            y: 2
                        )
                        .shadow(
                            color: colorScheme == .dark
                                ? Color.white.opacity(activeBandID == band.id ? 0.22 : 0.18)
                                : .clear,
                            radius: activeBandID == band.id ? 5 : 3
                        )
                        .position(point)

                    if activeBandID == band.id, isEnabled {
                        Text(formattedGain(gains[band.id]))
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(
                                Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .position(x: point.x, y: max(14, point.y - 45))
                            .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    }

                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(activeBandID == band.id ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(width: 1, height: 6)
                        Text("\(band.label)Hz")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(activeBandID == band.id ? Color.accentColor : .secondary)
                    }
                    .position(x: point.x, y: plotRect.maxY + 20)
                    .accessibilityHidden(true)

                    EqualizerAccessibleBandControl(
                        band: band,
                        gain: Double(gains[band.id]),
                        isEnabled: isEnabled,
                        onActivate: onActivate,
                        onChange: { onGainChange(Float($0), band.id) }
                    )
                    .frame(width: max(36, plotRect.width / CGFloat(EqualizerBand.all.count)), height: plotRect.height)
                    .position(x: point.x, y: plotRect.midY)
                }

            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(in: plotRect))
            .animation(curveAnimation, value: gains)
            .animation(.smooth(duration: 0.18), value: activeBandID)
        }
    }

    private func chartDragGesture(in plotRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isEnabled {
                    onActivate()
                }

                let bandID: Int
                if let activeBandID {
                    bandID = activeBandID
                } else {
                    let progress = min(max((value.startLocation.x - plotRect.minX) / plotRect.width, 0), 1)
                    bandID = Int((progress * CGFloat(EqualizerBand.all.count - 1)).rounded())
                    activeBandID = bandID
                }

                let normalized = (plotRect.midY - value.location.y) / (plotRect.height * 0.46)
                let rawGain = min(max(normalized * 12, -12), 12)
                let steppedGain = (rawGain * 2).rounded() / 2
                onGainChange(Float(steppedGain), bandID)
            }
            .onEnded { _ in
                activeBandID = nil
            }
    }

    private var curveColor: Color {
        isEnabled ? Color.accentColor : Color.secondary.opacity(0.55)
    }

    private func chartPoints(in rect: CGRect) -> [CGPoint] {
        EqualizerBand.all.map { band in
            let gain = gains.indices.contains(band.id) ? gains[band.id] : 0
            return CGPoint(
                x: rect.minX + rect.width * CGFloat(band.id) / CGFloat(EqualizerBand.all.count - 1),
                y: rect.midY - (gain / 12) * rect.height * 0.46
            )
        }
    }

    private func formattedGain(_ gain: CGFloat) -> String {
        if abs(gain) < 0.05 { return "0 dB" }
        return String(format: "%+.1f dB", gain)
    }
}

private struct EqualizerGrid: View {
    let plotRect: CGRect
    let horizontalExtent: ClosedRange<CGFloat>

    var body: some View {
        Canvas { context, _ in
            for level in 0...4 {
                let y = plotRect.minY + plotRect.height * CGFloat(level) / 4
                var path = Path()
                path.move(to: CGPoint(x: horizontalExtent.lowerBound, y: y))
                path.addLine(to: CGPoint(x: horizontalExtent.upperBound, y: y))
                context.stroke(
                    path,
                    with: .color(.secondary.opacity(level == 2 ? 0.22 : 0.1)),
                    style: StrokeStyle(lineWidth: 1, dash: level == 2 ? [] : [3, 6])
                )
            }

            for band in EqualizerBand.all {
                let x = plotRect.minX + plotRect.width * CGFloat(band.id) / CGFloat(EqualizerBand.all.count - 1)
                var path = Path()
                path.move(to: CGPoint(x: x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                context.stroke(
                    path,
                    with: .color(.secondary.opacity(0.07)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 7])
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct EqualizerCurveShape: Shape {
    var gains: EqualizerGainVector
    let contentInset: CGFloat
    let fillToBottom: Bool

    var animatableData: EqualizerGainVector {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let contentWidth = max(1, rect.width - contentInset * 2)
        let bandPoints = EqualizerBand.all.map { band in
            let gain = gains[band.id]
            return CGPoint(
                x: rect.minX + contentInset
                    + contentWidth * CGFloat(band.id) / CGFloat(EqualizerBand.all.count - 1),
                y: rect.midY - CGFloat(gain / 12) * rect.height * 0.46
            )
        }
        var path = smoothPath(
            points: bandPoints,
            horizontalBounds: rect.minX...rect.maxX
        )
        if fillToBottom {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    private func smoothPath(
        points: [CGPoint],
        horizontalBounds: ClosedRange<CGFloat>
    ) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: horizontalBounds.lowerBound, y: first.y))
        path.addLine(to: first)

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
            if index == points.count - 1 {
                path.addQuadCurve(to: current, control: current)
            }
        }
        path.addLine(to: CGPoint(x: horizontalBounds.upperBound, y: last.y))
        return path
    }
}

private struct EqualizerGainVector: VectorArithmetic, Equatable {
    private var values: [Double]

    init(_ gains: [CGFloat]) {
        values = gains.map(Double.init)
    }

    private init(values: [Double]) {
        self.values = values
    }

    static var zero: EqualizerGainVector {
        EqualizerGainVector(values: Array(repeating: 0, count: EqualizerBand.all.count))
    }

    subscript(index: Int) -> Double {
        values.indices.contains(index) ? values[index] : 0
    }

    static func + (lhs: EqualizerGainVector, rhs: EqualizerGainVector) -> EqualizerGainVector {
        EqualizerGainVector(values: combined(lhs, rhs, operation: +))
    }

    static func - (lhs: EqualizerGainVector, rhs: EqualizerGainVector) -> EqualizerGainVector {
        EqualizerGainVector(values: combined(lhs, rhs, operation: -))
    }

    static func += (lhs: inout EqualizerGainVector, rhs: EqualizerGainVector) {
        lhs = lhs + rhs
    }

    static func -= (lhs: inout EqualizerGainVector, rhs: EqualizerGainVector) {
        lhs = lhs - rhs
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combined(
        _ lhs: EqualizerGainVector,
        _ rhs: EqualizerGainVector,
        operation: (Double, Double) -> Double
    ) -> [Double] {
        (0..<EqualizerBand.all.count).map { operation(lhs[$0], rhs[$0]) }
    }
}

private struct EqualizerAccessibleBandControl: View {
    let band: EqualizerBand
    let gain: Double
    let isEnabled: Bool
    let onActivate: () -> Void
    let onChange: (Double) -> Void

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("\(band.character), \(band.label) hertz")
            .accessibilityValue(isEnabled ? String(format: "%+.1f decibels", gain) : "EQ off")
            .accessibilityHint(isEnabled ? "Swipe up or down to adjust" : "Adjusting turns on the equalizer")
            .accessibilityAdjustableAction { direction in
                if !isEnabled {
                    onActivate()
                }
                switch direction {
                case .increment:
                    onChange(min(12, gain + 0.5))
                case .decrement:
                    onChange(max(-12, gain - 0.5))
                @unknown default:
                    break
                }
            }
    }
}

private struct EqualizerPresetRow: View {
    let preset: EqualizerPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CustomEqualizerPresetRow: View {
    let preset: CustomEqualizerPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Custom preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension EqualizerPreset {
    var detail: String {
        switch self {
        case .flat: "No frequency shaping"
        case .bassBoost: "Deeper lows with a clean top end"
        case .vocal: "Brings voices forward"
        case .warm: "Fuller lows and softer highs"
        case .bright: "More clarity, detail, and air"
        case .acoustic: "Natural presence and definition"
        }
    }
}

#Preview {
    NavigationStack {
        EqualizerView()
    }
    .environment(AudioPlayer(store: ProjectStore()))
    .environment(MiniPlayerVisibility())
}
