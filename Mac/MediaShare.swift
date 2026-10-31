import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The system share menu for photos and videos on the drive: AirDrop, Messages, Mail, WeChat and every
/// other app that takes them. As in Arete, each file goes as what it is (a QuickTime movie, a HEIC or
/// JPEG photo), not as a plain file link: given a plain file, WeChat sends a file instead of a video.
@MainActor
enum MediaShare {
    /// Shows the share menu where the pointer is: on the button or menu item just clicked.
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty, let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        NSSharingServicePicker(items: urls.map(itemProvider))
            .show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    /// The file under its media type, its item the file's URL.
    private static func itemProvider(_ url: URL) -> NSItemProvider {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: type.identifier) { completion, _, _ in
            completion?(url as NSURL, nil)
        }
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// Share, for the viewer's toolbar and the selection bars.
struct ShareButton: View {
    let urls: [URL]

    var body: some View {
        Button { MediaShare.present(urls) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(urls.isEmpty)
        .help(urls.count > 1 ? "Share these \(urls.count) with AirDrop, Messages, WeChat or another app" : "Share with AirDrop, Messages, WeChat or another app")
    }
}
