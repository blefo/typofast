import Foundation
import llama

struct CompletionMetrics {
    var totalTime: Double = 0
    var promptProcessingTime: Double = 0
    var generationTime: Double = 0
    var ttft: Double = 0
    var tokensGenerated: Int = 0
    var tokensPerSecond: Double = 0
    var promptTokensProcessed: Int = 0
    var cachedTokensReused: Int = 0
}

private struct SamplingConfig {
    var maxSuggestTokens: Int = 8
    var temperature: Float = 0.15
    var topK: Int32 = 20
    var topP: Float = 0.9
    var minP: Float = 0.05
    var repeatPenalty: Float = 1.5
    var repeatLastN: Int32 = 0
    var frequencyPenalty: Float = 0.0
    var presencePenalty: Float = 0.0
    var deterministic: Bool = true
    var seed: UInt32 = 0
}

private final class LlamaSamplerChain {
    private var chain: UnsafeMutablePointer<llama_sampler>?
    private let config: SamplingConfig

    init(config: SamplingConfig) {
        self.config = config
        let params = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(params)

        if config.repeatLastN != 0 || config.repeatPenalty != 1.0 || config.frequencyPenalty != 0.0 || config.presencePenalty != 0.0 {
            let penalties = llama_sampler_init_penalties(
                config.repeatLastN,
                config.repeatPenalty,
                config.frequencyPenalty,
                config.presencePenalty
            )
        llama_sampler_chain_add(chain, penalties)
        }

        if config.topK > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(config.topK))
        }
        if config.topP < 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(config.topP, 1))
        }
        if config.minP > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(config.minP, 1))
        }
        if config.temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature))
        }

        if config.deterministic {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_dist(config.seed))
        }

        self.chain = chain
    }

    deinit {
        if let chain = chain {
            llama_sampler_free(chain)
        }
    }

    func reset() {
        if let chain = chain {
            llama_sampler_reset(chain)
        }
    }

    func accept(_ token: Int32) {
        if let chain = chain {
            llama_sampler_accept(chain, token)
        }
    }

    func sample(context: OpaquePointer?) -> Int32 {
        guard let chain = chain, let context = context else { return -1 }
        return llama_sampler_sample(chain, context, -1)
    }
}

actor AutocompleteEngine {
    private let llama = LlamaContext()
    private let promptSeqId: Int32 = 0
    private let genSeqId: Int32 = 1
    private var promptTokens: [Int32] = []
    private var generationId: Int = 0
    private let sampling = SamplingConfig()
    private var sampler: LlamaSamplerChain?

    func loadModel(path: String) async throws {
        try llama.loadModel(path: path)
        sampler = LlamaSamplerChain(config: sampling)
    }

    func getCompletion(prompt: String, inputText: String, maxTokens: Int = 10) async -> (String, CompletionMetrics) {
        generationId += 1
        let myGenerationId = generationId

        let startTime = Date()
        var metrics = CompletionMetrics()
        var ttft: Double? = nil

        let tokens = llama.tokenize(text: prompt, addBos: true)
        guard !tokens.isEmpty else { return ("", metrics) }

        let commonPrefix = findCommonPrefixLength(newTokens: tokens)
        metrics.cachedTokensReused = commonPrefix

        if commonPrefix < promptTokens.count {
            _ = llama.clearSequence(seqId: promptSeqId, from: Int32(commonPrefix))
            promptTokens = Array(promptTokens.prefix(commonPrefix))
        }

        let promptStart = Date()
        if tokens.count > commonPrefix {
            let tokensToAdd = Array(tokens[commonPrefix...])
            let positions = tokensToAdd.indices.map { Int32(commonPrefix + $0) }
            do {
                try llama.decode(
                    tokens: tokensToAdd,
                    positions: positions,
                    seqId: promptSeqId,
                    logitsOnLast: true
                )
            } catch {
                return ("", metrics)
            }
        }
        metrics.promptProcessingTime = Date().timeIntervalSince(promptStart)
        metrics.promptTokensProcessed = tokens.count - commonPrefix

        promptTokens = tokens

        guard generationId == myGenerationId else {
            return ("", metrics)
        }

        llama.clearInvalidBytes()
        _ = llama.clearSequence(seqId: genSeqId, from: 0)
        llama.copySequence(from: promptSeqId, to: genSeqId)

        let generationStart = Date()
        let maxOut = min(maxTokens, sampling.maxSuggestTokens)
        var output = ""
        var generatedCount = 0

        sampler?.reset()
        if sampling.repeatLastN != 0 {
            let tailCount = max(0, promptTokens.count - Int(sampling.repeatLastN))
            for token in promptTokens[tailCount...] {
                sampler?.accept(token)
            }
        }

        for _ in 0..<maxOut {
            if generationId != myGenerationId {
                _ = llama.clearSequence(seqId: genSeqId, from: 0)
                return ("", metrics)
            }

            let nextToken = sampler?.sample(context: llama.rawContext) ?? -1
            if nextToken < 0 { break }

            if llama.isEog(nextToken) { break }

            let tokenText = llama.tokenToTextAccumulating(nextToken)
            if shouldStop(tokenText: tokenText) { break }

            if ttft == nil {
                ttft = Date().timeIntervalSince(startTime)
            }

            output += tokenText
            sampler?.accept(nextToken)

            let pos = Int32(promptTokens.count + generatedCount)
            do {
                try llama.decode(
                    tokens: [nextToken],
                    positions: [pos],
                    seqId: genSeqId,
                    logitsOnLast: true
                )
            } catch {
                break
            }

            generatedCount += 1
        }

        _ = llama.clearSequence(seqId: genSeqId, from: 0)
        llama.clearInvalidBytes()

        let generationTime = Date().timeIntervalSince(generationStart)
        let totalTime = Date().timeIntervalSince(startTime)

        metrics.totalTime = totalTime
        metrics.generationTime = generationTime
        metrics.ttft = ttft ?? 0
        metrics.tokensGenerated = generatedCount
        metrics.tokensPerSecond = generationTime > 0 ? Double(generatedCount) / generationTime : 0

        return (output, metrics)
    }

    func resetCache() async {
        _ = llama.clearSequence(seqId: promptSeqId, from: 0)
        _ = llama.clearSequence(seqId: genSeqId, from: 0)
        promptTokens = []
    }

    private func findCommonPrefixLength(newTokens: [Int32]) -> Int {
        var commonLength = 0
        for i in 0..<min(promptTokens.count, newTokens.count) {
            if promptTokens[i] == newTokens[i] {
                commonLength += 1
            } else {
                break
            }
        }
        return commonLength
    }

    private func shouldStop(tokenText: String) -> Bool {
        if tokenText.isEmpty { return false }
        if tokenText.contains("\n") { return true }
        if tokenText == "</s>" { return true }
        if tokenText.contains("  ") { return true }
        if tokenText.contains(".") || tokenText.contains("!") || tokenText.contains("?") {
            return true
        }
        return false
    }
}
