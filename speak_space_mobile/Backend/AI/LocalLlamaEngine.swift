#if os(iOS)
import Foundation
import llama

enum LocalLlamaError: LocalizedError {
    case noSelectedModel
    case loadFailed
    case contextFailed
    case tokenizeFailed
    case decodeFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noSelectedModel: return "Download and select a local model first."
        case .loadFailed: return "Gemma could not be loaded. Make sure the model download completed successfully."
        case .contextFailed: return "There is not enough free memory to start Gemma. Close other apps and try again."
        case .tokenizeFailed: return "The note could not be prepared for Gemma."
        case .decodeFailed: return "Gemma stopped while generating the response."
        case .invalidResponse: return "Gemma returned an incomplete response. Please try again."
        }
    }
}

actor LocalLlamaEngine {
    static let shared = LocalLlamaEngine()
    private var loadedPath: String?
    private var model: OpaquePointer?

    deinit {
        if let model { llama_model_free(model) }
    }

    func generate(from text: String, type: NoteGenerationType) throws -> String {
        let modelURL = try selectedModelURL()
        try loadModelIfNeeded(at: modelURL)
        guard let model, let vocab = llama_model_get_vocab(model) else { throw LocalLlamaError.loadFailed }

        // Keep enough headroom for the formatted response on memory-constrained phones.
        let clipped = String(text.prefix(3_000))
        let instruction: String
        switch type {
        case .summary:
            instruction = """
            Provide a structured summary of the note below. Follow this exact format. Output nothing else. Preserve the note's language and never invent facts.

            ## Summary
            - **Overview**: [one sentence on the general purpose]
            - **Key Discussion**: [one sentence on the main topic or discussion]
            - **Outcome**: [one sentence on the final decision or next step]

            NOTE:
            \(clipped)
            """
        case .todo:
            instruction = """
            You are a task extraction assistant. Read only the note below and extract all actionable to-do items. Output a numbered list and nothing else. Each item must start with a verb and be concrete enough to act on. Never invent tasks. If no actions are found, output exactly: No actionable items found.

            NOTE:
            \(clipped)
            """
        }
        let prompt = "<bos><start_of_turn>user\n\(instruction)<end_of_turn>\n<start_of_turn>model\n"
        let tokens = try tokenize(prompt, vocab: vocab)

        var params = llama_context_default_params()
        params.n_ctx = UInt32(max(2_048, min(4_096, tokens.count + 700)))
        params.n_batch = UInt32(max(tokens.count, 32))
        params.n_threads = 4
        params.n_threads_batch = 4
        guard let context = llama_init_from_model(model, params) else { throw LocalLlamaError.contextFailed }
        defer { llama_free(context) }

        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else { throw LocalLlamaError.contextFailed }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        var batch = llama_batch_init(Int32(max(tokens.count, 1)), 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(tokens.count)
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?[0] = 0
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        guard llama_decode(context, batch) == 0 else { throw LocalLlamaError.decodeFailed }

        var output = ""
        var utf8Buffer: [CChar] = []
        var position = Int32(tokens.count)
        for _ in 0..<500 {
            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) { break }
            if let piece = tokenPiece(token, vocab: vocab, buffer: &utf8Buffer) { output += piece }
            if output.contains("<end_of_turn>") { break }

            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            batch.seq_id[0]?[0] = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else { throw LocalLlamaError.decodeFailed }
            position += 1
        }
        return try clean(output)
    }

    private func selectedModelURL() throws -> URL {
        guard UserDefaults.standard.string(forKey: LocalModelManager.activeModelKey) != nil else {
            throw LocalLlamaError.noSelectedModel
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalModels", isDirectory: true)
        let url = directory.appendingPathComponent(LocalModelDescriptor.gemma3OneB.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalLlamaError.noSelectedModel }
        return url
    }

    private func loadModelIfNeeded(at url: URL) throws {
        if loadedPath == url.path, model != nil { return }
        if let model { llama_model_free(model) }
        llama_backend_init()
        var params = llama_model_default_params()
        params.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(url.path, params) else {
            model = nil
            loadedPath = nil
            throw LocalLlamaError.loadFailed
        }
        model = loaded
        loadedPath = url.path
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let capacity = text.utf8.count + 32
        var tokens = [llama_token](repeating: 0, count: capacity)
        let count = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(capacity), true, true)
        guard count > 0 else { throw LocalLlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer, buffer: inout [CChar]) -> String? {
        var piece = [CChar](repeating: 0, count: 16)
        var count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
        if count < 0 {
            piece = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
        }
        guard count > 0 else { return nil }
        buffer.append(contentsOf: piece.prefix(Int(count)))
        let data = Data(buffer.map { UInt8(bitPattern: $0) })
        if let string = String(data: data, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: true)
            return string
        }
        if buffer.count > 4 { buffer.removeAll(keepingCapacity: true) }
        return nil
    }

    private func clean(_ raw: String) throws -> String {
        var cleaned = raw.replacingOccurrences(of: "<end_of_turn>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { throw LocalLlamaError.invalidResponse }
        return cleaned
    }
}
#endif
