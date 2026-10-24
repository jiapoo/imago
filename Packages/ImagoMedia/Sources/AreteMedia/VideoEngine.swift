// VideoEngine.swift
// AreteMedia

import AVFoundation
import Observation
import os
import SwiftUI
import Combine
#if os(iOS)
import AVFAudio
#endif

/// Shows in Console.app: filter on the app's bundle identifier, category "media".
let mediaLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AreteMedia", category: "media")

/// Core video playback engine supporting variable speed, scrubbing, frame-by-frame
@Observable
@MainActor
public final class VideoEngine {
    public init() {}

    // MARK: - State
    public private(set) var player: AVPlayer?
    public private(set) var playerItem: AVPlayerItem?
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var currentFrameImage: CGImage?
    public private(set) var videoSize: CGSize = .zero
    public private(set) var fps: Float = 30.0

    public var playbackSpeed: Float = 1.0 {
        didSet {
            if isPlaying { startPlayer() } else { player?.pause() }
        }
    }

    /// When true, playback lets AVPlayer read ahead enough to keep up before it starts (and after a
    /// stall) instead of starting at once. Better for files on a slow or sleeping drive, where
    /// starting at once stutters to a stop again and again. Off by default: Arete wants scrub-to-play
    /// to be instant.
    public var buffersBeforePlaying = false

    /// Playing, but waiting for the file to supply more video (see `buffersBeforePlaying`).
    public private(set) var isWaiting = false
    /// The current video has started playing at least once.
    public private(set) var hasStarted = false

    /// When true, the video loops back to the start when it ends and keeps
    /// playing — matching the native Photos app. Defaults to true.
    public var loopPlayback: Bool = true

    /// Optional playback window (edit-mode trim preview): playback starts
    /// inside it, stops/loops at its end, and seeks clamp into it.
    /// nil = the whole video.
    public private(set) var playbackBounds: ClosedRange<TimeInterval>?

    /// Confine playback to a sub-range of the video, or pass nil (or a range
    /// covering essentially the whole video) to lift the restriction.
    public func setPlaybackBounds(_ range: ClosedRange<TimeInterval>?) {
        var bounds = range
        if let r = range, r.lowerBound <= 0.05, r.upperBound >= duration - 0.05 {
            bounds = nil
        }
        playbackBounds = bounds
        // The player itself stops at the trim-out point and posts
        // DidPlayToEndTime — no polling needed to enforce the boundary.
        playerItem?.forwardPlaybackEndTime = bounds.map {
            CMTime(seconds: $0.upperBound, preferredTimescale: 600)
        } ?? .invalid
    }

    /// Start and end of the currently effective playback window.
    private var boundsStart: TimeInterval { playbackBounds?.lowerBound ?? 0 }
    private var boundsEnd: TimeInterval { playbackBounds?.upperBound ?? duration }

