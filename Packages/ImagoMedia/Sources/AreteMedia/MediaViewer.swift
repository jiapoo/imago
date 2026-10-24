// MediaViewer.swift
// AreteMedia
//
// A complete viewer for a list of photo and video files, built from Arete's
// pieces: the video engine, the frame ruler, the speed slider and the zoomable
// photo. Space plays and pauses, , and . step one frame, ← and → move through the
// list, Esc closes.
//
// Two looks: a window of its own (black, with its own title bar of file name and
// position), or `embedded` in an app's window like the Photos app: the background
// follows the appearance, the media stays inside the window's content area, the
// host's toolbar carries the title and actions, and video controls float in a panel.

import AVFoundation
import ImageIO
import os
import SwiftUI
import UniformTypeIdentifiers

/// Shows in Console.app: filter on the app's bundle identifier, category "media".
let viewerLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AreteMedia", category: "media")

public struct MediaViewer: View {
    let urls: [URL]
    var accent: Color
    var onClose: (() -> Void)?
    /// A small image to show at once, e.g. the grid's thumbnail, while the full photo is decoded
    /// or the video loads. Called on the main actor, so it should only return what's in memory.
    var placeholder: ((URL) -> CGImage?)?
    /// Inside an app's window, like Photos, rather than a window of its own (see the top of the file).
    var embedded: Bool
    /// Called with the index shown, when it changes, so the host can title it.
    var onIndexChange: ((Int) -> Void)?
    /// Shown when a video hasn't started after a moment, e.g. "Waking up the backup drive…".
    var slowStartMessage: String

    @State private var index: Int
    @State private var engine = VideoEngine()
    @State private var image: CGImage?
    /// The current photo is the placeholder, not the full image yet.
    @State private var imageIsPlaceholder = false
    @State private var decoded = DecodedImages()
    #if os(macOS)
    @State private var swipes = SwipeMonitor()
    #endif
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showingSpeed = false
    @State private var wasPlayingBeforeScrub = false
    /// The video hasn't started after a moment: say so, rather than look stuck.
    @State private var slowStart = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - urls: the photos and videos to step through.
    ///   - index: the one to show first.
    ///   - onClose: called for Esc, and on iOS for the close button it adds. Embedded, Space on a
    ///     photo calls it too, like going back to the grid in Photos.
    public init(urls: [URL], startAt index: Int = 0, accent: Color = .accentColor,
                placeholder: ((URL) -> CGImage?)? = nil, embedded: Bool = false,
                onIndexChange: ((Int) -> Void)? = nil, slowStartMessage: String = "Loading…",
                onClose: (() -> Void)? = nil) {
        self.urls = urls
        self.accent = accent
        self.placeholder = placeholder
        self.embedded = embedded
        self.onIndexChange = onIndexChange
        self.slowStartMessage = slowStartMessage
        self.onClose = onClose
        let start = min(max(index, 0), max(urls.count - 1, 0))
        _index = State(initialValue: start)
        // The first frame already shows the placeholder.
        let first = urls.indices.contains(start) ? placeholder?(urls[start]) : nil
        _image = State(initialValue: first)
        _imageIsPlaceholder = State(initialValue: first != nil)
    }

    private var url: URL? { urls.indices.contains(index) ? urls[index] : nil }
    private var isVideo: Bool { url.map(Self.isVideo) ?? false }

