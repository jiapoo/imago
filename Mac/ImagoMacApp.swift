import SwiftUI

@main
struct ImagoMacApp: App {
    @State private var server: BackupServer
    @State private var library = MediaLibrary()
    @State private var viewer = MediaViewerHost()
    @State private var history = FileHistory()

    init() {
        let server = BackupServer()
        server.start()
        #if DEBUG
        // Test hook: `Imago -PairOnLaunch` opens pairing mode and prints the link,
        // so the iOS Simulator can pair without clicking in the Mac UI.
        if CommandLine.arguments.contains("-PairOnLaunch") {
            server.beginPairing()
            print(server.pairingCode?.qrString ?? "")
            fflush(stdout)
        }
        #endif
        _server = State(initialValue: server)
    }

    var body: some Scene {
        Window("Imago", id: "main") {
            MainView()
                .environment(server)
                .environment(library)
                .environment(viewer)
                .environment(history)
                .frame(minWidth: 820, minHeight: 560)
                .tint(.imago)
        }
        .windowToolbarStyle(.unified)
        .commands { FileHistoryCommands(history: history) }

        Settings {
            SettingsView()
                .environment(server)
                .tint(.imago)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(server)
                .tint(.imago)
        } label: {
            Image(systemName: server.health.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
