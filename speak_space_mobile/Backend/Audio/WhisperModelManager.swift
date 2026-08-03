#if os(iOS)
import Combine
import CryptoKit
import Foundation

struct WhisperModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let detail: String
    let filename: String
    let downloadURL: URL
    let expectedBytes: Int64
    let sha256: String

    nonisolated static let tiny = WhisperModelDescriptor(
        id: "whisper-tiny-q5-1-multilingual",
        displayName: "Whisper Tiny",
        detail: "Multilingual · 31 MB · Fastest",
        filename: "ggml-tiny-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin?download=true")!,
        expectedBytes: 32_152_673,
        sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
    )

    nonisolated static let base = WhisperModelDescriptor(
        id: "whisper-base-q5-1-multilingual",
        displayName: "Whisper Base",
        detail: "Multilingual · 57 MB · Balanced",
        filename: "ggml-base-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin?download=true")!,
        expectedBytes: 59_707_625,
        sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
    )

    nonisolated static let small = WhisperModelDescriptor(
        id: "whisper-small-q5-1-multilingual",
        displayName: "Whisper Small",
        detail: "Multilingual · 181 MB · More accurate",
        filename: "ggml-small-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin?download=true")!,
        expectedBytes: 190_085_487,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
    )

    nonisolated static let catalog: [WhisperModelDescriptor] = [.tiny, .base, .small]
}

enum WhisperModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case verifying
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum WhisperModelStorage {
    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    nonisolated static func modelURL(
        for model: WhisperModelDescriptor,
        in directory: URL = modelsDirectory
    ) -> URL {
        directory.appendingPathComponent(model.filename, isDirectory: false)
    }

    nonisolated static func isInstalled(
        _ model: WhisperModelDescriptor,
        in directory: URL = modelsDirectory
    ) -> Bool {
        let url = modelURL(for: model, in: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
        return size == model.expectedBytes
    }

    nonisolated static func selectedModel() -> WhisperModelDescriptor? {
        guard let activeID = UserDefaults.standard.string(forKey: WhisperModelManager.activeModelKey),
              let model = WhisperModelDescriptor.catalog.first(where: { $0.id == activeID }),
              isInstalled(model) else { return nil }
        return model
    }
}

@MainActor
final class WhisperModelManager: NSObject, ObservableObject {
    nonisolated static let activeModelKey = "activeWhisperModelID"

    @Published private(set) var states: [String: WhisperModelState] = [:]
    @Published private(set) var activeModelID: String?

    let catalog = WhisperModelDescriptor.catalog
    private var activeDownloadID: String?
    private var downloadTask: URLSessionDownloadTask?
    private lazy var downloadSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    override init() {
        activeModelID = UserDefaults.standard.string(forKey: Self.activeModelKey)
        super.init()
        refreshInstalledModels()
    }

    var activeModel: WhisperModelDescriptor? {
        guard let activeModelID else { return nil }
        return catalog.first { $0.id == activeModelID }
    }

    func state(for model: WhisperModelDescriptor) -> WhisperModelState {
        states[model.id] ?? .notInstalled
    }

    func modelURL(for model: WhisperModelDescriptor) -> URL {
        WhisperModelStorage.modelURL(for: model)
    }

    func select(_ model: WhisperModelDescriptor) {
        guard WhisperModelStorage.isInstalled(model) else {
            states[model.id] = .failed("The downloaded model file is missing or incomplete. Download it again.")
            if activeModelID == model.id {
                activeModelID = nil
                UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
            }
            return
        }
        states[model.id] = .installed
        activeModelID = model.id
        UserDefaults.standard.set(model.id, forKey: Self.activeModelKey)
    }

    func download(_ model: WhisperModelDescriptor) {
        guard downloadTask == nil else { return }
        do { try FileManager.default.createDirectory(at: WhisperModelStorage.modelsDirectory, withIntermediateDirectories: true) }
        catch {
            states[model.id] = .failed(error.localizedDescription)
            return
        }
        activeDownloadID = model.id
        states[model.id] = .downloading(0)
        downloadTask = downloadSession.downloadTask(with: model.downloadURL)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        if let activeDownloadID { states[activeDownloadID] = .notInstalled }
        downloadTask = nil
        activeDownloadID = nil
    }

    func delete(_ model: WhisperModelDescriptor) {
        guard state(for: model).isInstalled else { return }
        try? FileManager.default.removeItem(at: modelURL(for: model))
        states[model.id] = .notInstalled
        if activeModelID == model.id {
            activeModelID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }
    }

    func refreshInstalledModels() {
        for model in catalog {
            states[model.id] = WhisperModelStorage.isInstalled(model) ? .installed : .notInstalled
        }
        if let activeModelID, !(states[activeModelID]?.isInstalled ?? false) {
            self.activeModelID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }
    }

    private func finishDownload(tempURL: URL, model: WhisperModelDescriptor) async {
        states[model.id] = .verifying
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size == model.expectedBytes else { throw WhisperModelFileError.invalidSize }
            let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: tempURL) }.value
            guard digest == model.sha256 else { throw WhisperModelFileError.invalidChecksum }

            try FileManager.default.createDirectory(at: WhisperModelStorage.modelsDirectory, withIntermediateDirectories: true)
            let destination = modelURL(for: model)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var durableDestination = destination
            try durableDestination.setResourceValues(resourceValues)
            guard WhisperModelStorage.isInstalled(model) else { throw WhisperModelFileError.installFailed }
            states[model.id] = .installed
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            states[model.id] = .failed(error.localizedDescription)
        }
        downloadTask = nil
        activeDownloadID = nil
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 4 * 1_024 * 1_024)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension WhisperModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let id = activeDownloadID else { return }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : catalog.first(where: { $0.id == id })?.expectedBytes ?? 1
            states[id] = .downloading(min(1, Double(totalBytesWritten) / Double(expected)))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let safeCopy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do { try FileManager.default.moveItem(at: location, to: safeCopy) }
        catch {
            Task { @MainActor in
                if let id = activeDownloadID { states[id] = .failed(error.localizedDescription) }
                self.downloadTask = nil
                activeDownloadID = nil
            }
            return
        }
        Task { @MainActor in
            guard let id = activeDownloadID, let model = catalog.first(where: { $0.id == id }) else { return }
            await finishDownload(tempURL: safeCopy, model: model)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            if (error as NSError).code != NSURLErrorCancelled, let id = activeDownloadID {
                states[id] = .failed(error.localizedDescription)
            }
            self.downloadTask = nil
            activeDownloadID = nil
        }
    }
}

private enum WhisperModelFileError: LocalizedError {
    case invalidSize
    case invalidChecksum
    case installFailed

    var errorDescription: String? {
        switch self {
        case .invalidSize: return "The downloaded Whisper model has an unexpected size."
        case .invalidChecksum: return "The downloaded Whisper model failed verification."
        case .installFailed: return "The Whisper model could not be saved on this iPhone."
        }
    }
}
#endif
