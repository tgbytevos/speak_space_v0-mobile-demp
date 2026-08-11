import SwiftData
import SwiftUI

#if os(iOS)
import AVFoundation
import Combine
import NaturalLanguage
import UIKit

enum LocalSubsystemReadiness: Equatable {
    case notConfigured
    case ready
    case unavailable

    static func resolve(
        hasSelection: Bool,
        selectedFileIsReady: Bool,
        hasFailure: Bool,
        runtimeFailed: Bool
    ) -> LocalSubsystemReadiness {
        guard hasSelection else { return hasFailure ? .unavailable : .notConfigured }
        if runtimeFailed || hasFailure || !selectedFileIsReady { return .unavailable }
        return .ready
    }

    var shortLabel: String {
        switch self {
        case .notConfigured: return "No model"
        case .ready: return "Ready"
        case .unavailable: return "Unavailable"
        }
    }

    var color: Color {
        switch self {
        case .notConfigured: return .secondary
        case .ready: return .green
        case .unavailable: return .red
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkspaceEntity.sortOrder) private var workspaces: [WorkspaceEntity]
    @Query(sort: \NoteEntity.sortOrder) private var allNotes: [NoteEntity]
    @StateObject private var pipeline = OnDevicePipeline()
    @StateObject private var modelManager = LocalModelManager()
    @StateObject private var whisperModelManager = WhisperModelManager()
    @State private var showingNewWorkspace = false
    @State private var showingModels = false
    @State private var showingWhisperModels = false
    @State private var showingAskAI = false
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
                            .foregroundStyle(textModelReadiness.color)
                    }
                    .accessibilityLabel("Local text model: \(textModelReadiness.shortLabel)")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingWhisperModels = true } label: {
                        Image(systemName: "waveform.badge.mic")
                            .foregroundStyle(whisperModelReadiness.color)
                    }
                    .accessibilityLabel("Whisper transcription model: \(whisperModelReadiness.shortLabel)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ask AI", systemImage: "sparkles") { showingAskAI = true }
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
            .sheet(isPresented: $showingWhisperModels) {
                WhisperModelLibraryView(manager: whisperModelManager)
            }
            .sheet(isPresented: $showingAskAI) {
                AskView(
                    scopeID: AskMode.appScopeID,
                    mode: .app,
                    transcript: appAskTranscript,
                    pipeline: pipeline
                )
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
                if phase == .active {
                    refreshPermissionState()
                    whisperModelManager.refreshInstalledModels()
                }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }

    @ViewBuilder
    private var setupNotices: some View {
        VStack(spacing: 8) {
            if whisperModelManager.activeModel == nil {
                SetupNotice(
                    icon: "waveform.badge.mic",
                    title: installedWhisperModelExists ? "No Whisper model is selected" : "No Whisper model is installed",
                    message: installedWhisperModelExists
                        ? "Select an installed multilingual Whisper model before recording."
                        : "Download and select a multilingual Whisper model to transcribe Chinese, English, and mixed speech on this iPhone.",
                    buttonTitle: installedWhisperModelExists ? "Select Whisper" : "Download Whisper"
                ) {
                    showingWhisperModels = true
                }
            }

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

    private var appAskTranscript: String {
        AppAskCorpus.transcript(workspaces: workspaces, notes: allNotes)
    }

    private var installedWhisperModelExists: Bool {
        whisperModelManager.catalog.contains { whisperModelManager.state(for: $0).isInstalled }
    }

    private var textModelReadiness: LocalSubsystemReadiness {
        .resolve(
            hasSelection: modelManager.activeModelID != nil,
            selectedFileIsReady: modelManager.activeModelIsReady,
            hasFailure: modelManager.hasAvailabilityFailure,
            runtimeFailed: pipeline.textModelRuntimeFailed
        )
    }

    private var whisperModelReadiness: LocalSubsystemReadiness {
        .resolve(
            hasSelection: whisperModelManager.activeModelID != nil,
            selectedFileIsReady: whisperModelManager.activeModelIsReady,
            hasFailure: whisperModelManager.hasAvailabilityFailure,
            runtimeFailed: pipeline.whisperRuntimeFailed
        )
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
                    deleteAskTurns(for: note.id, from: modelContext)
                    modelContext.delete(note)
                }
            }
            deleteAskTurns(for: id, isGlobal: true, from: modelContext)
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
    @State private var showingAsk = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAsk = true } label: { Image(systemName: "questionmark.bubble") }
                    .accessibilityLabel("Ask workspace")
            }
        }
        .sheet(isPresented: $showingAsk) {
            AskView(
                scopeID: workspace.id,
                mode: .workspace,
                transcript: notes.map(\.content).joined(separator: "\n"),
                pipeline: pipeline
            )
        }
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

