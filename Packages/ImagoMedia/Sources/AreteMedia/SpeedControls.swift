// SpeedControls.swift
// AreteMedia

import SwiftUI

// MARK: - Vertical Speed Slider

/// A vertical slider popup for playback speed from 0.1x to 2.0x.
/// Uses a custom DragGesture so vertical drags map correctly to value changes.
public struct VerticalSpeedSlider: View {
    let speed: Float
    var accent: Color = .accentColor
    let onSpeedChange: (Float) -> Void

    public init(speed: Float, accent: Color = .accentColor, onSpeedChange: @escaping (Float) -> Void) {
        self.speed = speed
        self.accent = accent
        self.onSpeedChange = onSpeedChange
    }

    /// Local drag position so the thumb moves immediately without waiting
    /// for the parent to round-trip the new value back.
    @State private var dragFraction: CGFloat?

    private let trackHeight: CGFloat = 160
    private let minVal: Float = 0.1
    private let maxVal: Float = 2.0
    /// Scale marks drawn along the track (1× is emphasised).
    private let marks: [Float] = [0.1, 0.5, 1.0, 1.5, 2.0]

    private func frac(_ s: Float) -> CGFloat { CGFloat((s - minVal) / (maxVal - minVal)) }

    /// During an active drag use the local fraction; otherwise fall back to the
    /// externally-supplied speed.
    private var activeFraction: CGFloat { dragFraction ?? frac(speed) }

    /// Live speed (follows the finger immediately while dragging), snapped to 0.1.
    private var displaySpeed: Float {
        let raw = minVal + Float(activeFraction) * (maxVal - minVal)
        return (raw * 10).rounded() / 10
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Live current speed — stays visible even if the toolbar fades.
            Text(formatSpeed(displaySpeed))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(minWidth: 36)

            // Custom vertical track + notches + thumb (1× emphasised).
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 4, height: trackHeight)

                Capsule()
                    .fill(accent)
                    .frame(width: 4, height: max(4, trackHeight * activeFraction))

                // Tick notches across the track; 1× stands out.
                ForEach(marks, id: \.self) { m in
                    Rectangle()
                        .fill(m == 1.0 ? accent.opacity(0.9) : Color.secondary.opacity(0.45))
                        .frame(width: m == 1.0 ? 14 : 9, height: m == 1.0 ? 2 : 1)
                        .offset(y: -(trackHeight * frac(m)) + (m == 1.0 ? 1 : 0.5))
                }

                Circle()
                    .fill(accent)
                    .frame(width: 18, height: 18)
                    .shadow(radius: 2)
                    .offset(y: -(trackHeight * activeFraction - 9))
            }
            .frame(width: 24, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Map Y position: top = max, bottom = min
                        let y = value.location.y
                        let clamped = max(0, min(trackHeight, y))
                        let f = 1.0 - clamped / trackHeight
                        dragFraction = f
                        let raw = minVal + Float(f) * (maxVal - minVal)
                        let snapped = (raw * 10).rounded() / 10
                        onSpeedChange(max(minVal, min(maxVal, snapped)))
                    }
                    .onEnded { _ in dragFraction = nil }
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Format speed for display: "1x", "0.5x", "1.5x"
public func formatSpeed(_ speed: Float) -> String {
    if speed == Float(Int(speed)) {
        return "\(Int(speed))x"
    }
    return String(format: "%.1fx", speed)
}
