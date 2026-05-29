import Foundation
import llama

enum LlamaError: Error {
    case modelLoadFailed(String)
    case contextInitFailed
    case decodeFailed(Int32)
    case invalidState
}

final class LlamaContext {
    private static var backendInitialized = false

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var temporaryInvalidBytes: [CChar] = []

    private(set) var nVocab: Int32 = 0
    private(set) var contextSize: Int = 2048

    deinit {
        cleanup()
    }

    func cleanup() {
        if let context = context {
            llama_free(context)
            self.context = nil
        }
        if let model = model {
            llama_free_model(model)
            self.model = nil
        }
        if LlamaContext.backendInitialized {
            llama_backend_free()
            LlamaContext.backendInitialized = false
        }
    }

    func loadModel(path: String) throws {
        if !LlamaContext.backendInitialized {
            llama_backend_init()
            LlamaContext.backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.use_mmap = llama_supports_mmap()
        modelParams.use_mlock = llama_supports_mlock()
        modelParams.use_extra_bufts = true

        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = llama_supports_gpu_offload() ? -1 : 0
        #endif

        guard let model = llama_load_model_from_file(path, modelParams) else {
            throw LlamaError.modelLoadFailed("Could not load model at \(path)")
        }
        self.model = model

        self.vocab = llama_model_get_vocab(model)
        self.nVocab = llama_vocab_n_tokens(vocab)

        let nThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_batch = 512
        ctxParams.n_ubatch = 256
        ctxParams.n_seq_max = 2
        ctxParams.n_threads = Int32(nThreads)
        ctxParams.n_threads_batch = Int32(nThreads)
        ctxParams.offload_kqv = true
        ctxParams.op_offload = true
        ctxParams.kv_unified = true
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        ctxParams.no_perf = true

        guard let context = llama_new_context_with_model(model, ctxParams) else {
            throw LlamaError.contextInitFailed
        }
        self.context = context
        self.contextSize = Int(ctxParams.n_ctx)

        if let info = llama_print_system_info() {
            print(String(cString: info))
        }
        print("Model loaded. Vocab size: \(nVocab)")
    }

    func tokenize(text: String, addBos: Bool, special: Bool = false) -> [Int32] {
        guard let vocab = vocab else { return [] }

        var maxTokens = max(512, text.utf8.count + 32)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokens)

        let textBytes = text.utf8CString
        var nTokens = textBytes.withUnsafeBufferPointer { buffer in
            llama_tokenize(
                vocab,
                buffer.baseAddress,
                Int32(buffer.count - 1),
                tokens,
                Int32(maxTokens),
                addBos,
                special
            )
        }

        if nTokens < 0 {
            tokens.deallocate()
            maxTokens = Int(-nTokens)
            let resizedTokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokens)
            defer { resizedTokens.deallocate() }

            nTokens = textBytes.withUnsafeBufferPointer { buffer in
                llama_tokenize(
                    vocab,
                    buffer.baseAddress,
                    Int32(buffer.count - 1),
                    resizedTokens,
                    Int32(maxTokens),
                    addBos,
                    special
                )
            }

            guard nTokens >= 0 else { return [] }

            var result: [Int32] = []
            result.reserveCapacity(Int(nTokens))
            for i in 0..<Int(nTokens) {
                result.append(resizedTokens[i])
            }
            return result
        }

        defer { tokens.deallocate() }

        var result: [Int32] = []
        result.reserveCapacity(Int(nTokens))
        for i in 0..<Int(nTokens) {
            result.append(tokens[i])
        }
        return result
    }

    func tokenToText(_ tokenId: Int32) -> String {
        guard let vocab = vocab else { return "" }

        let bufferSize = 128
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let nChars = llama_token_to_piece(
            vocab,
            tokenId,
            buffer,
            Int32(bufferSize),
            0,
            false
        )

        if nChars > 0 && nChars < bufferSize {
            return String(cString: buffer, encoding: .utf8) ?? ""
        }
        return ""
    }

    func tokenToTextAccumulating(_ tokenId: Int32) -> String {
        guard let vocab = vocab else { return "" }

        let bufferSize = 128
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let nChars = llama_token_to_piece(
            vocab,
            tokenId,
            buffer,
            Int32(bufferSize),
            0,
            false
        )

        if nChars > 0 && nChars < bufferSize {
            let tokenBytes = Array(UnsafeBufferPointer(start: buffer, count: Int(nChars)))
            temporaryInvalidBytes.append(contentsOf: tokenBytes)

            if let string = String(validatingUTF8: temporaryInvalidBytes + [0]) {
                temporaryInvalidBytes.removeAll()
                return string
            }

            for suffixLen in (1..<temporaryInvalidBytes.count).reversed() {
                let suffix = Array(temporaryInvalidBytes.suffix(suffixLen))
                if let string = String(validatingUTF8: suffix + [0]) {
                    temporaryInvalidBytes.removeAll()
                    return string
                }
            }
            return ""
        }

        return ""
    }

    func clearInvalidBytes() {
        temporaryInvalidBytes.removeAll()
    }

    func decode(tokens: [Int32], positions: [Int32], seqId: Int32, logitsOnLast: Bool) throws {
        guard let context = context else { throw LlamaError.invalidState }
        guard tokens.count == positions.count else { throw LlamaError.invalidState }

        let batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        var batchMutable = batch
        batchMutable.n_tokens = Int32(tokens.count)

        for i in 0..<tokens.count {
            batchMutable.token[i] = tokens[i]
            batchMutable.pos[i] = positions[i]
            batchMutable.n_seq_id[i] = 1
            batchMutable.seq_id[i]![0] = seqId
            batchMutable.logits[i] = (logitsOnLast && i == tokens.count - 1) ? 1 : 0
        }

        let result = llama_decode(context, batchMutable)
        if result != 0 {
            throw LlamaError.decodeFailed(result)
        }
    }

    func clearSequence(seqId: Int32, from: Int32 = 0) -> Bool {
        guard let context = context else { return false }
        let memory = llama_get_memory(context)
        return llama_memory_seq_rm(memory, seqId, from, -1)
    }

    func isEog(_ tokenId: Int32) -> Bool {
        guard let vocab = vocab else { return false }
        return llama_vocab_is_eog(vocab, tokenId)
    }

    func synchronize() {
        guard let context = context else { return }
        llama_synchronize(context)
    }

    var rawContext: OpaquePointer? {
        context
    }

    var eogTokenIds: [Int32] {
        guard let vocab = vocab else { return [] }
        return (0..<nVocab).filter { llama_vocab_is_eog(vocab, $0) }
    }

    var controlTokenIds: [Int32] {
        guard vocab != nil else { return [] }
        return (0..<nVocab).filter {
            let text = tokenToText($0)
            return text.contains("<") || text.contains(">")
        }
    }
}