    public static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()
            media
            chrome
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        }
        .environment(\.colorScheme, embedded ? colorScheme : .dark)
        .tint(accent)
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { showChrome() }
        }
        #endif
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.space) {
            if isVideo {
                togglePlay()
            } else if embedded, let onClose {
                onClose()
            }
            return .handled
        }
        .onKeyPress(characters: [",", "."]) { press in
            guard isVideo else { return .ignored }
            engine.pause()
            Task { press.characters == "," ? await engine.stepBackward() : await engine.stepForward() }
            showChrome()
            return .handled
        }
        .onKeyPress(.escape) {
            guard let onClose else { return .ignored }
            onClose()
            return .handled
        }
        .task(id: index) { await load() }
        .onChange(of: index) { _, index in onIndexChange?(index) }
        .onChange(of: engine.isPlaying) { showChrome() }
        #if os(macOS)
        .onAppear { swipes.start { go($0 ? 1 : -1) } }
        #endif
        .onDisappear {
            viewerLog.notice("Viewer: closed")
            hideTask?.cancel()
            engine.cleanup()
            #if os(macOS)
            swipes.stop()
            #endif
        }
    }

    // MARK: Media

    /// Embedded: the window's own background, white or black with the appearance, as in Photos.
    @ViewBuilder
    private var background: some View {
        if embedded {
            #if os(macOS)
            // Pure white in light mode and black in dark, as in Photos (not the grey text background).
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
            })
            #else
            Color(uiColor: .systemBackground)
            #endif
        } else {
            Color.black
        }
    }

    @ViewBuilder
    private var media: some View {
        if isVideo {
            // The poster frame, until the player draws its first frame over it (the player is clear
            // till then). Both in one frame, so they line up: a window of its own reaches under
            // its title bar; embedded, both stay inside the host's content area.
            ZStack {
                if let image { poster(image) }
                #if os(macOS)
                if embedded {
                    // AVKit's own view and floating controls: the bar Photos and QuickTime show.
                    // Exactly the video's shape: AVPlayerView paints black around the picture, which
                    // showed as bars above and below it against the light background.
                    NativePlayerView(player: engine.player)
                        .aspectRatio(videoAspect, contentMode: .fit)
                } else {
                    VideoPlayerRepresentable(player: engine.player)
                }
                #else
                VideoPlayerRepresentable(player: engine.player)
                #endif
                if slowStart, !engine.hasStarted {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(slowStartMessage).font(.callout.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .environment(\.colorScheme, .dark)
                } else if engine.isWaiting {
                    ProgressView()
                        .controlSize(.large)
                        .padding(18)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .environment(\.colorScheme, .dark)
                }
            }
            .ignoresSafeArea(edges: embedded ? [] : .all)
            .contentShape(Rectangle())
            // Embedded, clicks belong to the native controls.
            .onTapGesture {
                #if os(macOS)
                if !embedded { togglePlay() }
                #else
                toggleChrome()
                #endif
            }
        } else if let image {
            #if os(macOS)
            // Sized by the full photo's aspect, so swapping the placeholder for it doesn't jump.
            MacZoomableImage(image: NSImage(cgImage: image, size: .zero))
                .id(index)
            #else
            ZoomablePhotoView(uiImage: UIImage(cgImage: image), onSingleTap: toggleChrome)
                .id(index)
                .ignoresSafeArea()
            #endif
        } else {
            ProgressView().controlSize(.large)
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            if !embedded { topBar }
            Spacer(minLength: 0)
            // Embedded, videos use the native floating controls (see `media`); , and . still step frames.
            if isVideo, !embedded {
                videoControls
            }
        }
        // Embedded, the host moves through the list with ← →  and swipes, as in Photos: no buttons.
        .overlay { if urls.count > 1, !embedded { navigationButtons } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            #if os(iOS)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            #endif
            Text(url?.lastPathComponent ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if urls.count > 1 {
                Text("\(index + 1) of \(urls.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, leadingInset)
        .padding(.trailing, 18)
        .padding(.top, topInset)
        .padding(.bottom, 28)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(chromeVisible)
    }

    /// On the Mac the window's title bar is hidden: its traffic lights sit at the top left, and
    /// they close the window (as does Esc), so there's no close button of our own.
    private var topInset: CGFloat {
        #if os(macOS)
        14
        #else
        8
        #endif
    }

    private var leadingInset: CGFloat {
        #if os(macOS)
        84
        #else
        18
        #endif
    }

    private var videoControls: some View {
        VStack(spacing: 12) {
            // Its own view: only the ruler redraws as the time moves (30 times a second), not the
            // whole viewer.
            LiveRuler(engine: engine, accent: accent, onDraggingChanged: scrubbing)
                .frame(height: 96)

            HStack(spacing: 22) {
                Button { engine.isMuted.toggle() } label: {
                    Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28)
                }
                .help(engine.isMuted ? "Unmute" : "Mute")

                Spacer()

                Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Back one frame ( , )")
                Button(action: togglePlay) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .frame(width: 54, height: 54)
                        .background(.ultraThinMaterial, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(engine.isPlaying ? "Pause (Space)" : "Play (Space)")
                Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Forward one frame ( . )")

                Spacer()

                Button { showingSpeed.toggle() } label: {
                    Text(formatSpeed(engine.playbackSpeed))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(minWidth: 44)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .help("Playback speed")
                .popover(isPresented: $showingSpeed, arrowEdge: .top) {
                    VerticalSpeedSlider(speed: engine.playbackSpeed, accent: accent) { engine.playbackSpeed = $0 }
                        .padding(6)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, embedded ? 14 : 36)
        .padding(.bottom, embedded ? 14 : 18)
        .background {
            if !embedded {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(chromeVisible)
    }

    private var navigationButtons: some View {
        HStack {
            chevron("chevron.left", enabled: index > 0) { go(-1) }
            Spacer()
            chevron("chevron.right", enabled: index < urls.count - 1) { go(1) }
        }
        .padding(.horizontal, 14)
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(embedded ? Color.primary : .white)
                .frame(width: 40, height: 40)
                .background(embedded ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .shadow(color: .black.opacity(embedded ? 0.15 : 0), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    // MARK: Actions

    private func load() async {
        engine.pause()
        guard let url else { image = nil; return }
        // Something on screen at once: the full photo if it's been decoded ahead, else the placeholder.
        if let ready = decoded[url] {
            image = ready
            imageIsPlaceholder = false
        } else {
            image = placeholder?(url)
            imageIsPlaceholder = image != nil
        }
        if Self.isVideo(url) {
            viewerLog.notice("Viewer: open video \(url.lastPathComponent, privacy: .public) (\(index + 1) of \(urls.count))")
            engine.cleanup()
            engine.isMuted = false
            engine.playbackSpeed = 1
            // Embedded in an app that plays from a backup drive: read ahead rather than stutter.
            engine.buffersBeforePlaying = embedded
            // Photos on the Mac plays a video once and stops; Arete's own window loops.
            engine.loopPlayback = !embedded
            slowStart = false
            let opened = index
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if index == opened, !engine.hasStarted { slowStart = true }
            }
            await engine.loadVideo(url: url, startPlaying: true)
        } else {
            engine.cleanup()
            if decoded[url] == nil {
                let full = await Task.detached(priority: .userInitiated) { Self.decode(url) }.value
                guard !Task.isCancelled else { return }
                if let full { decoded[url] = full }
                image = full ?? image
                imageIsPlaceholder = full == nil && imageIsPlaceholder
            }
        }
        showChrome()
        // Not while a video plays: on a slow drive, decoding photos ahead competes with it.
        if !Self.isVideo(url) { prefetchNeighbours() }
    }

    /// Decodes the photos either side, so stepping to them is instant.
    private func prefetchNeighbours() {
        let wanted = [index + 1, index - 1].filter(urls.indices.contains).map { urls[$0] }.filter { !Self.isVideo($0) }
        decoded.keep(Set(wanted + (url.map { [$0] } ?? [])))
        for next in wanted where decoded[next] == nil {
            Task {
                let full = await Task.detached(priority: .utility) { Self.decode(next) }.value
                if let full { decoded[next] = full }
            }
        }
    }

    /// The video's width over height: from the video once it's read, from the poster until then.
    private var videoAspect: CGFloat? {
        if engine.videoSize.width > 0, engine.videoSize.height > 0 {
            return engine.videoSize.width / engine.videoSize.height
        }
        if let image, image.height > 0 { return CGFloat(image.width) / CGFloat(image.height) }
        return nil
    }

    private func poster(_ image: CGImage) -> some View {
        #if os(macOS)
        Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().scaledToFit()
        #else
        Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFit()
        #endif
    }

    /// The photo, upright, at most 4096 pixels on its long side.
    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // No bigger than the photo: ImageIO complains about a larger size, and it gains nothing.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longSide = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide > 0 ? min(longSide, 4096) : 4096,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard urls.indices.contains(next) else { return }
        index = next
    }

    private func togglePlay() {
        guard isVideo else { return }
        engine.togglePlayPause()
    }

    private func step(_ frames: Int) {
        engine.pause()
        Task { frames < 0 ? await engine.stepBackward() : await engine.stepForward() }
    }

    private func scrubbing(_ dragging: Bool) {
        if dragging {
            wasPlayingBeforeScrub = engine.isPlaying
            engine.pause()
        } else {
            engine.finalizeAfterScrub()
            if wasPlayingBeforeScrub { engine.play() }
        }
        showChrome()
    }

    private func toggleChrome() {
        chromeVisible ? hideChrome() : showChrome()
    }

    private func hideChrome() {
        hideTask?.cancel()
        chromeVisible = false
    }

    /// Shows the controls, and hides them again after a moment while a video plays. Embedded, a
    /// photo's ← → buttons also fade once the pointer rests, leaving just the photo, as in Photos.
    private func showChrome() {
        chromeVisible = true
        hideTask?.cancel()
        guard shouldAutoHide else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, shouldAutoHide else { return }
            chromeVisible = false
        }
    }

    private var shouldAutoHide: Bool {
        !showingSpeed && (engine.isPlaying || (embedded && !isVideo))
    }
}

/// The few full-size photos the viewer keeps: the current one and its neighbours.
@MainActor
private final class DecodedImages {
    private var images: [URL: CGImage] = [:]

    subscript(url: URL) -> CGImage? {
        get { images[url] }
        set { images[url] = newValue }
    }

    /// Drops everything except these.
    func keep(_ urls: Set<URL>) {
        images = images.filter { urls.contains($0.key) }
    }
}

#if os(macOS)
import AppKit

/// Two-finger horizontal swipes on the trackpad: one step per gesture, like Photos.
@MainActor
private final class SwipeMonitor {
    private var monitor: Any?
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var fired = false

    func start(_ onSwipe: @escaping (_ forward: Bool) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event }
            return MainActor.assumeIsolated { self.handle(event, onSwipe) } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the event was used.
    private func handle(_ event: NSEvent, _ onSwipe: (Bool) -> Void) -> Bool {
        if event.phase.contains(.began) { dx = 0; dy = 0; fired = false }
        dx += event.scrollingDeltaX
        dy += event.scrollingDeltaY
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { dx = 0; dy = 0 }
            return fired
        }
        guard !fired, abs(dx) > 50, abs(dx) > abs(dy) * 2 else { return fired }
        // Fingers moving right → previous, as in Safari and Photos.
        fired = true
        onSwipe(dx < 0)
        return true
    }
}
#endif

/// The frame ruler, reading the playhead itself so a time update redraws only this.
private struct LiveRuler: View {
    let engine: VideoEngine
    let accent: Color
    let onDraggingChanged: (Bool) -> Void

    var body: some View {
        FrameRulerTimeline(
            currentTime: engine.currentTime,
            duration: engine.duration,
            fps: engine.fps,
            onSeek: { engine.seekFast($0) },
            majorTickHeight: 36, mediumTickHeight: 24, minorTickHeight: 14,
            tickSpacing: 14,
            majorLineWidth: 3.0, mediumLineWidth: 1.8, minorLineWidth: 1.2,
            showProgressBar: true,
            cornerRadius: 10,
            majorColor: .white, mediumColor: .white.opacity(0.88), minorColor: .white.opacity(0.72),
            backgroundFill: .black.opacity(0.42),
            timeCurrentColor: accent, progressFillColor: accent.opacity(0.45), progressDotColor: accent,
            accent: accent,
            onDraggingChanged: onDraggingChanged
        )
    }
}
