#if os(iOS)
import AVFoundation
import Combine
import Foundation
import FoundationModels
import Speech

@Generable(description: "Structured information extracted from a voice note")
struct GeneratedNoteContent {
    @Guide(description: "A concise title in the same language as the transcript")
    var title: String

    @Guide(description: "A factual two-sentence summary in the same language as the transcript")
    var summary: String

    @Guide(description: "Concrete action items only. Return an empty list when there are none", .maximumCount(6))
    var todos: [String]
}

enum OnDeviceAIError: LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case noRecording
    case unsupportedLocale
    case emptyTranscript
    case modelUnavailable(String)
    case audioSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required. Enable it in Settings → Privacy & Security → Microphone."
        case .speechRecognitionDenied:
            return "Speech recognition access is required. Enable it in Settings → Privacy & Security → Speech Recognition."
        case .noRecording:
            return "No recording is available to transcribe."
        case .unsupportedLocale:
            return "On-device transcription does not support the current language."
        case .emptyTranscript:
            return "No speech was detected in the recording."
        case .modelUnavailable(let reason):
            return reason
        case .audioSetupFailed(let step):
            return "Audio setup failed while \(step). Please try again."
        }
    }
}

enum NoteGenerationType: String, Sendable {
    case summary
    case todo

    var progressLabel: String { self == .summary ? "summary" : "to-do list" }
}

@MainActor
final class OnDevicePipeline: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case preparingSpeechModel
        case transcribing
        case generating

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .preparingSpeechModel: return "Preparing offline speech model…"
            case .transcribing: return "Transcribing on this iPhone…"
            case .generating: return "Creating summary on this iPhone…"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?
    @Published private(set) var audioLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?

    var isBusy: Bool { phase != .idle && phase != .recording }

    func startRecording() async throws {
        lastError = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw OnDeviceAIError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` and `.duckOthers` are playback-oriented. Combining
            // them with a record-only session returns paramErr (-50) on devices.
            try session.setCategory(.record, mode: .measurement, options: [])
        } catch {
            throw OnDeviceAIError.audioSetupFailed("configuring the recording session (\(error.localizedDescription))")
        }
        do {
            try session.setActive(true)
        } catch {
            throw OnDeviceAIError.audioSetupFailed("activating the recording session (\(error.localizedDescription))")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw OnDeviceAIError.audioSetupFailed("creating the audio recorder (\(error.localizedDescription))")
        }
        recorder.prepareToRecord()
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw OnDeviceAIError.noRecording }

        self.recorder = recorder
        recordingURL = url
        phase = .recording
        startMetering()
    }

    func cancelRecording() {
        stopMetering()
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func finishAndProcess(locale requestedLocale: Locale = .current) async throws -> ProcessedVoiceNote {
        stopMetering()
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = recordingURL else { throw OnDeviceAIError.noRecording }
        defer {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            phase = .idle
        }

        let transcript = try await transcribe(url: url, locale: requestedLocale)
        let savedAudioURL = try persistRecording(at: url)
        return ProcessedVoiceNote(
            transcript: transcript,
            title: transcript.suggestedNoteTitle,
            summary: nil,
            todos: [],
            audioURL: savedAudioURL
        )
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let decibels = max(-50, Double(recorder.averagePower(forChannel: 0)))
                self.audioLevel = max(0.03, min(1, (decibels + 50) / 50))
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
    }

    private func persistRecording(at temporaryURL: URL) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
 
    func generateNote(from text: String, type: NoteGenerationType) async throws -> String {
        phase = .generating
        defer { phase = .idle }
        if UserDefaults.standard.string(forKey: LocalModelManager.activeModelKey) != nil {
            return try await LocalLlamaEngine.shared.generate(from: text, type: type)
        }
        let generated = try await generate(from: text)
        switch type {
        case .summary:
            return generated.summary
        case .todo:
            return generated.todos.isEmpty
                ? "No actionable items found."
                : generated.todos.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
    }

    private func transcribe(url: URL, locale requestedLocale: Locale) async throws -> String {
        phase = .preparingSpeechModel
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        guard authorization == .authorized else { throw OnDeviceAIError.speechRecognitionDenied }
        guard SpeechTranscriber.isAvailable else { throw OnDeviceAIError.unsupportedLocale }
        let requestedMatch = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        let englishFallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = requestedMatch ?? englishFallback else {
            throw OnDeviceAIError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        phase = .transcribing
        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { () throws -> [String] in
            var chunks: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { chunks.append(text) }
            }
            return chunks
        }

        do {
            let lastTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastTime {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let transcript = try await resultTask.value.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw OnDeviceAIError.emptyTranscript }
            return transcript
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func generate(from transcript: String) async throws -> GeneratedNoteContent {
        phase = .generating
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw OnDeviceAIError.modelUnavailable("This iPhone does not support Apple Intelligence. The transcript can still be saved without an AI summary.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw OnDeviceAIError.modelUnavailable("Turn on Apple Intelligence in Settings to create summaries locally.")
        case .unavailable(.modelNotReady):
            throw OnDeviceAIError.modelUnavailable("The on-device language model is still downloading. Try again when it is ready.")
        case .unavailable:
            throw OnDeviceAIError.modelUnavailable("The on-device language model is currently unavailable.")
        }

        let chunks = transcript.chunked(maxCharacters: 2_400)
        var generatedChunks: [GeneratedNoteContent] = []
        for (index, chunk) in chunks.enumerated() {
            let context = chunks.count == 1 ? "voice note" : "part \(index + 1) of \(chunks.count)"
            generatedChunks.append(try await generateSingle(from: chunk, context: context, model: model))
        }
        guard generatedChunks.count > 1 else { return generatedChunks[0] }

        let combined = generatedChunks.enumerated().map { index, item in
            let todos = item.todos.isEmpty ? "None" : item.todos.joined(separator: "; ")
            return "Part \(index + 1) summary: \(item.summary)\nAction items: \(todos)"
        }.joined(separator: "\n\n")
        return try await generateSingle(from: combined, context: "combined summaries of a longer recording", model: model)
    }

    private func generateSingle(
        from text: String,
        context: String,
        model: SystemLanguageModel
    ) async throws -> GeneratedNoteContent {
        let session = LanguageModelSession(
            model: model,
            instructions: "You organize voice notes. Never invent facts. Preserve the transcript language. Return short, useful output."
        )
        let response = try await session.respond(
            to: "Create a title, summary, and action items from this \(context):\n\n\(text)",
            generating: GeneratedNoteContent.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 500)
        )
        return response.content
    }
}

struct ProcessedVoiceNote: Sendable {
    let transcript: String
    let title: String
    let summary: String?
    let todos: [String]
    let audioURL: URL
}

private extension String {
    var suggestedNoteTitle: String {
        let firstLine = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Voice Note" }
        return String(trimmed.prefix(36))
    }

    func chunked(maxCharacters: Int) -> [String] {
        guard count > maxCharacters else { return [self] }
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let proposedEnd = index(start, offsetBy: maxCharacters, limitedBy: endIndex) ?? endIndex
            var end = proposedEnd
            if proposedEnd < endIndex,
               let boundary = self[start..<proposedEnd].lastIndex(where: { ".!?。！？\n".contains($0) }),
               distance(from: start, to: boundary) > maxCharacters / 2 {
                end = index(after: boundary)
            }
            let chunk = self[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            start = end
        }
        return chunks
    }
}
#endif
