#if os(iOS)
import AVFoundation
import Combine
import Foundation

enum OnDeviceAIError: LocalizedError {
    case microphoneDenied
    case noRecording
    case emptyTranscript
    case modelUnavailable(String)
    case modelTimedOut
    case audioSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required. Enable it in Settings → Privacy & Security → Microphone."
        case .noRecording:
            return "No recording is available to transcribe."
        case .emptyTranscript:
            return "No speech was detected in the recording."
        case .modelUnavailable(let reason):
            return reason
        case .modelTimedOut:
            return "The local model timed out after 30 seconds. Try again, reload the model, or select a smaller model."
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
        case preparingTranscriptionModel
        case transcribing
        case generating

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .preparingTranscriptionModel: return "Loading selected Whisper model…"
            case .transcribing: return "Transcribing on this iPhone…"
            case .generating: return "Creating summary on this iPhone…"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var textModelRuntimeFailed = false
    @Published private(set) var whisperRuntimeFailed = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?

    var isBusy: Bool { phase != .idle && phase != .recording }

    func startRecording() async throws {
        lastError = nil
        guard WhisperModelStorage.selectedModel() != nil else {
            throw LocalWhisperError.noSelectedModel
        }
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
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
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

    func finishAndProcess() async throws -> ProcessedVoiceNote {
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

        phase = .preparingTranscriptionModel
        await Task.yield()
        phase = .transcribing
        let transcript: String
        do {
            transcript = try await LocalWhisperEngine.shared.transcribe(audioURL: url)
            whisperRuntimeFailed = false
        } catch {
            if let whisperError = error as? LocalWhisperError {
                switch whisperError {
                case .noSelectedModel, .loadFailed, .transcriptionFailed:
                    whisperRuntimeFailed = true
                case .audioDecodeFailed, .emptyTranscript:
                    whisperRuntimeFailed = false
                }
            }
            throw error
        }
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
        guard UserDefaults.standard.string(forKey: LocalModelManager.activeModelKey) != nil else {
            throw OnDeviceAIError.modelUnavailable(
                "Download and select a local model in Local AI Models before creating a \(type.progressLabel)."
            )
        }
        do {
            let output = try await withModelTimeout(seconds: 30) {
                try await LocalLlamaEngine.shared.generate(from: text, type: type)
            }
            textModelRuntimeFailed = false
            return output
        } catch {
            textModelRuntimeFailed = true
            throw error
        }
    }

    private func withModelTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let race = ModelTimeoutRace(continuation: continuation)

            Task {
                do {
                    await race.resolve(.success(try await operation()))
                } catch {
                    await race.resolve(.failure(error))
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(seconds))
                await race.resolve(.failure(OnDeviceAIError.modelTimedOut))
            }
        }
    }

}

private actor ModelTimeoutRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
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

}
#endif
