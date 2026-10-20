import QuickLookThumbnailing
import SwiftUI

// Shared building blocks for the Mac screens.

extension View {
    /// A soft rounded panel used for every section.
    func card(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }
}

/// The colored status disc used in the hero, menu bar panel and device pages.
struct HealthBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 72
    var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: tint.opacity(0.35), radius: size / 6, y: size / 18)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.rotate, options: .repeating, isActive: spinning)
        }
        .frame(width: size, height: size)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .card(padding: 18)
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

struct ThumbnailView: View {
    let url: URL
    var cornerRadius: CGFloat = 10
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if hovering {
                    Text(url.lastPathComponent)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.snappy(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 300, height: 300), scale: 2, representationTypes: .thumbnail
                )
                let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
                withAnimation(.easeOut(duration: 0.2)) { image = thumbnail }
            }
    }
}

extension Date {
    var shortRelative: String { formatted(.relative(presentation: .named)) }
}

extension UInt64 {
    var bytes: String { Int64(self).formatted(.byteCount(style: .file)) }
}
