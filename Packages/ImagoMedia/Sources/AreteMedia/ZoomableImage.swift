// ZoomableImage.swift
// AreteMedia

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - ZoomablePhotoView (iOS only)

#if os(iOS)
/// Pinch-to-zoom + drag-to-pan gesture layer for the image.
/// When `canNavigate` is true the DragGesture at scale 1× also handles
/// playlist swipe navigation; the parent receives live-offset and end callbacks.
public struct ZoomablePhotoView: View {
    let uiImage: UIImage?
    /// Pass true when this view is embedded in a playlist (VideoPlayerView).
    var canNavigate: Bool = false
    /// Called on a single tap (after the double-tap zoom-reset gesture fails) —
    /// callers use it to toggle their chrome, like the iOS Photos app.
    var onSingleTap: (() -> Void)? = nil
    /// Called with the live horizontal offset as the user swipes at scale 1×.
    var onSwipeChanged: ((CGFloat) -> Void)? = nil
    /// Called when the swipe ends. `nil` = cancelled (reset). `Bool` = navigate
    /// forward (true) or backward (false).
    var onSwipeEnded: ((Bool?) -> Void)? = nil

    public init(uiImage: UIImage?, canNavigate: Bool = false, onSingleTap: (() -> Void)? = nil,
                onSwipeChanged: ((CGFloat) -> Void)? = nil, onSwipeEnded: ((Bool?) -> Void)? = nil) {
        self.uiImage = uiImage
        self.canNavigate = canNavigate
        self.onSingleTap = onSingleTap
        self.onSwipeChanged = onSwipeChanged
        self.onSwipeEnded = onSwipeEnded
    }

    @State private var scale:       CGFloat = 1.0
    @State private var lastScale:   CGFloat = 1.0
    @State private var offset:      CGSize  = .zero
    @State private var lastOffset:  CGSize  = .zero
    /// When a drag last moved. The single tap waits out the double-tap window,
    /// so it can land as a swipe starts — that "tap" must not toggle chrome.
    @State private var lastDragAt:  Date    = .distantPast

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 8.0

    public var body: some View {
        GeometryReader { geo in
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Without an explicit content shape only the fitted image
                    // is tappable — the letterbox bars around it would ignore
                    // taps/gestures, unlike the video player's full-frame tap.
                    .contentShape(Rectangle())
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            // Pinch — zoom about the focal point (where the
                            // fingers are), keeping that point under the
                            // fingers, instead of always scaling about center.
                            MagnifyGesture()
                                .onChanged { val in
                                    let s0 = lastScale
                                    let s1 = min(max(s0 * val.magnification, minScale), maxScale)
                                    let fx = val.startAnchor.x * geo.size.width  - geo.size.width  / 2
                                    let fy = val.startAnchor.y * geo.size.height - geo.size.height / 2
                                    let ratio = s0 > 0 ? s1 / s0 : 1
                                    offset = CGSize(
                                        width:  fx - (fx - lastOffset.width)  * ratio,
                                        height: fy - (fy - lastOffset.height) * ratio
                                    )
                                    scale = s1
                                }
                                .onEnded { _ in
                                    // Snap back if at/under 1×, otherwise persist
                                    // the focal-zoom scale + offset for panning.
                                    if scale <= minScale {
                                        withAnimation(.spring()) {
                                            scale = minScale; offset = .zero
                                        }
                                        lastScale  = minScale
                                        lastOffset = .zero
                                    } else {
                                        lastScale  = scale
                                        lastOffset = offset
                                    }
                                },
                            // Drag: pan when zoomed in, swipe-to-navigate at 1×
                            DragGesture()
                                .onChanged { val in
                                    let dx = val.translation.width
                                    let dy = val.translation.height
                                    if abs(dx) + abs(dy) > 8 { lastDragAt = Date() }
                                    if scale > 1 {
                                        offset = CGSize(
                                            width:  lastOffset.width  + dx,
                                            height: lastOffset.height + val.translation.height
                                        )
                                    } else if canNavigate, abs(dx) > abs(dy) * 1.2 {
                                        onSwipeChanged?(dx)
                                    }
                                }
                                .onEnded { val in
                                    let dx = val.translation.width
                                    let dy = val.translation.height
                                    if scale > 1 {
                                        lastOffset = offset
                                    } else if canNavigate,
                                              abs(dx) > abs(dy) * 1.5,
                                              abs(dx) > 60 {
                                        onSwipeEnded?(dx < 0)
                                    } else {
                                        onSwipeEnded?(nil) // cancel
                                    }
                                }
                        )
                    )
                    // Double-tap to reset zoom
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            scale = 1; offset = .zero
                        }
                        lastScale  = 1
                        lastOffset = .zero
                    }
                    // Single tap — attached AFTER the double-tap gesture so it
                    // only fires once a second tap hasn't arrived.
                    .onTapGesture {
                        guard Date().timeIntervalSince(lastDragAt) > 0.5 else { return }
                        onSingleTap?()
                    }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
#endif

#if os(macOS)
// MARK: - Zoomable photo

/// Fits the photo to the view; pinch or double-click to zoom (up to 8×), then
/// click-and-drag to move around the zoomed image.
public struct MacZoomableImage: View {
    let image: NSImage

    public init(image: NSImage) {
        self.image = image
    }

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var dragging = false

    public var body: some View {
        GeometryReader { geo in
            let fit = fitted(image.size, in: geo.size)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fit.width, height: fit.height)
                .scaleEffect(zoom)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .clipped()
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in
                            let z = min(8, max(1, baseZoom * v.magnification))
                            offset = clamp(scaled(baseOffset, by: z / baseZoom), fit: fit, in: geo.size, zoom: z)
                            zoom = z
                        }
                        .onEnded { _ in
                            baseZoom = zoom
                            baseOffset = offset
                            updateCursor()
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            guard zoom > 1.01 else { return }
                            if !dragging { dragging = true; NSCursor.closedHand.push() }
                            offset = clamp(CGSize(width: baseOffset.width + v.translation.width,
                                                  height: baseOffset.height + v.translation.height),
                                           fit: fit, in: geo.size, zoom: zoom)
                        }
                        .onEnded { _ in
                            baseOffset = offset
                            if dragging { dragging = false; NSCursor.pop() }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if zoom > 1.01 {
                            zoom = 1; offset = .zero
                        } else {
                            zoom = 2.5
                        }
                    }
                    baseZoom = zoom
                    baseOffset = offset
                    updateCursor()
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active: if !dragging { (zoom > 1.01 ? NSCursor.openHand : NSCursor.arrow).set() }
                    case .ended:  NSCursor.arrow.set()
                    }
                }
                .onChange(of: geo.size) { _, size in
                    offset = clamp(offset, fit: fitted(image.size, in: size), in: size, zoom: zoom)
                    baseOffset = offset
                }
        }
    }

    private func updateCursor() { (zoom > 1.01 ? NSCursor.openHand : NSCursor.arrow).set() }

    private func fitted(_ img: CGSize, in box: CGSize) -> CGSize {
        guard img.width > 0, img.height > 0, box.width > 0, box.height > 0 else { return box }
        let s = min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }

    private func scaled(_ o: CGSize, by f: CGFloat) -> CGSize {
        CGSize(width: o.width * f, height: o.height * f)
    }

    /// Keep the zoomed image covering the view — no dragging it off into empty space.
    private func clamp(_ o: CGSize, fit: CGSize, in box: CGSize, zoom: CGFloat) -> CGSize {
        let maxX = max(0, (fit.width * zoom - box.width) / 2)
        let maxY = max(0, (fit.height * zoom - box.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }
}
#endif
