import SwiftUI
import UIKit

// MARK: - Full waveform (NowPlaying screen)

struct WaveformView: View {
    let trackID: UUID
    /// Real waveform amplitudes (0…1). Falls back to seeded random when nil.
    var waveformData: [Float]?
    var progress: Double = 0
    var barCount: Int = 60
    var accentColor: Color = Color(hex: "#FFD000")
    var baseColor: Color = .white.opacity(0.35)
    var onSeek: ((Double) -> Void)? = nil

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var displayProgress: Double { isDragging ? dragProgress : progress }

    var body: some View {
        GeometryReader { geo in
            let bars = resampledBars(count: barCount)
            let gap: CGFloat = 1.5
            let barWidth = (geo.size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
            let maxH = geo.size.height

            Canvas { context, _ in
                for (i, height) in bars.enumerated() {
                    let x = CGFloat(i) * (barWidth + gap)
                    let barH = CGFloat(height) * maxH
                    let y = (maxH - barH) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barH)
                    let fraction = Double(i) / Double(max(1, barCount - 1))
                    let color: Color = fraction <= displayProgress ? accentColor : baseColor
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragProgress = min(1, max(0, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        let p = min(1, max(0, value.location.x / geo.size.width))
                        isDragging = false
                        onSeek?(p)
                    }
            )
        }
        .frame(height: 44)
    }

    // MARK: - Data source

    private func resampledBars(count: Int) -> [Float] {
        if let data = waveformData, !data.isEmpty {
            return resample(data, to: count)
        }
        return seededBars(count: count, seed: trackID.hashValue)
    }
}

// MARK: - Scrolling waveform window (mini player)
// Shows a zoomed-in sliding window of the waveform. The current position is
// always pinned to the center yellow marker; the waveform scrolls right-to-left
// during playback. Supports drag-to-scrub with per-bar haptic feedback.

struct ScrollingMiniWaveformView: View {
    let trackID: UUID
    var waveformData: [Float]?
    var progress: Double
    /// How many bars are visible in the sliding window at once.
    var visibleBars: Int
    var onSeek: ((Double) -> Void)?

    // Extrapolation anchor — always kept up to date by onChange, even while
    // scrubbing, so it's correct the instant isScrubbing flips back to false.
    // Initialized from `progress` so the very first rendered frame is correct
    // (avoids the flash to 0:00 when the view is recreated while paused).
    @State private var anchorProgress: Double
    @State private var anchorDate: Date
    // Measured playback speed in progress-units/second.
    // Reset to 0 whenever a seek is detected so the extrapolation doesn't
    // rocket the waveform to an incorrect position.
    @State private var progressRate: Double = 0

    // Scrubbing — displayProgress is the single authoritative position while
    // the user has a finger on the waveform.
    @State private var isScrubbing: Bool = false
    @State private var displayProgress: Double
    @State private var dragStartProgress: Double = 0
    @State private var lastHapticBarIdx: Int = -1
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    init(trackID: UUID,
         waveformData: [Float]? = nil,
         progress: Double = 0,
         visibleBars: Int = 38,
         onSeek: ((Double) -> Void)? = nil) {
        self.trackID = trackID
        self.waveformData = waveformData
        self.progress = progress
        self.visibleBars = visibleBars
        self.onSeek = onSeek
        // Seed the anchor from the live progress value so the very first
        // TimelineView tick renders the correct position, even when the player
        // is paused and onChange(of: progress) will never fire.
        _anchorProgress  = State(initialValue: progress)
        _anchorDate      = State(initialValue: Date())
        _displayProgress = State(initialValue: progress)
    }

    private var effectiveBars: [Float] {
        guard let data = waveformData, !data.isEmpty else {
            return seededBars(count: 200, seed: trackID.hashValue)
        }
        return data
    }

    var body: some View {
        GeometryReader { geo in
            let bars      = effectiveBars
            let totalBars = bars.count
            let w         = geo.size.width
            let h         = geo.size.height
            let barWidth  = w / CGFloat(visibleBars)
            let barDrawW  = barWidth * 0.52
            let centerX   = w / 2

            TimelineView(.animation) { tl in
                // While scrubbing: show the drag position directly.
                // While playing / paused: extrapolate from the last anchor so
                // motion stays smooth at full display refresh rate (≤120 Hz)
                // between sparse 100 ms progress ticks.
                let liveProgress: Double = {
                    if isScrubbing { return displayProgress }
                    let elapsed = min(tl.date.timeIntervalSince(anchorDate), 0.15)
                    return max(0, min(1, anchorProgress + elapsed * progressRate))
                }()

                let barFloat  = liveProgress * Double(max(1, totalBars - 1))
                let barInt    = Int(barFloat)
                let subOffset = barFloat - Double(barInt)

                Canvas { context, size in
                    let halfV = visibleBars / 2 + 3
                    for i in -halfV...halfV {
                        let idx = barInt + i
                        guard idx >= 0, idx < totalBars else { continue }

                        let amp  = CGFloat(bars[idx])
                        let barH = max(h * 0.08, amp * h)
                        let xPos = centerX + CGFloat(Double(i) - subOffset) * barWidth
                        guard xPos > -barWidth, xPos < size.width + barWidth else { continue }

                        let dist     = abs(xPos - centerX)
                        let edgeFade = dist < w * 0.28 ? 1.0
                                     : max(0, 1.0 - (dist - w * 0.28) / (w * 0.22))
                        let t        = smoothstep((Double(i) - subOffset + 2.0) / 4.0)
                        let opacity  = (0.88 * (1 - t) + 0.28 * t) * edgeFade

                        context.fill(
                            Path(roundedRect: CGRect(x: xPos - barDrawW / 2,
                                                     y: (h - barH) / 2,
                                                     width: barDrawW, height: barH),
                                 cornerRadius: barDrawW / 2),
                            with: .color(.white.opacity(opacity))
                        )
                    }
                    // Yellow marker — full bar height
                    context.fill(
                        Path(roundedRect: CGRect(x: centerX - 1.5, y: 0, width: 3, height: h),
                             cornerRadius: 1.5),
                        with: .color(Color(hex: "#FFD000"))
                    )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if !isScrubbing {
                                isScrubbing = true
                                // Use the current smooth live position as the drag
                                // anchor so there's no jump when scrubbing starts.
                                let elapsed = min(Date().timeIntervalSince(anchorDate), 0.15)
                                let live    = max(0, min(1, anchorProgress + elapsed * progressRate))
                                dragStartProgress = live
                                displayProgress   = live
                                lastHapticBarIdx  = Int(live * Double(max(1, totalBars - 1)))
                                haptic.prepare()
                            }
                            let shifted = Double(-value.translation.width) / Double(barWidth)
                            let newP    = max(0, min(1, dragStartProgress + shifted / Double(max(1, totalBars - 1))))
                            displayProgress = newP

                            let newIdx = Int(newP * Double(max(1, totalBars - 1)))
                            if newIdx != lastHapticBarIdx {
                                haptic.impactOccurred(intensity: 0.45)
                                haptic.prepare()
                                lastHapticBarIdx = newIdx
                            }
                        }
                        .onEnded { _ in
                            onSeek?(displayProgress)
                            // Keep isScrubbing = true until the seek propagates.
                            // anchorProgress is already updated by onChange below
                            // (the guard was removed), so it will be correct
                            // the moment isScrubbing becomes false.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                isScrubbing = false
                            }
                        }
                )
            }
        }
        // When the track changes while the view stays alive (e.g. next track
        // in the mini player), snap the anchor to the new position immediately.
        .onChange(of: trackID) { _, _ in
            anchorProgress  = progress
            anchorDate      = Date()
            displayProgress = progress
            progressRate    = 0
            isScrubbing     = false
        }
        // Always update the anchor — even while scrubbing — so it's ready the
        // instant isScrubbing becomes false.
        .onChange(of: progress) { _, newValue in
            let now     = Date()
            let elapsed = now.timeIntervalSince(anchorDate)
            if elapsed > 0.01, elapsed < 0.5 {
                let measured = (newValue - anchorProgress) / elapsed
                // A seek appears as a huge rate jump (>> 1 progress/s for any
                // song longer than 1 second).  Reject it and reset progressRate
                // to 0 so the extrapolation doesn't overshoot to the wrong spot.
                progressRate = abs(measured) < 1.0 ? measured : 0
            }
            anchorProgress = newValue
            anchorDate     = now
        }
    }
}

