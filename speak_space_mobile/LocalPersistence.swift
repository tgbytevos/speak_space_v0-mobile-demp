#if os(iOS)
import Foundation
import SwiftData

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
    var sortOrder: Int

    init(
        id: UUID,
        workspaceID: UUID,
        content: String,
        summary: String?,
        todo: String?,
        timeLabel: String,
        audioPath: String?,
        sortOrder: Int
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.content = content
        self.summary = summary
        self.todo = todo
        self.timeLabel = timeLabel
        self.audioPath = audioPath
        self.sortOrder = sortOrder
    }
}

struct NoteSnapshot: Sendable {
    let id: UUID
    let content: String
    let summary: String?
    let todo: String?
    let time: String
    let audioURL: URL?
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
            container = try ModelContainer(for: WorkspaceEntity.self, NoteEntity.self)
        } catch {
            let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(
                for: WorkspaceEntity.self,
                NoteEntity.self,
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
                            audioURL: $0.audioPath.map { URL(fileURLWithPath: $0) }
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
                    audioPath: note.audioURL?.path,
                    sortOrder: noteIndex
                ))
            }
        }
        try context.save()
    }
}
#endif
