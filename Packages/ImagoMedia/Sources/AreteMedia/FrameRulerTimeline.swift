// FrameRulerTimeline.swift
// AreteMedia
//
// Frame-Indexed Precision Scrubber with Decisecond Scale.
// A high-density shuttle timeline indexed to the video's actual frame rate.
// Features: inertial scrolling with heavy flywheel feel, frame-locking snap,
// major ticks at deciseconds, minor ticks per individual frame.

import SwiftUI

public struct FrameRulerTimeline: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let fps: Float
    let onSeek: (TimeInterval) -> Void
    /// Optional: trim start/end for sub-range playback
    var trimStart: TimeInterval? = nil
    var trimEnd: TimeInterval? = nil

    // Visual / behavior customization (sane defaults preserve existing look)
    var majorTickHeight: CGFloat = 30
    var mediumTickHeight: CGFloat = 20
    var minorTickHeight: CGFloat = 12
    var tickSpacing: CGFloat = 10 // px between each frame tick
    var majorLineWidth: CGFloat = 1.8
    var mediumLineWidth: CGFloat = 1.0
    var minorLineWidth: CGFloat = 0.75
    /// Whether to show the thin overall-position progress bar between the time
    /// labels and the ruler. Hidden when a separate progress bar (e.g. the
    /// Photos-style pill) already represents overall position.
    var showProgressBar: Bool = true
    /// Corner radius of the ruler's rounded background. Tunable so the frame
    /// timeline can match the radius of the sibling floating bars.
    var cornerRadius: CGFloat = 6
    var majorColor: Color = Color.primary.opacity(0.85)
    var mediumColor: Color = Color.primary.opacity(0.5)
    var minorColor: Color = Color.primary.opacity(0.28)
    var backgroundFill: Color = Color.primary.opacity(0.06)
    /// Colour overrides for fullscreen/dark-background usage. Defaults match the light-mode theme.
    var timeCurrentColor: Color = .accentColor   // current-time label
    var progressFillColor: Color = Color.accentColor.opacity(0.5)  // progress bar left fill
    var progressDotColor: Color  = .accentColor  // playhead dot
    /// The playhead and the trim-range tint.
    var accent: Color = .accentColor
    /// Called when user starts/stops dragging the scrubber. Useful to keep UI chrome visible.
    var onDraggingChanged: ((Bool) -> Void)? = nil

    public init(
        currentTime: TimeInterval, duration: TimeInterval, fps: Float, onSeek: @escaping (TimeInterval) -> Void,
        trimStart: TimeInterval? = nil, trimEnd: TimeInterval? = nil,
        majorTickHeight: CGFloat = 30, mediumTickHeight: CGFloat = 20, minorTickHeight: CGFloat = 12,
        tickSpacing: CGFloat = 10,
        majorLineWidth: CGFloat = 1.8, mediumLineWidth: CGFloat = 1.0, minorLineWidth: CGFloat = 0.75,
        showProgressBar: Bool = true, cornerRadius: CGFloat = 6,
        majorColor: Color = Color.primary.opacity(0.85), mediumColor: Color = Color.primary.opacity(0.5),
        minorColor: Color = Color.primary.opacity(0.28), backgroundFill: Color = Color.primary.opacity(0.06),
        timeCurrentColor: Color = .accentColor, progressFillColor: Color = Color.accentColor.opacity(0.5),
        progressDotColor: Color = .accentColor, accent: Color = .accentColor,
        onDraggingChanged: ((Bool) -> Void)? = nil
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.fps = fps
        self.onSeek = onSeek
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.majorTickHeight = majorTickHeight
        self.mediumTickHeight = mediumTickHeight
        self.minorTickHeight = minorTickHeight
        self.tickSpacing = tickSpacing
        self.majorLineWidth = majorLineWidth
        self.mediumLineWidth = mediumLineWidth
        self.minorLineWidth = minorLineWidth
        self.showProgressBar = showProgressBar
        self.cornerRadius = cornerRadius
        self.majorColor = majorColor
        self.mediumColor = mediumColor
        self.minorColor = minorColor
        self.backgroundFill = backgroundFill
        self.timeCurrentColor = timeCurrentColor
        self.progressFillColor = progressFillColor
        self.progressDotColor = progressDotColor
        self.accent = accent
        self.onDraggingChanged = onDraggingChanged
    }

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var dragBaseTime: TimeInterval = 0
    /// True while the progress-bar is being scrubbed (prevents re-firing onDraggingChanged)
    @State private var isProgressBarDragging = false

    private var frameDuration: Double {
        fps > 0 ? 1.0 / Double(fps) : 1.0 / 30.0
    }

    private var totalFrames: Int {
        max(1, Int(ceil(duration * Double(fps))))
    }

    private var displayTime: TimeInterval {
        isDragging ? dragTime : currentTime
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Time info bar
            timeInfoBar

            // Timeline progress bar (shows overall position in video)
            if showProgressBar {
                timelineProgressBar
            }

            // Ruler area
            GeometryReader { geometry in
                let width = geometry.size.width
                let centerX = width / 2

                ZStack {
                    // Translucent background bar — colour supplied by the caller.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )

                    // Trim range highlight
                    if trimStart != nil, trimEnd != nil {
                        trimRangeOverlay(width: width, centerX: centerX)
                    }

                    // Ticks
                    Canvas { context, size in
                        drawRulerTicks(context: context, size: size, centerX: centerX)
                    }

                    // Center playhead (fixed position)
                    Rectangle()
                        .fill(accent)
                        .frame(width: 2.5, height: majorTickHeight + 10)
                        .position(x: centerX, y: geometry.size.height / 2)
                        .shadow(color: accent.opacity(0.5), radius: 4)

                    // Playhead triangle at top
                    Triangle()
                        .fill(accent)
                        .frame(width: 12, height: 7)
                        .position(x: centerX, y: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                // Drag (or tap) start — seek to the tapped tick position
                                // immediately rather than waiting for translation.
                                let tapOffset = value.location.x - centerX
                                let tappedTime = max(0, min(duration,
                                    currentTime + Double(tapOffset) / Double(tickSpacing) * frameDuration))
                                let snappedFrame = round(tappedTime / frameDuration)
                                dragTime = max(0, min(duration, snappedFrame * frameDuration))
                                dragBaseTime = dragTime
                                isDragging = true
                                onDraggingChanged?(true)
                                onSeek(dragTime)
                            }

                            // Use translation for stable delta computation
                            let translationX = value.translation.width
                            let deltaTime = -Double(translationX) / Double(tickSpacing) * frameDuration
                            let newTime = max(0, min(duration, dragBaseTime + deltaTime))
                            let frame = round(newTime / frameDuration)
                            // Clamp after rounding so floating-point can't push past the boundary
                            dragTime = max(0, min(duration, frame * frameDuration))
                            onSeek(dragTime)
                        }
                        .onEnded { value in
                            onSeek(dragTime)
                            isDragging = false
                            onDraggingChanged?(false)
                        }
                )
            }
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    // MARK: - Timeline Progress Bar

    private var timelineProgressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let progress = duration > 0 ? displayTime / duration : 0
            let trimStartFrac = (trimStart ?? 0) / max(duration, 0.001)
            let trimEndFrac = (trimEnd ?? duration) / max(duration, 0.001)

            ZStack(alignment: .leading) {
                // Background track (full width, light gray so right side is visible)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.18))

                // Trim range highlight (if set)
                if trimStart != nil, trimEnd != nil {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent.opacity(0.18))
                        .frame(width: max(0, CGFloat(trimEndFrac - trimStartFrac) * w))
                        .offset(x: CGFloat(trimStartFrac) * w)
                }

                // Progress fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(progressFillColor)
                    .frame(width: max(0, CGFloat(progress) * w))

                // Playhead dot
                Circle()
                    .fill(progressDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: progressDotColor.opacity(0.6), radius: 3)
                    .offset(x: CGFloat(progress) * w - 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isProgressBarDragging {
                            isProgressBarDragging = true
                            onDraggingChanged?(true)
                        }
                        let frac = max(0, min(1, Double(value.location.x / w)))
                        let time = frac * duration
                        // Snap to nearest frame
                        let frame = round(time / frameDuration)
                        let snapped = frame * frameDuration
                        onSeek(snapped)
                    }
                    .onEnded { _ in
                        isProgressBarDragging = false
                        onDraggingChanged?(false)
                    }
            )
        }
        .frame(height: 8)
    }

    // MARK: - Time Info Bar

    private var timeInfoBar: some View {
        HStack {
            // Current time in ms
            Text(formatTimeMS(displayTime))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(timeCurrentColor)

            Spacer()

            // Total duration
            Text(formatTimeMS(duration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Drawing

    private func drawRulerTicks(context: GraphicsContext, size: CGSize, centerX: CGFloat) {
        let midY = size.height / 2
        let framesPerSide = Int(ceil(size.width / (2 * tickSpacing))) + 2
        let currentFrame = Int(displayTime / frameDuration)

        for offset in -framesPerSide...framesPerSide {
            let frameIndex = currentFrame + offset
            guard frameIndex >= 0, frameIndex <= totalFrames else { continue }

            let x = centerX + CGFloat(offset) * tickSpacing
            guard x >= -tickSpacing, x <= size.width + tickSpacing else { continue }

            let frameTime = Double(frameIndex) * frameDuration
            let isSecond = abs(frameTime.remainder(dividingBy: 1.0)) < frameDuration * 0.5
            let isDeciSecond = abs(frameTime.remainder(dividingBy: 0.1)) < frameDuration * 0.5
            let isFifthFrame = frameIndex % 5 == 0

            let tickH: CGFloat
            let color: Color
            let lineWidth: CGFloat

            if isSecond {
                tickH = majorTickHeight
                color = majorColor
                lineWidth = majorLineWidth
            } else if isDeciSecond {
                tickH = mediumTickHeight
                color = mediumColor
                lineWidth = mediumLineWidth
            } else if isFifthFrame {
                tickH = minorTickHeight + 3
                color = minorColor.opacity(0.9)
                lineWidth = minorLineWidth
            } else {
                tickH = minorTickHeight
                color = minorColor.opacity(0.6)
                lineWidth = max(0.4, minorLineWidth * 0.5)
            }

            var path = Path()
            path.move(to: CGPoint(x: x, y: midY - tickH / 2))
            path.addLine(to: CGPoint(x: x, y: midY + tickH / 2))
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

            // Second labels
            if isSecond {
                let text = formatTimeShort(frameTime)
                context.draw(
                    Text(text)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.primary.opacity(0.65)),
                    at: CGPoint(x: x, y: size.height - 6)
                )
            }
            // Decisecond labels (show .Xs for non-second ticks)
            else if isDeciSecond {
                let dsLabel = String(format: ".%d", Int(round(frameTime * 10)) % 10)
                context.draw(
                    Text(dsLabel)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.primary.opacity(0.3)),
                    at: CGPoint(x: x, y: size.height - 5)
                )
            }
        }
    }

    // MARK: - Trim Range

    @ViewBuilder
    private func trimRangeOverlay(width: CGFloat, centerX: CGFloat) -> some View {
        if let ts = trimStart, let te = trimEnd {
            let startOffset = CGFloat((ts - displayTime) / frameDuration) * tickSpacing + centerX
            let endOffset = CGFloat((te - displayTime) / frameDuration) * tickSpacing + centerX

            Rectangle()
                .fill(accent.opacity(0.15))
                .frame(width: max(0, endOffset - startOffset))
                .position(x: (startOffset + endOffset) / 2, y: 24)
        }
    }

    // MARK: - Formatting

    private func formatTimeMS(_ time: TimeInterval) -> String {
        let totalMs = Int(time * 1000)
        let minutes = totalMs / 60000
        let seconds = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        return String(format: "%d:%02d.%03d", minutes, seconds, ms)
    }

    private func formatTimeShort(_ time: TimeInterval) -> String {
        let s = Int(time) % 60
        let m = Int(time) / 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}