    /// Volume level (0.0 – 1.0). Persists across seeks.
    public var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }

    /// Mute toggle. Independent of volume slider position. Defaults to muted.
    public var isMuted: Bool = true {
        // Only flip the player's mute flag here — deliberately NOT reconfiguring
        // the audio session. Switching the AVAudioSession category mid-playback
        // stalls the AVPlayer and momentarily freezes the on-screen frame, which
        // is exactly the mute/unmute glitch. The session category is managed on
        // play/pause instead and stays `.playback` while playing, muted or not.
        didSet { player?.isMuted = isMuted }
    }

    // Time observer
    private var timeObserver: Any?
    /// The specific AVPlayer instance that owns `timeObserver`.
    /// Must remove from this player, NOT from `self.player`, which may already
    /// point to a newer player when loadVideo is called again.
    private weak var timeObserverOwner: AVPlayer?
    private var imageGenerator: AVAssetImageGenerator?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// For the log: when the current video was opened, and when stats were last written.
    private var openedAt = Date()
    private var reportedPlaying = false
    private var lastStatsLog = Date()

    // MARK: - Load

    /// Opens a video. The player is made first, so it starts reading frames (and, with
    /// `startPlaying`, playing) while the duration, size and frame rate are read alongside: on a
    /// slow drive those reads alone took seconds before anything showed.
    public func loadVideo(url: URL, startPlaying: Bool = false) async {
        let asset = AVURLAsset(url: url)
        openedAt = Date()
        reportedPlaying = false
        hasStarted = false
        mediaLog.notice("Video: opening \(url.lastPathComponent, privacy: .public), waits to buffer: \(self.buffersBeforePlaying)")

        #if os(iOS)
        // Configure audio session based on mute state.
        // When muted, use .ambient so device background audio is not ducked.
        // When unmuted, use .playback so video audio plays at full volume.
        configureAudioSession()
        #endif

        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.allowsExternalPlayback = false
        // Screen keep-awake is owned solely by ScreenSleep (driven from
        // isPlaying). AVPlayer's own display-sleep prevention defaults to
        // TRUE and holds the screen through a separate mechanism — a
        // leaked/looping player then keeps the phone awake forever.
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.automaticallyWaitsToMinimizeStalling = buffersBeforePlaying

        self.playbackBounds = nil   // a fresh video is never trim-restricted
        self.playerItem = item
        self.player = newPlayer
        self.duration = 0
        self.videoSize = .zero   // until it's read: the last video's shape doesn't apply
        newPlayer.volume = volume
        newPlayer.isMuted = isMuted

        setupTimeObserver()
        setupImageGenerator(asset: asset)
        setupEndObserver()
        setupStatusObserver()

        // Reset playhead — AVPlayer renders the first frame automatically.
        // Skipping AVAssetImageGenerator at load time cuts ~0.3-0.8 s per video.
        currentTime = 0
        if startPlaying {
            isPlaying = true
            startPlayer()
        }

        do {
            // Load duration and video tracks concurrently — first batch
            async let durationLoad  = asset.load(.duration)
            async let tracksLoad    = asset.loadTracks(withMediaType: .video)
            let (durationCMTime, tracks) = try await (durationLoad, tracksLoad)
            // Another video was opened meanwhile.
            guard playerItem === item else { return }
            duration = durationCMTime.seconds

            guard let videoTrack = tracks.first else { return }

            // Load all three track properties in a single async call — avoids
            // sending the non-Sendable AVAssetTrack across boundaries (Swift 6).
            let (size, nominalFrameRate, preferredTransform) = try await videoTrack.load(
                .naturalSize, .nominalFrameRate, .preferredTransform
            )
            guard playerItem === item else { return }

            // Apply the track's preferredTransform so videoSize reflects the
            // actual display orientation (portrait vs landscape).  Raw naturalSize
            // is always in sensor/encoded coordinates, which can be rotated 90°
            // relative to what AVPlayer renders on screen.
            let transformed = size.applying(preferredTransform)
            let displaySize = CGSize(width: abs(transformed.width),
                                    height: abs(transformed.height))

            self.videoSize = displaySize.width > 0 && displaySize.height > 0 ? displaySize : size
            self.fps       = nominalFrameRate > 0 ? nominalFrameRate : 30.0
            mediaLog.notice("Video: details read after \(self.elapsed) — \(Int(displaySize.width))×\(Int(displaySize.height)) at \(nominalFrameRate) fps, \(String(format: "%.1f", self.duration)) s")
        } catch {
            print("VideoEngine: Failed to load video: \(error)")
        }
    }

    // MARK: - Playback Controls

    public func play() {
        // Set isPlaying BEFORE configuring the audio session so that the
        // session sees the correct state (playing + unmuted → .playback).
        isPlaying = true
        #if os(iOS)
        configureAudioSession()
        #endif
        // If at (or past) the end of the playback window — or before its
        // start — restart from the window's beginning. (Not before the duration is known.)
        if duration > 0, currentTime >= boundsEnd - 0.05 || currentTime < boundsStart - 0.05 {
            Task {
                await seekToTime(boundsStart)
                startPlayer()
            }
            return
        }
        // Just start playback from wherever the player's decode head currently
        // sits.  Do NOT seek first — any additional seek (even loose-tolerance)
        // puts work into the decode pipeline that playImmediately must wait for.
        // After scrubbing/inertia, the player is already at approximately the
        // right position from the last seekFast() call.
        startPlayer()
    }

    /// Starts the player at the playback speed: at once, or once it has read ahead enough
    /// (`buffersBeforePlaying`).
    private func startPlayer() {
        guard let player else { return }
        if buffersBeforePlaying {
            player.automaticallyWaitsToMinimizeStalling = true
            player.rate = playbackSpeed
        } else {
            player.playImmediately(atRate: playbackSpeed)
        }
    }

    public func pause(_ caller: StaticString = #function, line: Int = #line) {
        if isPlaying { mediaLog.notice("Video: paused by \(caller):\(line) at \(String(format: "%.2f", self.currentTime)) s") }
        player?.pause()
        isPlaying = false
        #if os(iOS)
        configureAudioSession()
        #endif
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seekToTime(_ time: TimeInterval) async {
        let clampedTime = max(boundsStart, min(time, boundsEnd))
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        await player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clampedTime
        await generateFrameImage(at: clampedTime)
    }

    /// Fast seek for continuous scrubbing.
    /// Uses the NO-completion-handler variant of AVPlayer.seek — this is
    /// **interruptible**: calling `playImmediately(atRate:)` immediately
    /// overrides any in-flight seek and starts rendering from wherever the
    /// decoder currently is.  The completion-handler variant creates a
    /// non-interruptible seek that blocks the render pipeline until the
    /// decode finishes — that was the root cause of the scrub-to-play lag.
    public func seekFast(_ time: TimeInterval) {
        let clamped = max(boundsStart, min(time, boundsEnd))
        currentTime = clamped
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        let tol = CMTime(seconds: 3.0 / Double(fps > 0 ? fps : 30.0),
                         preferredTimescale: 600)
        // No completion handler → interruptible by playImmediately(atRate:)
        player?.seek(to: cmTime, toleranceBefore: tol, toleranceAfter: tol)
    }

    /// After scrubbing ends (when paused), do one accurate seek so the
    /// displayed frame exactly matches the scrubbed position.
    /// Uses no completion handler so it remains interruptible.
    public func finalizeAfterScrub() {
        let clamped = max(0, min(currentTime, duration))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func seekToNormalizedPosition(_ position: Double) async {
        let time = position * duration
        await seekToTime(time)
    }

    public func stepForward() async {
        let frameDuration = 1.0 / Double(fps)
        let newTime = min(currentTime + frameDuration, boundsEnd)
        await seekToTime(newTime)
    }

    public func stepBackward() async {
        let frameDuration = 1.0 / Double(fps)
        let newTime = max(currentTime - frameDuration, boundsStart)
        await seekToTime(newTime)
    }

    /// Seek to specific frame number
    public func seekToFrame(_ frame: Int) async {
        let time = Double(frame) / Double(fps)
        await seekToTime(time)
    }

    // MARK: - Frame Generation

    private func setupImageGenerator(asset: AVAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.imageGenerator = generator
    }

    public func generateFrameImage(at time: TimeInterval) async {
        guard let generator = imageGenerator else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)

        // AVAssetImageGenerator is not Sendable but is safe here
        nonisolated(unsafe) let gen = generator
        do {
            let (image, _) = try await gen.image(at: cmTime)
            self.currentFrameImage = image
        } catch {
            // Frame generation can fail for some timestamps; ignore gracefully
        }
    }

    /// Fast approximate frame grab — uses loose tolerance so AVFoundation can
    /// return the nearest keyframe without a full decode.
    public func grabFrameForDetection(at time: TimeInterval) async -> CGImage? {
        guard let generator = imageGenerator else { return nil }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        nonisolated(unsafe) let gen = generator
        // Save / restore tolerance so accurate frame-step isn't affected
        let prevBefore = gen.requestedTimeToleranceBefore
        let prevAfter  = gen.requestedTimeToleranceAfter
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter  = tolerance
        defer {
            gen.requestedTimeToleranceBefore = prevBefore
            gen.requestedTimeToleranceAfter  = prevAfter
        }
        return try? await gen.image(at: cmTime).image
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        // Always remove the observer from the player that added it — NOT from
        // self.player, which may already be a new instance after loadVideo().
        if let observer = timeObserver, let owner = timeObserverOwner {
            owner.removeTimeObserver(observer)
        }
        timeObserver = nil
        timeObserverOwner = nil

        guard let player else { return }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
                self?.logStatsNow()
            }
        }
        timeObserverOwner = player
    }

    // MARK: - Status Observer (waiting for the file)

    private func setupStatusObserver() {
        statusObservation?.invalidate()
        statusObservation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue ?? ""
            Task { @MainActor in self?.statusChanged(status, reason: reason) }
        }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus, reason: String) {
        isWaiting = status == .waitingToPlayAtSpecifiedRate
        // Follow the player, so play and pause from elsewhere (AVKit's own controls) count too.
        if status == .playing { isPlaying = true }
        if status == .paused, player?.rate == 0 { isPlaying = false }
        switch status {
        case .playing:
            hasStarted = true
            if !reportedPlaying {
                reportedPlaying = true
                mediaLog.notice("Video: playing after \(self.elapsed)")
            } else {
                mediaLog.notice("Video: playing again at \(String(format: "%.2f", self.currentTime)) s")
            }
        case .waitingToPlayAtSpecifiedRate:
            mediaLog.notice("Video: waiting at \(String(format: "%.2f", self.currentTime)) s (\(reason, privacy: .public)) \(self.stats, privacy: .public)")
        default:
            break
        }
    }

    private var elapsed: String { String(format: "%.0f ms", Date().timeIntervalSince(openedAt) * 1000) }

    /// Dropped frames and stalls so far, from the player's own log.
    private var stats: String {
        guard let event = playerItem?.accessLog()?.events.last else { return "" }
        return "dropped \(event.numberOfDroppedVideoFrames) frames, \(event.numberOfStalls) stalls"
    }

    /// Every few seconds while playing, the player's own count of dropped frames and stalls.
    private func logStatsNow() {
        guard isPlaying, Date().timeIntervalSince(lastStatsLog) >= 5 else { return }
        lastStatsLog = Date()
        mediaLog.notice("Video: at \(String(format: "%.1f", self.currentTime)) s, \(self.stats, privacy: .public)")
    }

    // MARK: - End Observer (loop / restart)

    private func setupEndObserver() {
        guard let playerItem else { return }
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                if self.loopPlayback {
                    // Restart at the playback window's start (0 when unbounded);
                    // forwardPlaybackEndTime fires this at the trim-out point too.
                    // A plain seek: `seekToTime` also renders a still of the frame from the file,
                    // which held up every restart (a visible pause on each loop of a short clip).
                    let start = CMTime(seconds: self.boundsStart, preferredTimescale: 600)
                    await self.player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.currentTime = self.boundsStart
                    self.play()
                }
            }
        }
    }

    // MARK: - Thumbnail Strip

    /// Generate evenly-spaced thumbnail images for a filmstrip.
    /// Returns an array of CGImages sampled across the video duration.
    public func generateThumbnails(count: Int) async -> [CGImage] {
        guard let generator = imageGenerator, duration > 0 else { return [] }
        let n = max(1, count)
        var images: [CGImage] = []
        nonisolated(unsafe) let gen = generator

        // Lower tolerance for speed
        let prev = (gen.requestedTimeToleranceBefore, gen.requestedTimeToleranceAfter)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 120, height: 90)

        for i in 0..<n {
            let t = duration * Double(i) / Double(n)
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let img = try? await gen.image(at: cmTime).image {
                images.append(img)
            }
        }

        // Restore
        gen.requestedTimeToleranceBefore = prev.0
        gen.requestedTimeToleranceAfter = prev.1
        gen.maximumSize = .zero
        return images
    }

    // MARK: - Audio Session

    #if os(iOS)
    /// Reconfigure AVAudioSession on play/pause transitions only — never on a mute
    /// toggle. The category depends solely on whether we're playing, so muting and
    /// unmuting during playback leave the session untouched (no player stall / no
    /// frame freeze). Mute is handled separately via `player.isMuted`.
    public func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if isPlaying {
            // Actively playing → `.playback` for speaker audio. Stays put for the
            // whole playing session regardless of mute state.
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        } else {
            // Paused/stopped → `.ambient` + deactivate so other audio resumes and
            // iOS can auto-lock the screen normally.
            try? session.setCategory(.ambient, mode: .default)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    #endif

    // MARK: - Cleanup

    public func cleanup() {
        if player != nil { mediaLog.notice("Video: closed at \(String(format: "%.1f", self.currentTime)) s, \(self.stats, privacy: .public)") }
        if let observer = timeObserver, let owner = timeObserverOwner {
            owner.removeTimeObserver(observer)
        }
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        timeObserver = nil
        timeObserverOwner = nil
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        isWaiting = false
        hasStarted = false
        player = nil
        playerItem = nil
        imageGenerator = nil
        #if os(iOS)
        // Ensure audio session is fully deactivated on cleanup so iOS can
        // auto-lock the screen when no video is playing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
