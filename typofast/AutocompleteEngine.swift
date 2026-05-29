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
    var hardMaxTokens: Int = 64
    // Greedy decoding: for inline autocomplete we want the single most-likely continuation.
    // Sampling (even at low temperature) pulls in long-tail junk like random numbers, which
    // a small quantized model is especially prone to. Greedy is also fully deterministic so
    // the same prefix always yields the same suggestion (no flicker).
    var temperature: Float = 0.0
    var topK: Int32 = 0
    var topP: Float = 1.0
    var minP: Float = 0.0
    var repeatPenalty: Float = 1.1
    var repeatLastN: Int32 = 64
    var seed: UInt32 = 0x9E3779B9
}

private final class LlamaSamplerChain {
    private var chain: UnsafeMutablePointer<llama_sampler>?

    init(config: SamplingConfig, nVocab: Int32 = 0, bannedTokenIds: [Int32] = []) {
        let params = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(params)

        if !bannedTokenIds.isEmpty && nVocab > 0 {
            let biases = bannedTokenIds.map { llama_logit_bias(token: $0, bias: -.infinity) }
            biases.withUnsafeBufferPointer { ptr in
                llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(nVocab, Int32(biases.count), ptr.baseAddress))
            }
        }

        if config.repeatLastN != 0 || config.repeatPenalty != 1.0 {
            let penalties = llama_sampler_init_penalties(config.repeatLastN, config.repeatPenalty, 0.0, 0.0)
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
            llama_sampler_chain_add(chain, llama_sampler_init_dist(config.seed))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
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

/// Autoregressive next-token continuation engine.
///
/// The model is treated as a pure base completion model: the prompt is the raw text
/// up to the caret and the output is whatever the model would type next. There is no
/// chat template or instruction wrapper.
///
/// A single KV-cache sequence holds exactly the prompt tokens between requests. On each
/// request we reuse the longest common token prefix already in the cache, decode only the
/// new suffix, generate, then roll back the generated cells so the cache again holds only
/// the prompt. This gives very low TTFT for in-word keystrokes (usually 1-2 tokens to
/// re-decode) and lets completions fire on every character.
actor AutocompleteEngine {
    private let llama = LlamaContext()
    private let seqId: Int32 = 0
    private var promptTokens: [Int32] = []
    private var generationId: Int = 0
    private let sampling = SamplingConfig()
    private var sampler: LlamaSamplerChain?
    private var tokenizeAddsBos = true
    private var contextCapacity = 2048

    func loadModel(path: String, addBos: Bool = true) async throws {
        tokenizeAddsBos = addBos
        try llama.loadModel(path: path)
        contextCapacity = max(512, llama.contextSize)
        let bannedIds = Array(Set(llama.eogTokenIds + llama.controlTokenIds))
        sampler = LlamaSamplerChain(config: sampling, nVocab: llama.nVocab, bannedTokenIds: bannedIds)
        warmupKernels()
    }

    func getCompletion(prompt: String, maxWords: Int = 6) async -> (String, CompletionMetrics) {
        guard !Task.isCancelled else { return ("", CompletionMetrics()) }
        generationId += 1
        let myGenerationId = generationId
        return getCompletionSync(
            prompt: prompt,
            maxWords: max(1, maxWords),
            generationId: myGenerationId,
            allowRetry: true
        )
    }

    func resetCache() async {
        hardResetCache()
    }

    private func getCompletionSync(
        prompt: String,
        maxWords: Int,
        generationId: Int,
        allowRetry: Bool
    ) -> (String, CompletionMetrics) {
        let startTime = Date()
        var metrics = CompletionMetrics()
        var ttft: Double? = nil

        // Generous token budget so the model can actually reach `maxWords` words (a word can be
        // several BPE tokens). Generation is stopped at the word boundary, not by truncation.
        let tokenBudget = min(sampling.hardMaxTokens, maxWords * 4 + 4)

        var tokens = llama.tokenize(text: prompt, addBos: tokenizeAddsBos, special: false)
        guard !tokens.isEmpty else { return ("", metrics) }
        tokens = clampToContext(tokens, reservedForGeneration: tokenBudget)

        let commonPrefix = findCommonPrefixLength(newTokens: tokens)
        metrics.cachedTokensReused = commonPrefix

        if commonPrefix < promptTokens.count {
            guard llama.clearSequence(seqId: seqId, from: Int32(commonPrefix)) else {
                return retryOrEmpty(prompt, maxWords, generationId, allowRetry, metrics)
            }
            promptTokens = Array(promptTokens.prefix(commonPrefix))
        }

        let promptStart = Date()
        if tokens.count > commonPrefix {
            let suffix = Array(tokens[commonPrefix...])
            let positions = suffix.indices.map { Int32(commonPrefix + $0) }
            do {
                try llama.decode(tokens: suffix, positions: positions, seqId: seqId, logitsOnLast: true)
            } catch {
                return retryOrEmpty(prompt, maxWords, generationId, allowRetry, metrics)
            }
            metrics.promptTokensProcessed = suffix.count
        } else {
            let lastIndex = tokens.count - 1
            guard llama.clearSequence(seqId: seqId, from: Int32(lastIndex)) else {
                return retryOrEmpty(prompt, maxWords, generationId, allowRetry, metrics)
            }
            do {
                try llama.decode(tokens: [tokens[lastIndex]], positions: [Int32(lastIndex)], seqId: seqId, logitsOnLast: true)
            } catch {
                return retryOrEmpty(prompt, maxWords, generationId, allowRetry, metrics)
            }
            metrics.promptTokensProcessed = 1
        }

        promptTokens = tokens
        let promptLen = tokens.count
        metrics.promptProcessingTime = Date().timeIntervalSince(promptStart)

        guard generationId == self.generationId, !Task.isCancelled else {
            _ = llama.clearSequence(seqId: seqId, from: Int32(promptLen))
            return ("", metrics)
        }

        llama.clearInvalidBytes()
        let generationStart = Date()
        let maxOut = max(1, tokenBudget)
        var output = ""
        var generatedCount = 0
        var generatedTokens: [Int32] = []

        sampler?.reset()
        let tailStart = max(0, promptTokens.count - Int(sampling.repeatLastN))
        for token in promptTokens[tailStart...] {
            sampler?.accept(token)
        }

        for step in 0..<maxOut {
            if generationId != self.generationId || Task.isCancelled {
                _ = llama.clearSequence(seqId: seqId, from: Int32(promptLen))
                return ("", metrics)
            }

            let nextToken = sampler?.sample(context: llama.rawContext) ?? -1
            if nextToken < 0 || llama.isEog(nextToken) { break }
            if isRepetitiveLoop(generatedTokens: generatedTokens, nextToken: nextToken) { break }

            let tokenText = llama.tokenToTextAccumulating(nextToken)
            let isLeadingNewline = generatedCount == 0 && !tokenText.isEmpty &&
                tokenText.allSatisfy { $0 == "\n" || $0 == "\r" }

            if !isLeadingNewline {
                if shouldStop(tokenText: tokenText) { break }
                if ttft == nil { ttft = Date().timeIntervalSince(startTime) }
                output += tokenText
                generatedCount += 1
                if wordCount(output) > maxWords { break }
            }

            generatedTokens.append(nextToken)
            sampler?.accept(nextToken)

            do {
                try llama.decode(
                    tokens: [nextToken],
                    positions: [Int32(promptLen + step)],
                    seqId: seqId,
                    logitsOnLast: true
                )
            } catch {
                break
            }
        }

        _ = llama.clearSequence(seqId: seqId, from: Int32(promptLen))
        llama.clearInvalidBytes()

        let generationTime = Date().timeIntervalSince(generationStart)
        metrics.totalTime = Date().timeIntervalSince(startTime)
        metrics.generationTime = generationTime
        metrics.ttft = ttft ?? 0
        metrics.tokensGenerated = generatedCount
        metrics.tokensPerSecond = generationTime > 0 ? Double(generatedCount) / generationTime : 0

        return (limitToWords(output, maxWords: maxWords), metrics)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
    }

    private func limitToWords(_ text: String, maxWords: Int) -> String {
        let separators: Set<Character> = [" ", "\n", "\t", "\r"]
        var leading = ""
        var index = text.startIndex
        while index < text.endIndex, separators.contains(text[index]) {
            leading.append(text[index])
            index = text.index(after: index)
        }
        let rest = String(text[index...])
        let words = rest.split(whereSeparator: { separators.contains($0) })
        guard words.count > maxWords else { return text }
        return leading + words.prefix(maxWords).joined(separator: " ")
    }

    private func retryOrEmpty(
        _ prompt: String,
        _ maxWords: Int,
        _ generationId: Int,
        _ allowRetry: Bool,
        _ metrics: CompletionMetrics
    ) -> (String, CompletionMetrics) {
        hardResetCache()
        if allowRetry {
            return getCompletionSync(prompt: prompt, maxWords: maxWords, generationId: generationId, allowRetry: false)
        }
        return ("", metrics)
    }

    private func hardResetCache() {
        _ = llama.clearSequence(seqId: seqId, from: 0)
        promptTokens = []
        llama.clearInvalidBytes()
    }

    private func clampToContext(_ tokens: [Int32], reservedForGeneration: Int) -> [Int32] {
        let budget = contextCapacity - reservedForGeneration - 4
        guard budget > 1, tokens.count > budget else { return tokens }
        let overflow = tokens.count - budget
        if tokenizeAddsBos, let bos = tokens.first {
            return [bos] + Array(tokens[(overflow + 1)...])
        }
        return Array(tokens[overflow...])
    }

    private func warmupKernels() {
        let tokens = llama.tokenize(text: "The quick brown fox jumps", addBos: tokenizeAddsBos, special: false)
        guard !tokens.isEmpty else { return }
        let positions = tokens.indices.map { Int32($0) }
        do {
            try llama.decode(tokens: tokens, positions: positions, seqId: seqId, logitsOnLast: true)
            llama.synchronize()
            let warmupSampler = LlamaSamplerChain(config: sampling, nVocab: llama.nVocab, bannedTokenIds: llama.eogTokenIds)
            var nextPos = Int32(tokens.count)
            for _ in 0..<4 {
                let next = warmupSampler.sample(context: llama.rawContext)
                guard next >= 0, !llama.isEog(next) else { break }
                try llama.decode(tokens: [next], positions: [nextPos], seqId: seqId, logitsOnLast: true)
                llama.synchronize()
                nextPos += 1
            }
        } catch {}
        hardResetCache()
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

    private func isRepetitiveLoop(generatedTokens: [Int32], nextToken: Int32) -> Bool {
        let count = generatedTokens.count
        if count >= 2, generatedTokens[count - 1] == nextToken, generatedTokens[count - 2] == nextToken {
            return true
        }
        if count >= 4 {
            let lastTwo = [generatedTokens[count - 2], generatedTokens[count - 1]]
            let prevTwo = [generatedTokens[count - 4], generatedTokens[count - 3]]
            if lastTwo == prevTwo, lastTwo.last == nextToken {
                return true
            }
        }
        return false
    }

    private func shouldStop(tokenText: String) -> Bool {
        if tokenText.isEmpty { return false }
        if tokenText.contains("\n") || tokenText.contains("\r") { return true }
        if tokenText.contains("<") || tokenText.contains(">") { return true }
        return false
    }
}