// MARK: - Shared helpers

/// Classic smoothstep — clamps `t` to [0,1] then applies 3t²-2t³.
private func smoothstep(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    return x * x * (3 - 2 * x)
}

/// Linearly resample `source` to exactly `targetCount` elements.
private func resample(_ source: [Float], to targetCount: Int) -> [Float] {
    guard targetCount > 0, !source.isEmpty else { return [] }
    if source.count == targetCount { return source }
    let ratio = Double(source.count - 1) / Double(max(1, targetCount - 1))
    return (0..<targetCount).map { i in
        let pos = Double(i) * ratio
        let lo = Int(pos)
        let hi = min(lo + 1, source.count - 1)
        let frac = Float(pos - Double(lo))
        return source[lo] * (1 - frac) + source[hi] * frac
    }
}

/// Deterministic bar heights seeded from a hash — used only when no real waveform exists yet.
private func seededBars(count: Int, seed: Int) -> [Float] {
    var rng = SeededRNG(seed: seed)
    return (0..<count).map { _ in Float(0.1 + rng.next() * 0.9) }
}

private struct SeededRNG {
    var state: UInt64
    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed))
        _ = next()
    }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let v = (state >> 33) ^ state
        return Double(v) / Double(UInt64.max)
    }
}

#Preview {
    let mockData: [Float] = (0..<200).map { i in
        let t = Float(i) / 200
        return 0.2 + 0.8 * abs(sin(t * Float.pi * 12) * cos(t * Float.pi * 5))
    }
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 24) {
            WaveformView(trackID: UUID(), waveformData: mockData, progress: 0.4)
                .padding(.horizontal)
            ScrollingMiniWaveformView(trackID: UUID(), waveformData: mockData, progress: 0.45)
                .frame(width: 140, height: 32)
        }
    }
}
