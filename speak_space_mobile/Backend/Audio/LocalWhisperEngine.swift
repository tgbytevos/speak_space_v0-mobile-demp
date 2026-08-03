#if os(iOS)
import AVFoundation
import Foundation
import whisper

enum LocalWhisperError: LocalizedError {
    case noSelectedModel
    case loadFailed
    case audioDecodeFailed
    case transcriptionFailed
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .noSelectedModel: return "Download and select a Whisper transcription model before recording a voice note."
        case .loadFailed: return "The selected Whisper model could not be loaded. Delete and download it again."
        case .audioDecodeFailed: return "The recording could not be prepared for local transcription."
        case .transcriptionFailed: return "Whisper could not transcribe this recording. Please try again."
        case .emptyTranscript: return "No speech was detected in the recording."
        }
    }
}

actor LocalWhisperEngine {
    static let shared = LocalWhisperEngine()
    private var loadedPath: String?
    private var context: OpaquePointer?

    deinit {
        if let context { whisper_free(context) }
    }

    func transcribe(audioURL: URL) throws -> String {
        let modelURL = try selectedModelURL()
        try loadModelIfNeeded(at: modelURL)
        guard let context else { throw LocalWhisperError.loadFailed }
        let samples = try Self.decodeMonoSamples(from: audioURL)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.n_threads = Int32(max(1, min(6, ProcessInfo.processInfo.processorCount - 2)))

        let result = "auto".withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard result == 0 else { throw LocalWhisperError.transcriptionFailed }

        var output = ""
        for index in 0..<whisper_full_n_segments(context) {
            output += String(cString: whisper_full_get_segment_text(context, index))
        }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocalWhisperError.emptyTranscript }
        return cleaned
    }

    private func selectedModelURL() throws -> URL {
        guard let descriptor = WhisperModelStorage.selectedModel() else { throw LocalWhisperError.noSelectedModel }
        let url = WhisperModelStorage.modelURL(for: descriptor)
        return url
    }

    private func loadModelIfNeeded(at url: URL) throws {
        if loadedPath == url.path, context != nil { return }
        if let context { whisper_free(context) }
        var params = whisper_context_default_params()
#if targetEnvironment(simulator)
        params.use_gpu = false
#else
        params.flash_attn = true
#endif
        guard let loaded = whisper_init_from_file_with_params(url.path, params) else {
            context = nil
            loadedPath = nil
            throw LocalWhisperError.loadFailed
        }
        context = loaded
        loadedPath = url.path
    }

    nonisolated private static func decodeMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.channelCount > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LocalWhisperError.audioDecodeFailed
        }
        try file.read(into: buffer)
        guard file.processingFormat.sampleRate == 16_000,
              let channels = buffer.floatChannelData else { throw LocalWhisperError.audioDecodeFailed }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }
}
#endif
