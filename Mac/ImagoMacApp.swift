import SwiftUI

@main
struct ImagoMacApp: App {
    @State private var server: BackupServer
    @State private var library = MediaLibrary()

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
                .frame(minWidth: 820, minHeight: 560)
                .tint(.blue)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(server)
                .tint(.blue)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(server)
                .tint(.blue)
        } label: {
            Image(systemName: server.health.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
