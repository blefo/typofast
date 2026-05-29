import Foundation

enum CompletionLength: String, CaseIterable, Sendable {
    case short
    case medium
    case long

    /// Number of words the model is asked to generate. Generation is stopped once this many
    /// words are produced (the model is not run long then truncated), and the result is shown
    /// in full. The prompt / context window is independent of this value.
    var wordCount: Int {
        switch self {
        case .short: return 3
        case .medium: return 6
        case .long: return 12
        }
    }

    var shortLabel: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .long: return "Long"
        }
    }
}
