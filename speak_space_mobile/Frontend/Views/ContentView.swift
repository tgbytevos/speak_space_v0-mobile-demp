import SwiftData
import SwiftUI

#if os(iOS)
import AVFoundation
import Combine
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkspaceEntity.sortOrder) private var workspaces: [WorkspaceEntity]
    @StateObject private var pipeline = OnDevicePipeline()
    @StateObject private var modelManager = LocalModelManager()
    @State private var showingNewWorkspace = false
    @State private var showingModels = false
    @State private var newWorkspaceTitle = ""
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @AppStorage("isDarkMode") private var isDarkMode = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                setupNotices

                Group {
                    if workspaces.isEmpty {
                        ContentUnavailableView {
                            Label("Your voice workspace", systemImage: "waveform.circle.fill")
                        } description: {
                            Text("Create a workspace, record an idea, and turn it into a transcript, summary, or to-do list — all on this iPhone.")
                        } actions: {
                            Button("Create Workspace") { showingNewWorkspace = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        List {
                            Section("Workspaces") {
                                ForEach(workspaces) { workspace in
                                    NavigationLink {
                                        WorkspaceView(workspace: workspace, pipeline: pipeline)
                                    } label: {
                                        WorkspaceRow(workspace: workspace)
                                    }
                                }
                                .onDelete(perform: deleteWorkspaces)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Speak Space")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingModels = true } label: {
                        Image(systemName: "cpu")
                    }
                    .accessibilityLabel("Local AI models")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isDarkMode.toggle() } label: {
                        Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                    }
                    .accessibilityLabel(isDarkMode ? "Use light mode" : "Use dark mode")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewWorkspace = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create workspace")
                }
            }
            .sheet(isPresented: $showingModels) {
                ModelLibraryView(manager: modelManager)
            }
            .alert("New Workspace", isPresented: $showingNewWorkspace) {
                TextField("Name", text: $newWorkspaceTitle)
                Button("Cancel", role: .cancel) { newWorkspaceTitle = "" }
                Button("Create") { createWorkspace() }
            } message: {
                Text("Use workspaces to group recordings from a meeting, project, or idea.")
            }
            .task {
                migrateLegacyRecordingPaths()
                refreshPermissionState()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshPermissionState() }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }

    @ViewBuilder
    private var setupNotices: some View {
        VStack(spacing: 8) {
            if modelManager.activeModel == nil {
                SetupNotice(
                    icon: "cpu",
                    title: installedModelExists ? "No offline model is active" : "No offline model is installed",
                    message: installedModelExists
                        ? "Select an installed model before creating local summaries."
                        : "Download an offline model to create summaries and to-do lists privately on this iPhone.",
                    buttonTitle: installedModelExists ? "Select Model" : "Download Model"
                ) {
                    showingModels = true
                }
            }

            if microphonePermission != .granted {
                SetupNotice(
                    icon: "mic.slash.fill",
                    title: "Microphone access is required",
                    message: microphonePermission == .denied
                        ? "Enable microphone access in Settings to record voice notes."
                        : "Allow microphone access to record and transcribe voice notes.",
                    buttonTitle: microphonePermission == .denied ? "Open Settings" : "Allow Access"
                ) {
                    handleMicrophonePermission()
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var installedModelExists: Bool {
        modelManager.catalog.contains { modelManager.state(for: $0).isInstalled }
    }

    private func refreshPermissionState() {
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    private func handleMicrophonePermission() {
        if microphonePermission == .denied {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } else {
            Task { @MainActor in
                _ = await AVAudioApplication.requestRecordPermission()
                refreshPermissionState()
            }
        }
    }

    private func createWorkspace() {
        let trimmed = newWorkspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled Workspace" : trimmed
        modelContext.insert(WorkspaceEntity(
            id: UUID(),
            title: title,
            dateLabel: Date.now.formatted(date: .abbreviated, time: .omitted),
            pinned: false,
            sortOrder: workspaces.count
        ))
        try? modelContext.save()
        newWorkspaceTitle = ""
    }

    private func deleteWorkspaces(at offsets: IndexSet) {
        for index in offsets {
            let workspace = workspaces[index]
            let id = workspace.id
            let descriptor = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.workspaceID == id })
            if let notes = try? modelContext.fetch(descriptor) {
                for note in notes {
                    RecordingFileStore.delete(note.audioPath)
                    modelContext.delete(note)
                }
            }
            modelContext.delete(workspace)
        }
        try? modelContext.save()
    }

    private func migrateLegacyRecordingPaths() {
        guard let notes = try? modelContext.fetch(FetchDescriptor<NoteEntity>()) else { return }
        var changed = false
        for note in notes {
            guard let storedPath = note.audioPath,
                  let currentURL = RecordingFileStore.resolve(storedPath) else { continue }
            if storedPath.hasPrefix("/") {
                note.audioPath = RecordingFileStore.storedValue(for: currentURL)
                changed = true
            }
            if note.audioDuration == nil,
               let player = try? AVAudioPlayer(contentsOf: currentURL),
               player.duration > 0 {
                note.audioDuration = player.duration
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }
}

private struct SetupNotice: View {
    let icon: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(11)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.22)))
    }
}

private struct WorkspaceRow: View {
    @Environment(\.modelContext) private var modelContext
    let workspace: WorkspaceEntity
    @State private var noteCount = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.title).font(.headline)
                Text("\(noteCount) \(noteCount == 1 ? "note" : "notes") · \(workspace.dateLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task { refreshCount() }
    }

    private func refreshCount() {
        let id = workspace.id
        let descriptor = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.workspaceID == id })
        noteCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

private struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    let workspace: WorkspaceEntity
    @ObservedObject var pipeline: OnDevicePipeline
    @State private var notes: [NoteEntity] = []
    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var textDraft = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "Ready to listen",
                        systemImage: "mic.circle",
                        description: Text("Tap the microphone and start speaking. Your recording and transcript stay on this iPhone.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(notes) { note in
                                VoiceNoteCard(note: note, pipeline: pipeline) {
                                    refreshNotes()
                                }
                            }
                        }
                        .padding()
                        .padding(.bottom, 96)
                    }
                }
            }

            composerBar
        }
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshNotes() }
        .alert("Speak Space", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var composerBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(isRecording ? Color.red : Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(pipeline.isBusy)
            .accessibilityLabel(isRecording ? "Stop and transcribe" : "Record a voice note")

            Group {
                if isRecording {
                    HStack(spacing: 10) {
                        AudioWaveformView(level: pipeline.audioLevel)
                        Text("Listening…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if pipeline.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(pipeline.phase.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Type a note or record your voice…", text: $textDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit { addTextNote() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 12)
            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 19))
            .animation(.easeInOut(duration: 0.18), value: isRecording)

            if !isRecording, !pipeline.isBusy {
                Button(action: addTextNote) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add text note")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func addTextNote() {
        let content = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        modelContext.insert(NoteEntity(
            id: UUID(),
            workspaceID: workspace.id,
            content: content,
            summary: nil,
            todo: nil,
            timeLabel: Date.now.formatted(date: .omitted, time: .shortened),
            audioPath: nil,
            audioDuration: nil,
            sortOrder: notes.count
        ))
        do {
            try modelContext.save()
            textDraft = ""
            refreshNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleRecording() async {
        do {
            if isRecording {
                isRecording = false
                let result = try await pipeline.finishAndProcess()
                let note = NoteEntity(
                    id: UUID(),
                    workspaceID: workspace.id,
                    content: result.transcript,
                    summary: result.summary,
                    todo: result.todos.isEmpty ? nil : result.todos.joined(separator: "\n"),
                    timeLabel: Date.now.formatted(date: .omitted, time: .shortened),
                    audioPath: RecordingFileStore.storedValue(for: result.audioURL),
                    audioDuration: (try? AVAudioPlayer(contentsOf: result.audioURL))?.duration,
                    sortOrder: notes.count
                )
                modelContext.insert(note)
                try modelContext.save()
                refreshNotes()
            } else {
                try await pipeline.startRecording()
                isRecording = true
            }
        } catch {
            isRecording = false
            pipeline.cancelRecording()
            errorMessage = error.localizedDescription
        }
    }

    private func refreshNotes() {
        let id = workspace.id
        var descriptor = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.workspaceID == id })
        descriptor.sortBy = [SortDescriptor(\NoteEntity.sortOrder, order: .reverse)]
        notes = (try? modelContext.fetch(descriptor)) ?? []
    }
}

private struct AudioWaveformView: View {
    let level: Double
    private let shape: [Double] = [0.35, 0.65, 1, 0.55, 0.82, 0.42, 0.72, 0.3]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shape.enumerated()), id: \.offset) { index, multiplier in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3, height: barHeight(multiplier, index: index))
                    .animation(
                        .easeInOut(duration: 0.10).delay(Double(index) * 0.008),
                        value: level
                    )
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    private func barHeight(_ multiplier: Double, index: Int) -> Double {
        let variation = 0.72 + Double(index % 3) * 0.14
        return max(4, min(28, 4 + level * 24 * multiplier * variation))
    }
}

private struct VoiceNoteCard: View {
    @Environment(\.modelContext) private var modelContext
    let note: NoteEntity
    @ObservedObject var pipeline: OnDevicePipeline
    let onChange: () -> Void
    @State private var generating: NoteGenerationType?
    @State private var errorMessage: String?
    @State private var isEditing = false
    @State private var transcriptDraft: String
    @State private var editingCreation: NoteGenerationType?
    @State private var creationDraft = ""
    @State private var copiedCreation: NoteGenerationType?
    @StateObject private var audioPlayer: NoteAudioPlayer

    init(
        note: NoteEntity,
        pipeline: OnDevicePipeline,
        onChange: @escaping () -> Void
    ) {
        self.note = note
        self.pipeline = pipeline
        self.onChange = onChange
        _transcriptDraft = State(initialValue: note.content)
        _audioPlayer = StateObject(wrappedValue: NoteAudioPlayer(
            url: RecordingFileStore.resolve(note.audioPath),
            storedDuration: note.audioDuration
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(note.timeLabel, systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Edit Transcript", systemImage: "pencil") { beginEditing() }
                    Button("Create Summary", systemImage: "text.alignleft") { generate(.summary) }
                    Button("Create To-do", systemImage: "checklist") { generate(.todo) }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteNote() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            if hasAICreation {
                HStack(alignment: .top, spacing: 0) {
                    transcriptColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Divider()
                        .padding(.horizontal, 10)

                    aiColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 190, maxHeight: 270)
            } else {
                transcriptColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(minHeight: 120)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        .onDisappear { audioPlayer.stop() }
        .alert("Couldn’t create content", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private var hasAICreation: Bool {
        generating != nil || note.summary != nil || note.todo != nil
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Transcript", systemImage: "text.quote")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            if note.audioPath != nil {
                audioControls
            }

            if isEditing {
                TextEditor(text: $transcriptDraft)
                    .font(.callout)
                    .padding(5)
                    .scrollContentBackground(.hidden)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

                HStack(spacing: 8) {
                    Button("Cancel") { cancelEditing() }
                        .font(.caption)
                    Button("Save") { saveTranscript() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                ScrollView {
                    Text(note.content)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginEditing() }
                }
            }
        }
    }

    private var aiColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("AI Creations", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)

            if let generating {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Creating \(generating.progressLabel)…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if note.summary == nil, note.todo == nil, generating == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No AI output yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Summary") { generate(.summary) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("To-do") { generate(.todo) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if let summary = note.summary {
                            creation(title: "Summary", icon: "text.alignleft", text: summary, type: .summary)
                        }
                        if let todo = note.todo {
                            creation(title: "To-do", icon: "checklist", text: todo, type: .todo)
                        }
                    }
                }
            }
        }
    }

    private var audioControls: some View {
        HStack(spacing: 7) {
            Button {
                audioPlayer.toggle()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(.tint.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause recording" : "Play recording")
            Text(audioPlayer.durationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func beginEditing() {
        transcriptDraft = note.content
        isEditing = true
    }

    private func cancelEditing() {
        transcriptDraft = note.content
        isEditing = false
    }

    private func saveTranscript() {
        let trimmed = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        note.content = trimmed
        do {
            try modelContext.save()
            transcriptDraft = trimmed
            isEditing = false
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func creation(
        title: String,
        icon: String,
        text: String,
        type: NoteGenerationType
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                Spacer()

                if copiedCreation == type {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }

                Button {
                    beginEditingCreation(type, text: text)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(title)")

                Button {
                    copyCreation(editingCreation == type ? creationDraft : text, title: title, type: type)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(title)")
                .accessibilityHint("Copies the current \(title.lowercased()) to the clipboard")
            }

            if editingCreation == type {
                TextEditor(text: $creationDraft)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .padding(5)
                    .scrollContentBackground(.hidden)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))

                HStack(spacing: 8) {
                    Button("Cancel") { cancelEditingCreation() }
                        .font(.caption)
                    Button("Save") { saveCreation(type) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(creationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(text).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func beginEditingCreation(_ type: NoteGenerationType, text: String) {
        creationDraft = text
        editingCreation = type
    }

    private func cancelEditingCreation() {
        editingCreation = nil
        creationDraft = ""
    }

    private func saveCreation(_ type: NoteGenerationType) {
        guard !creationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if type == .summary {
            note.summary = creationDraft
        } else {
            note.todo = creationDraft
        }
        do {
            try modelContext.save()
            editingCreation = nil
            creationDraft = ""
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyCreation(_ text: String, title: String, type: NoteGenerationType) {
        UIPasteboard.general.string = text
        copiedCreation = type
        UIAccessibility.post(notification: .announcement, argument: "\(title) copied")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedCreation == type { copiedCreation = nil }
        }
    }

    private func generate(_ type: NoteGenerationType) {
        generating = type
        Task { @MainActor in
            defer { generating = nil }
            do {
                let output = try await pipeline.generateNote(from: note.content, type: type)
                if type == .summary { note.summary = output } else { note.todo = output }
                try modelContext.save()
                onChange()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteNote() {
        RecordingFileStore.delete(note.audioPath)
        modelContext.delete(note)
        try? modelContext.save()
        onChange()
    }
}

@MainActor
private final class NoteAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress = 0.0
    @Published private(set) var durationLabel: String

    private let url: URL?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL?, storedDuration: Double?) {
        self.url = url
        durationLabel = Self.format(storedDuration ?? 0)
        super.init()
        prepare()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        updateProgress()
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func prepare() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        if let duration = player?.duration, duration > 0 {
            durationLabel = Self.format(duration)
        }
        updateProgress()
    }

    private func play() {
        if player == nil { prepare() }
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard player.play() else { return }
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateProgress()
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player else { return }
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    private static func format(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
            self.updateProgress()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private struct ModelLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: LocalModelManager

    var body: some View {
        NavigationStack {
            List(manager.catalog) { model in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayName).font(.headline)
                            Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        status(for: model)
                    }
                    controls(for: model)
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Local AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    @ViewBuilder private func status(for model: LocalModelDescriptor) -> some View {
        switch manager.state(for: model) {
        case .notInstalled: Text("Not installed").foregroundStyle(.secondary)
        case .downloading(let value): Text("\(Int(value * 100))%").foregroundStyle(.tint)
        case .verifying: Text("Verifying…").foregroundStyle(.secondary)
        case .installed:
            Label(manager.activeModelID == model.id ? "Selected" : "Installed",
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private func controls(for model: LocalModelDescriptor) -> some View {
        switch manager.state(for: model) {
        case .notInstalled, .failed:
            Button("Donload Offline Model") { manager.download(model) }
        case .downloading:
            ProgressView(value: progress(for: model))
            Button("Cancel", role: .destructive) { manager.cancelDownload() }
        case .verifying:
            ProgressView()
        case .installed:
            HStack {
                if manager.activeModelID != model.id { Button("Use Model") { manager.select(model) } }
                Spacer()
                Button("Delete", role: .destructive) { manager.delete(model) }
            }
        }
    }

    private func progress(for model: LocalModelDescriptor) -> Double {
        if case .downloading(let value) = manager.state(for: model) { return value }
        return 0
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [WorkspaceEntity.self, NoteEntity.self], inMemory: true)
}
#else
struct ContentView: View {
    var body: some View { Text("Speak Space is designed for iPhone.") }
}
#endif
