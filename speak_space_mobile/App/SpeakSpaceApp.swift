import Combine
import OSLog
import SwiftData
import SwiftUI

@main
struct speak_space_mobileApp: App {
    @StateObject private var persistence = PersistenceBootstrap()

    init() {
        PersistenceBootstrap.logger.notice("App launch started")
    }

    var body: some Scene {
        WindowGroup {
            if let container = persistence.container {
                ContentView()
                    .modelContainer(container)
            } else {
                PersistenceRecoveryView(persistence: persistence)
            }
        }
    }
}

@MainActor
final class PersistenceBootstrap: ObservableObject {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SpeakSpace",
        category: "Startup"
    )

    @Published private(set) var container: ModelContainer?
    @Published private(set) var errorMessage: String?

    private let schema = Schema([WorkspaceEntity.self, NoteEntity.self, AskTurnEntity.self])
    private lazy var configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

    init() {
        retry()
    }

    func retry() {
        Self.logger.notice("SwiftData container initialization started")
        container = nil
        errorMessage = nil
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            Self.logger.notice("SwiftData container initialization succeeded")
        } catch {
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            Self.logger.error(
                "SwiftData container initialization failed (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))"
            )
        }
    }

    func resetLocalNotesAndRetry() throws {
        Self.logger.notice("Local persistence recovery reset started")
        do {
            container = nil
            for url in Self.storeFiles(for: configuration.url) {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }

            let recordings = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Recordings", isDirectory: true)
            if FileManager.default.fileExists(atPath: recordings.path) {
                try FileManager.default.removeItem(at: recordings)
            }
            retry()
            if container != nil {
                Self.logger.notice("Local persistence recovery reset succeeded")
            } else {
                Self.logger.error("Local persistence recovery reset completed, but SwiftData remains unavailable")
            }
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Local persistence recovery reset failed (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))"
            )
            throw error
        }
    }

    nonisolated static func storeFiles(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal")
        ]
    }
}

private struct PersistenceRecoveryView: View {
    @ObservedObject var persistence: PersistenceBootstrap
    @State private var showingResetConfirmation = false
    @State private var resetError: String?

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Couldn’t open local notes", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                VStack(spacing: 12) {
                    Text("Speak Space could not open its on-device database. Your data has not been deleted.")
                    Text(persistence.errorMessage ?? "An unknown storage error occurred.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let resetError {
                        Text(resetError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } actions: {
                Button("Try Again") { persistence.retry() }
                    .buttonStyle(.borderedProminent)
                Button("Reset Local Notes", role: .destructive) {
                    showingResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Storage Recovery")
        }
        .confirmationDialog(
            "Reset all local notes?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Notes and Recordings", role: .destructive) {
                do {
                    resetError = nil
                    try persistence.resetLocalNotesAndRetry()
                } catch {
                    resetError = "Reset failed: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all workspaces, transcripts, summaries, to-dos, and saved voice recordings on this iPhone. Downloaded AI models and app settings are kept.")
        }
    }
}
