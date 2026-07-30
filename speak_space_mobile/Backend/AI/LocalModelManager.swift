#if os(iOS)
import Combine
import CryptoKit
import Foundation

struct LocalModelDescriptor: Identifiable, Hashable, Sendable {
    enum PromptFormat: Hashable, Sendable {
        case gemma
        case qwen
        case llama
    }

    let id: String
    let displayName: String
    let detail: String
    let filename: String
    let downloadURL: URL
    let expectedBytes: Int64
    let sha256: String
    let promptFormat: PromptFormat

    nonisolated static let gemma3OneB = LocalModelDescriptor(
        id: "gemma-3-1b-it-q4km",
        displayName: "Gemma 3 1B",
        detail: "Q4_K_M · Multilingual · 769 MB",
        filename: "gemma-3-1b-it-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf?download=true")!,
        expectedBytes: 806_058_240,
        sha256: "8ccc5cd1f1b3602548715ae25a66ed73fd5dc68a210412eea643eb20eb75a135",
        promptFormat: .gemma
    )

    nonisolated static let qwenHalfB = LocalModelDescriptor(
        id: "qwen-2.5-0.5b-instruct-q4km",
        displayName: "Qwen 2.5 0.5B",
        detail: "Q4_K_M · Multilingual · 469 MB · Fastest",
        filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true")!,
        expectedBytes: 491_400_032,
        sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        promptFormat: .qwen
    )

    nonisolated static let llamaOneB = LocalModelDescriptor(
        id: "llama-3.2-1b-instruct-q4km",
        displayName: "Llama 3.2 1B",
        detail: "Q4_K_M · 8 languages · 770 MB · English focused",
        filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true")!,
        expectedBytes: 807_694_464,
        sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
        promptFormat: .llama
    )

    nonisolated static let qwenOneAndHalfB = LocalModelDescriptor(
        id: "qwen-2.5-1.5b-instruct-q4km",
        displayName: "Qwen 2.5 1.5B",
        detail: "Q4_K_M · Multilingual · 1.04 GB · Higher quality",
        filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true")!,
        expectedBytes: 1_117_320_736,
        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
        promptFormat: .qwen
    )
}

enum LocalModelState: Equatable, Sendable {
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

@MainActor
final class LocalModelManager: NSObject, ObservableObject {
    nonisolated static let activeModelKey = "activeLocalModelID"

    @Published private(set) var states: [String: LocalModelState] = [:]
    @Published private(set) var activeModelID: String?

    let catalog: [LocalModelDescriptor] = [
        .qwenHalfB,
        .gemma3OneB,
        .llamaOneB,
        .qwenOneAndHalfB
    ]
    private var activeDownloadID: String?
    private var downloadTask: URLSessionDownloadTask?
    private lazy var downloadSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    override init() {
        activeModelID = UserDefaults.standard.string(forKey: Self.activeModelKey)
        super.init()
        refreshInstalledModels()
    }

    var activeModel: LocalModelDescriptor? {
        guard let activeModelID else { return nil }
        return catalog.first { $0.id == activeModelID }
    }

    var compactStatusLabel: String {
        guard let model = activeModel else { return "No local model" }
        switch state(for: model) {
        case .notInstalled: return "Model not installed"
        case .downloading(let progress): return "\(Int(progress * 100))%"
        case .verifying: return "Verifying…"
        case .installed: return model.displayName
        case .failed: return "Model error"
        }
    }

    func state(for model: LocalModelDescriptor) -> LocalModelState {
        states[model.id] ?? .notInstalled
    }

    func modelURL(for model: LocalModelDescriptor) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    func select(_ model: LocalModelDescriptor) {
        guard state(for: model).isInstalled else { return }
        activeModelID = model.id
        UserDefaults.standard.set(model.id, forKey: Self.activeModelKey)
    }

    func download(_ model: LocalModelDescriptor) {
        guard downloadTask == nil else { return }
        do { try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true) }
        catch {
            states[model.id] = .failed(error.localizedDescription)
            return
        }
        activeDownloadID = model.id
        states[model.id] = .downloading(0)
        let task = downloadSession.downloadTask(with: model.downloadURL)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        if let activeDownloadID { states[activeDownloadID] = .notInstalled }
        downloadTask = nil
        activeDownloadID = nil
    }

    func delete(_ model: LocalModelDescriptor) {
        guard state(for: model).isInstalled else { return }
        try? FileManager.default.removeItem(at: modelURL(for: model))
        states[model.id] = .notInstalled
        if activeModelID == model.id {
            activeModelID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }
    }

    private var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalModels", isDirectory: true)
    }

    private func refreshInstalledModels() {
        for model in catalog {
            states[model.id] = FileManager.default.fileExists(atPath: modelURL(for: model).path)
                ? .installed : .notInstalled
        }
        if let activeModelID,
           !(states[activeModelID]?.isInstalled ?? false) {
            self.activeModelID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
        }
    }

    private func finishDownload(tempURL: URL, model: LocalModelDescriptor) async {
        states[model.id] = .verifying
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size == model.expectedBytes else {
                throw ModelFileError.invalidSize(expected: model.expectedBytes, actual: size)
            }
            let digest = try await Task.detached(priority: .utility) {
                try Self.sha256(of: tempURL)
            }.value
            guard digest == model.sha256 else { throw ModelFileError.invalidChecksum }

            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let destination = modelURL(for: model)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            states[model.id] = .installed
            select(model)
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

extension LocalModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let id = activeDownloadID else { return }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : catalog.first(where: { $0.id == id })?.expectedBytes ?? 1
            states[id] = .downloading(min(1, Double(totalBytesWritten) / Double(expected)))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let safeCopy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.moveItem(at: location, to: safeCopy)
        } catch {
            Task { @MainActor in
                if let id = activeDownloadID { states[id] = .failed(error.localizedDescription) }
                self.downloadTask = nil
                activeDownloadID = nil
            }
            return
        }
        Task { @MainActor in
            guard let id = activeDownloadID,
                  let model = catalog.first(where: { $0.id == id }) else { return }
            await finishDownload(tempURL: safeCopy, model: model)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            if (error as NSError).code != NSURLErrorCancelled,
               let id = activeDownloadID {
                states[id] = .failed(error.localizedDescription)
            }
            self.downloadTask = nil
            activeDownloadID = nil
        }
    }
}

private enum ModelFileError: LocalizedError {
    case invalidSize(expected: Int64, actual: Int64)
    case invalidChecksum

    var errorDescription: String? {
        switch self {
        case .invalidSize(let expected, let actual):
            return "Model download is incomplete (expected \(expected) bytes, received \(actual))."
        case .invalidChecksum:
            return "Model security check failed. Delete it and download again."
        }
    }
}
#endif
