// PlayerSurface.swift
// AreteMedia

import AVFoundation
import SwiftUI

// MARK: - Video Player Representable

public struct VideoPlayerRepresentable: View {
    let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public var body: some View {
        #if os(iOS)
        _VideoPlayerUIView(player: player)
        #else
        _VideoPlayerNSView(player: player)
        #endif
    }
}

#if os(iOS)
struct _VideoPlayerUIView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> UIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? PlayerUIView)?.player = player
    }
}

public class PlayerUIView: UIView {
    public var player: AVPlayer? {
        get { playerLayer.player }
        // Re-assigning the *same* AVPlayer to the layer makes AVPlayerLayer detach
        // and re-attach, flushing the on-screen frame — a visible momentary freeze
        // on every SwiftUI re-render. Toggling mute mutates the @Observable engine,
        // which re-evaluates the player view's body and re-runs updateUIView; without
        // this guard that redundant set froze the frame. Skip it when unchanged.
        set {
            guard playerLayer.player !== newValue else { return }
            playerLayer.player = newValue
        }
    }

    override public class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        // .resizeAspect: letterboxes the video within the UIView bounds,
        // maintaining the video's native aspect ratio. The UIView itself is now
        // sized to fill the full video container (no SwiftUI .aspectRatio on top),
        // so the AVPlayerLayer always starts from a full-width, pixel-perfect frame
        // with zero gap at the edges. Black letterbox bars appear only when the
        // video aspect differs from the container (e.g. landscape video on portrait).
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }
}
#else
struct _VideoPlayerNSView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> NSView {
        let view = PlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PlayerNSView)?.player = player
    }
}

public class PlayerNSView: NSView {
    public var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        // See PlayerUIView: skip the redundant re-attach that flushes the frame.
        set {
            guard let playerLayer = layer as? AVPlayerLayer,
                  playerLayer.player !== newValue else { return }
            playerLayer.player = newValue
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif

#if os(macOS)
import AVKit

/// AVKit's player view with floating controls: the same control bar as Photos and QuickTime
/// (volume, play, AirPlay, and a scrubber with elapsed and remaining time), shown on hover.
public struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = true
        // Clear around the video, so the host's background (and the poster under it) show.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.player = player
        return view
    }

    public func updateNSView(_ view: AVPlayerView, context: Context) {
        // Re-setting the same player flushes the frame on screen; see PlayerNSView.
        if view.player !== player { view.player = player }
    }
}
#endif