enum VoiceNoteContentPane: String, CaseIterable {
    case transcript = "Transcript"
    case aiCreation = "AI Creation"

    static func initial(hasAICreation: Bool) -> Self {
        hasAICreation ? .aiCreation : .transcript
    }
}

private struct VoiceNoteCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var showingAsk = false
    @State private var selectedPane: VoiceNoteContentPane
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
        _selectedPane = State(initialValue: .initial(hasAICreation: note.summary != nil || note.todo != nil))
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
                    Button("Ask Transcript", systemImage: "questionmark.bubble") { showingAsk = true }
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
                VStack(spacing: 10) {
                    Picker("Note content", selection: $selectedPane) {
                        ForEach(VoiceNoteContentPane.allCases, id: \.self) { pane in
                            Text(pane.rawValue).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Switches between the transcript and generated AI content for this note")

                    ZStack(alignment: .topLeading) {
                        if selectedPane == .transcript {
                            transcriptColumn
                                .transition(transcriptPaneTransition)
                        } else {
                            aiColumn
                                .transition(aiCreationPaneTransition)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: selectedPane)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 270, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    transcriptColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if let generating {
                        generationProgress(for: generating)
                    }
                }
                .frame(minHeight: 120)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        .onDisappear { audioPlayer.stop() }
        .sheet(isPresented: $showingAsk) {
            AskView(scopeID: note.id, mode: .thread, transcript: note.content, pipeline: pipeline)
        }
        .onChange(of: hasAICreation) { hadCreation, hasCreation in
            if !hasCreation {
                selectedPane = .transcript
            } else if !hadCreation {
                selectedPane = .aiCreation
            }
        }
        .alert("Couldn’t create content", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private var transcriptPaneTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading))
    }

    private var aiCreationPaneTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
    }

    private var hasAICreation: Bool {
        note.summary != nil || note.todo != nil
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
                generationProgress(for: generating)
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

    private func generationProgress(for type: NoteGenerationType) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("Creating \(type.progressLabel)…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Creating \(type.progressLabel)")
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
        selectedPane = .transcript
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
        if hasAICreation { selectedPane = .aiCreation }
        Task { @MainActor in
            defer { generating = nil }
            do {
                let output = try await pipeline.generateNote(from: note.content, type: type)
                if type == .summary { note.summary = output } else { note.todo = output }
                try modelContext.save()
                selectedPane = .aiCreation
                onChange()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteNote() {
        RecordingFileStore.delete(note.audioPath)
        deleteAskTurns(for: note.id, from: modelContext)
        modelContext.delete(note)
        try? modelContext.save()
        onChange()
    }
}

enum ThreadAskRetrieval {
    nonisolated static func segments(for question: String, in transcript: String, limit: Int = 3) -> [String] {
        let chunks = transcript.split(whereSeparator: { "\n.!?;。！？；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let questionVector = vector(question)
        guard !questionVector.isEmpty else { return [] }

        return chunks.compactMap { chunk -> (Double, String)? in
            let chunkVector = vector(chunk)
            let dot = questionVector.reduce(0.0) { $0 + Double($1.value * chunkVector[$1.key, default: 0]) }
            let magnitude = sqrt(Double(questionVector.values.reduce(0) { $0 + $1 * $1 }))
                * sqrt(Double(chunkVector.values.reduce(0) { $0 + $1 * $1 }))
            guard magnitude > 0, dot > 0 else { return nil }
            return (dot / magnitude, chunk)
        }
        .sorted { $0.0 > $1.0 }
        .prefix(limit)
        .map(\.1)
    }

    private nonisolated static func vector(_ text: String) -> [String: Int] {
        // ponytail: lexical vectors are the v1 ceiling; replace with embeddings in TASK-044.
        let stopWords: Set<String> = ["a", "an", "are", "how", "is", "the", "what", "when", "where", "who", "why"]
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }.reduce(into: [:]) {
            guard !stopWords.contains(String($1)) else { return }
            $0[String($1), default: 0] += 1
        }
    }
}

struct ThreadAskIndex {
    private let chunks: [String]
    private let embedding: NLEmbedding?
    private let vectors: [[Double]?]

    init(transcript: String) {
        let selectedChunks = transcript.split(whereSeparator: { "\n.!?;。！？；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let language = NLLanguageRecognizer.dominantLanguage(for: transcript) ?? .english
        let selectedEmbedding = NLEmbedding.sentenceEmbedding(for: language)
        chunks = selectedChunks
        embedding = selectedEmbedding
        vectors = selectedChunks.map { selectedEmbedding?.vector(for: $0) }
    }

    func segments(for question: String, limit: Int = 3) -> [String] {
        guard let embedding, let query = embedding.vector(for: question) else {
            return ThreadAskRetrieval.segments(for: question, in: chunks.joined(separator: ". "), limit: limit)
        }
        let matches = zip(chunks, vectors).compactMap { chunk, vector -> (Double, String)? in
            guard let vector else { return nil }
            let score = cosine(query, vector)
            return score >= 0.45 ? (score, chunk) : nil
        }
        .sorted { $0.0 > $1.0 }
        .prefix(limit)
        .map(\.1)
        return matches.isEmpty
            ? ThreadAskRetrieval.segments(for: question, in: chunks.joined(separator: ". "), limit: limit)
            : matches
    }

    private func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return 0 }
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + $1.0 * $1.1 }
        let magnitude = sqrt(lhs.reduce(0.0) { $0 + $1 * $1 }) * sqrt(rhs.reduce(0.0) { $0 + $1 * $1 })
        return magnitude == 0 ? 0 : dot / magnitude
    }
}

enum AskMode: Equatable {
    case thread, workspace, app

    static let appScopeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    var isGlobal: Bool { self == .workspace }
    var isAppWide: Bool { self == .app }
    var title: String { self == .thread ? "Thread Ask" : self == .workspace ? "Workspace Ask" : "Ask AI" }
}

enum AppAskCorpus {
    @MainActor static func transcript(workspaces: [WorkspaceEntity], notes: [NoteEntity]) -> String {
        notes.compactMap { note in
            guard let workspace = workspaces.first(where: { $0.id == note.workspaceID }) else { return nil }
            return note.content.split(whereSeparator: { "\n.!?;。！？；".contains($0) })
                .map { "[Workspace: \(workspace.title)] [Thread: \(note.timeLabel), \(note.id)] \($0)" }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}

private struct AskView: View {
    private enum PendingState: Equatable { case thinking, noMatch, failed(String) }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var turns: [AskTurnEntity]
    let scopeID: UUID
    let mode: AskMode
    let transcript: String
    @ObservedObject var pipeline: OnDevicePipeline
    @State private var question = ""
    @State private var isAnswering = false
    @State private var pendingQuestion: String?
    @State private var pendingEvidence: [String] = []
    @State private var pendingState: PendingState = .thinking
    @State private var pendingUsesKnowledge = false
    @State private var showingAllTurns = false
    @State private var index: ThreadAskIndex

    init(scopeID: UUID, mode: AskMode, transcript: String, pipeline: OnDevicePipeline) {
        let isGlobal = mode.isGlobal
        let isAppWide = mode.isAppWide
        self.scopeID = scopeID
        self.mode = mode
        self.transcript = transcript
        self.pipeline = pipeline
        _turns = Query(
            filter: #Predicate<AskTurnEntity> {
                $0.scopeID == scopeID && $0.isGlobal == isGlobal && $0.isAppWide == isAppWide
            },
            sort: [SortDescriptor(\.createdAt)]
        )
        _index = State(initialValue: ThreadAskIndex(transcript: transcript))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if turns.isEmpty, pendingQuestion == nil {
                    ContentUnavailableView(
                        mode == .app ? "Ask all transcripts" : mode == .workspace ? "Ask this workspace" : "Ask this transcript",
                        systemImage: "questionmark.bubble",
                        description: Text(mode == .app
                            ? "The answer is generated on this iPhone from all workspace transcripts."
                            : mode == .workspace
                                ? "The answer is generated on this iPhone from this workspace's transcripts."
                                : "The answer is generated on this iPhone from this transcript only.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if turns.count > 4, !showingAllTurns {
                                    Button("Show \(turns.count - 4) earlier turns") { showingAllTurns = true }
                                        .font(.caption)
                                }
                                ForEach(visibleTurns) { turn in
                                    VStack(alignment: .leading, spacing: 6) {
                                        askBubble(turn.question, isUser: true)
                                        askBubble(turn.answer, isUser: false)
                                        Text(turn.hasTranscriptSource ? "Transcript-assisted" : "No transcript source")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if let pendingQuestion {
                                    VStack(alignment: .leading, spacing: 6) {
                                        askBubble(pendingQuestion, isUser: true)
                                        pendingAssistantView
                                    }
                                    .id("pendingAsk")
                                }
                            }
                        }
                        .onChange(of: pendingQuestion) { _, value in
                            if value != nil { proxy.scrollTo("pendingAsk", anchor: .bottom) }
                        }
                        .onChange(of: pendingState) { _, _ in
                            proxy.scrollTo("pendingAsk", anchor: .bottom)
                        }
                    }
                }

                HStack {
                    TextField("Ask a question…", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { ask() }
                        .disabled(pendingQuestion != nil)
                    Button { ask() } label: {
                        if isAnswering { ProgressView() } else { Image(systemName: "arrow.up.circle.fill") }
                    }
                    .disabled(pendingQuestion != nil || isAnswering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(mode == .app ? "Ask AI" : mode == .workspace ? "Ask workspace" : "Ask transcript")
                }
            }
            .padding()
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var visibleTurns: ArraySlice<AskTurnEntity> {
        showingAllTurns ? turns[...] : turns.suffix(4)
    }

    @ViewBuilder private func askBubble(_ text: String, isUser: Bool) -> some View {
        if isUser {
            Text(text).font(.callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(10)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(text).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var pendingAssistantView: some View {
        Group {
            switch pendingState {
            case .thinking:
                HStack { ProgressView(); Text("Thinking…") }.font(.callout)
            case .noMatch:
                VStack(alignment: .leading, spacing: 8) {
                    Text("I couldn't find an answer in your transcripts. You can edit your question, or I can try to help using general knowledge.")
                        .font(.callout)
                    HStack {
                        Button("Edit question") { editPendingQuestion() }
                        Button("Use AI knowledge") { answerPendingFromKnowledge() }
                    }.buttonStyle(.bordered)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Button("Retry") { retryPending() }.buttonStyle(.bordered)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pendingAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var pendingAccessibilityLabel: String {
        switch pendingState {
        case .thinking: "Thinking"
        case .noMatch: "I couldn't find an answer in your transcripts. Edit your question, or use AI knowledge."
        case .failed(let message): "Answer failed: \(message). Retry available."
        }
    }

    private func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingQuestion == nil else { return }
        let evidence = index.segments(for: trimmed, limit: mode == .app ? 8 : 3)
        question = ""
        pendingQuestion = trimmed
        pendingEvidence = evidence
        pendingUsesKnowledge = false
        guard !evidence.isEmpty else {
            pendingState = .noMatch
            return
        }
        answerPending()
    }

    private func answerPending() {
        guard let pendingQuestion else { return }
        isAnswering = true
        pendingState = .thinking
        Task { @MainActor in
            defer { isAnswering = false }
            var insertedTurn: AskTurnEntity?
            do {
                let history = turns.map { AskExchange(question: $0.question, answer: $0.answer) }
                let answer = pendingUsesKnowledge
                    ? try await pipeline.answerFromKnowledge(question: pendingQuestion, history: history)
                    : try await pipeline.answer(question: pendingQuestion, evidence: pendingEvidence, history: history)
                let turn = AskTurnEntity(
                    scopeID: scopeID,
                    question: pendingQuestion,
                    answer: answer,
                    isGlobal: mode.isGlobal,
                    isAppWide: mode.isAppWide,
                    hasTranscriptSource: !pendingUsesKnowledge
                )
                insertedTurn = turn
                modelContext.insert(turn)
                try modelContext.save()
                self.pendingQuestion = nil
                pendingEvidence = []
            }
            catch {
                if let insertedTurn { modelContext.delete(insertedTurn) }
                pendingState = .failed(error.localizedDescription)
            }
        }
    }

    private func answerPendingFromKnowledge() {
        pendingUsesKnowledge = true
        answerPending()
    }

    private func retryPending() {
        answerPending()
    }

    private func editPendingQuestion() {
        question = pendingQuestion ?? ""
        pendingQuestion = nil
        pendingEvidence = []
        pendingUsesKnowledge = false
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
                Button(manager.activeModelID == model.id ? "Deselect" : "Use Model") { manager.select(model) }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Delete", role: .destructive) { manager.delete(model) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func progress(for model: LocalModelDescriptor) -> Double {
        if case .downloading(let value) = manager.state(for: model) { return value }
        return 0
    }
}

private struct WhisperModelLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: WhisperModelManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(manager.catalog) { model in
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
                            if case .failed(let message) = manager.state(for: model) {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("On-device transcription")
                } footer: {
                    Text("All options are multilingual whisper.cpp models. Downloads start only when you tap Download; voice recordings and transcripts stay on this iPhone.")
                }
            }
            .navigationTitle("Whisper Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    @ViewBuilder private func status(for model: WhisperModelDescriptor) -> some View {
        switch manager.state(for: model) {
        case .notInstalled: Text("Not installed").foregroundStyle(.secondary)
        case .downloading(let value): Text("\(Int(value * 100))%").foregroundStyle(.tint)
        case .verifying: Text("Verifying…").foregroundStyle(.secondary)
        case .installed:
            Label(manager.activeModelID == model.id ? "Selected" : "Installed",
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHint(message)
        }
    }

    @ViewBuilder private func controls(for model: WhisperModelDescriptor) -> some View {
        switch manager.state(for: model) {
        case .notInstalled, .failed:
            Button("Download Whisper Model") { manager.download(model) }
        case .downloading:
            ProgressView(value: progress(for: model))
            Button("Cancel", role: .destructive) { manager.cancelDownload() }
        case .verifying:
            ProgressView()
        case .installed:
            HStack {
                Button(manager.activeModelID == model.id ? "Deselect" : "Use for Transcription") {
                    manager.select(model)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Delete", role: .destructive) { manager.delete(model) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func progress(for model: WhisperModelDescriptor) -> Double {
        if case .downloading(let value) = manager.state(for: model) { return value }
        return 0
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [WorkspaceEntity.self, NoteEntity.self, AskTurnEntity.self], inMemory: true)
}
#else
struct ContentView: View {
    var body: some View { Text("Speak Space is designed for iPhone.") }
}
#endif
