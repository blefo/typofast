import Foundation

@MainActor
final class InputMethodEngine {
    static let shared = InputMethodEngine()

    private let engine = AutocompleteEngine()
    private var isLoaded = false
    private var loadingTask: Task<Void, Never>?
    private let modelPathKey = "typofast.modelPath"

    private init() {}

    func ensureLoaded() async {
        guard !isLoaded else { return }
        if loadingTask != nil { return }

        loadingTask = Task { @MainActor in
            defer { loadingTask = nil }
            guard let path = UserDefaults.standard.string(forKey: modelPathKey), !path.isEmpty else {
                return
            }
            do {
                try await engine.loadModel(path: path)
                isLoaded = true
            } catch {
                isLoaded = false
            }
        }
    }

    func getSuggestion(prompt: String, inputText: String) async -> (String, CompletionMetrics) {
        await ensureLoaded()
        guard isLoaded else { return ("", CompletionMetrics()) }
        let (completion, metrics) = await engine.getCompletion(prompt: prompt, inputText: inputText, maxTokens: 6)
        publishMetrics(metrics)
        return (completion, metrics)
    }

    private func publishMetrics(_ metrics: CompletionMetrics) {
        let payload: [String: Any] = [
            "ttft": metrics.ttft,
            "tokensPerSecond": metrics.tokensPerSecond,
            "tokensGenerated": metrics.tokensGenerated,
            "cachedTokensReused": metrics.cachedTokensReused
        ]
        DistributedNotificationCenter.default().post(
            name: Notification.Name("TypofastMetricsUpdate"),
            object: nil,
            userInfo: payload
        )
    }
}
