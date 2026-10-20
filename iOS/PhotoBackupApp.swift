import BackgroundTasks
import SwiftUI

@main
struct PhotoBackupApp: App {
    @State private var client: BackupClient
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let client = BackupClient()
        BackgroundBackup.register(client: client)
        if #available(iOS 26, *) { ContinuedBackup.register(client: client) }
        _client = State(initialValue: client)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Pick up a backup that iOS interrupted, e.g. when the phone locked.
                client.resumeIfUnfinished()
            case .background:
                if client.overnightBackup, client.credential != nil { BackgroundBackup.schedule() }
            default:
                break
            }
        }
    }
}

/// iOS decides when this runs: usually overnight, while charging and online. It is likely on most
/// nights but never guaranteed, and it stops if the user swipes the app away in the app switcher.
enum BackgroundBackup {
    static let identifier = "com.example.photobackup.ios.processing"

    static func register(client: BackupClient) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { bgTask in
            // BGTask is documented as safe to complete from any thread.
            let task = UncheckedSendable(value: bgTask)
            MainActor.assumeIsolated {
                schedule()
                let work = Task { await client.backUpNow(automatic: true) }
                task.value.expirationHandler = { work.cancel() }
                Task {
                    await work.value
                    if case .finished = client.phase {
                        task.value.setTaskCompleted(success: true)
                    } else {
                        task.value.setTaskCompleted(success: false)
                    }
                }
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// iOS 26: a backup the user starts keeps running after they leave the app, shown with a system
/// progress indicator, and is only stopped if the user cancels it there or the system needs to.
@available(iOS 26, *)
enum ContinuedBackup {
    static let prefix = "com.example.photobackup.ios.continued"

    static func register(client: BackupClient) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + ".*", using: .main) { bgTask in
            let task = UncheckedSendable(value: bgTask)
            MainActor.assumeIsolated {
                guard let continued = task.value as? BGContinuedProcessingTask else {
                    task.value.setTaskCompleted(success: false)
                    return
                }
                log.info("iOS started the continued-processing task")
                let work = Task { await client.run(automatic: false, systemTask: continued) }
                continued.expirationHandler = {
                    log.notice("iOS expired the continued-processing task")
                    work.cancel()
                }
                Task {
                    // Started too late: the app is already backing up without it.
                    guard await work.value else {
                        task.value.setTaskCompleted(success: true)
                        return
                    }
                    if case .finished = client.phase {
                        task.value.setTaskCompleted(success: true)
                    } else {
                        task.value.setTaskCompleted(success: false)
                    }
                }
            }
        }
    }

    /// Asks iOS to run the backup now. Returns false if it can't, and the app runs it in the foreground instead.
    @MainActor
    static func submit() -> Bool {
        let request = BGContinuedProcessingTaskRequest(
            identifier: "\(prefix).\(UUID().uuidString)",
            title: "Backing up photos",
            subtitle: "Connecting to your Mac…"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            log.notice("iOS refused the continued-processing request: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
