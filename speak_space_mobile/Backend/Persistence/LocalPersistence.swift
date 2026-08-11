#if os(iOS)
import Foundation
import SwiftData

enum RecordingFileStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Persist only the filename. Absolute sandbox paths contain a container UUID
    /// that may change when Xcode reinstalls the app.
    static func storedValue(for url: URL) -> String {
        url.lastPathComponent
    }

    static func resolve(_ storedValue: String?) -> URL? {
        guard let storedValue, !storedValue.isEmpty else { return nil }

        // Keep compatibility with an existing absolute path while it is valid.
        if storedValue.hasPrefix("/"), FileManager.default.fileExists(atPath: storedValue) {
            return URL(fileURLWithPath: storedValue)
        }

        // For stale absolute paths and new filename-only records, rebuild the URL
        // inside the app's current data container.
        let filename = URL(fileURLWithPath: storedValue).lastPathComponent
        let currentURL = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: currentURL.path) ? currentURL : nil
    }

    static func delete(_ storedValue: String?) {
        guard let url = resolve(storedValue) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

@Model
final class WorkspaceEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var dateLabel: String
    var pinned: Bool
    var sortOrder: Int

    init(id: UUID, title: String, dateLabel: String, pinned: Bool, sortOrder: Int) {
        self.id = id
        self.title = title
        self.dateLabel = dateLabel
        self.pinned = pinned
        self.sortOrder = sortOrder
    }
}

@Model
final class NoteEntity {
    @Attribute(.unique) var id: UUID
    var workspaceID: UUID
    var content: String
    var summary: String?
    var todo: String?
    var timeLabel: String
    var audioPath: String?
    var audioDuration: Double?
    var sortOrder: Int

    init(
        id: UUID,
        workspaceID: UUID,
        content: String,
        summary: String?,
        todo: String?,
        timeLabel: String,
        audioPath: String?,
        audioDuration: Double? = nil,
        sortOrder: Int
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.content = content
        self.summary = summary
        self.todo = todo
        self.timeLabel = timeLabel
        self.audioPath = audioPath
        self.audioDuration = audioDuration
        self.sortOrder = sortOrder
    }
}

@Model
final class AskTurnEntity {
    @Attribute(.unique) var id: UUID
    var scopeID: UUID
    var question: String
    var answer: String
    var createdAt: Date
    var isGlobal: Bool = false
    var isAppWide: Bool = false
    var hasTranscriptSource: Bool = true

    init(id: UUID = UUID(), scopeID: UUID, question: String, answer: String, createdAt: Date = .now, isGlobal: Bool = false, isAppWide: Bool = false, hasTranscriptSource: Bool = true) {
        self.id = id
        self.scopeID = scopeID
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
        self.isGlobal = isGlobal
        self.isAppWide = isAppWide
        self.hasTranscriptSource = hasTranscriptSource
    }
}

func deleteAskTurns(for scopeID: UUID, isGlobal: Bool = false, isAppWide: Bool = false, from context: ModelContext) {
    let descriptor = FetchDescriptor<AskTurnEntity>(predicate: #Predicate {
        $0.scopeID == scopeID && $0.isGlobal == isGlobal && $0.isAppWide == isAppWide
    })
    for turn in (try? context.fetch(descriptor)) ?? [] { context.delete(turn) }
}

struct NoteSnapshot: Sendable {
    let id: UUID
    let content: String
    let summary: String?
    let todo: String?
    let time: String
    let audioURL: URL?
    let audioDuration: Double?
}

struct WorkspaceSnapshot: Sendable {
    let id: UUID
    let title: String
    let date: String
    let pinned: Bool
    let notes: [NoteSnapshot]
}

@MainActor
final class LocalPersistenceStore {
    static let shared = LocalPersistenceStore()
    private let container: ModelContainer
    private let context: ModelContext

    private init() {
        do {
            container = try ModelContainer(for: WorkspaceEntity.self, NoteEntity.self, AskTurnEntity.self)
        } catch {
            let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(
                for: WorkspaceEntity.self,
                NoteEntity.self,
                AskTurnEntity.self,
                configurations: memoryOnly
            )
        }
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func load() throws -> [WorkspaceSnapshot] {
        let workspaces = try context.fetch(FetchDescriptor<WorkspaceEntity>())
            .sorted { $0.sortOrder < $1.sortOrder }
        let notes = try context.fetch(FetchDescriptor<NoteEntity>())
        let notesByWorkspace = Dictionary(grouping: notes, by: \.workspaceID)

        return workspaces.map { workspace in
            WorkspaceSnapshot(
                id: workspace.id,
                title: workspace.title,
                date: workspace.dateLabel,
                pinned: workspace.pinned,
                notes: (notesByWorkspace[workspace.id] ?? [])
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map {
                        NoteSnapshot(
                            id: $0.id,
                            content: $0.content,
                            summary: $0.summary,
                            todo: $0.todo,
                            time: $0.timeLabel,
                            audioURL: RecordingFileStore.resolve($0.audioPath),
                            audioDuration: $0.audioDuration
                        )
                    }
            )
        }
    }

    func save(_ snapshots: [WorkspaceSnapshot]) throws {
        for note in try context.fetch(FetchDescriptor<NoteEntity>()) { context.delete(note) }
        for workspace in try context.fetch(FetchDescriptor<WorkspaceEntity>()) { context.delete(workspace) }

        for (workspaceIndex, workspace) in snapshots.enumerated() {
            context.insert(WorkspaceEntity(
                id: workspace.id,
                title: workspace.title,
                dateLabel: workspace.date,
                pinned: workspace.pinned,
                sortOrder: workspaceIndex
            ))
            for (noteIndex, note) in workspace.notes.enumerated() {
                context.insert(NoteEntity(
                    id: note.id,
                    workspaceID: workspace.id,
                    content: note.content,
                    summary: note.summary,
                    todo: note.todo,
                    timeLabel: note.time,
                    audioPath: note.audioURL.map(RecordingFileStore.storedValue),
                    audioDuration: note.audioDuration,
                    sortOrder: noteIndex
                ))
            }
        }
        try context.save()
    }
}
#endif
