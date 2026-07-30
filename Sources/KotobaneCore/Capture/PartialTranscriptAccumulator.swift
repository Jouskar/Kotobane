import Foundation

public struct PartialTranscriptAccumulator: Equatable, Sendable {
    private var segments: [String] = []

    public init() {}

    public var text: String {
        segments.joined(separator: " ")
    }

    public mutating func append(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        segments.append(normalized)
    }
}

public struct RollingTranscriptAccumulator: Equatable, Sendable {
    private var transcriptWords: [String] = []
    private var previousWindowWords: [String] = []

    public init() {}

    public var text: String {
        transcriptWords.joined(separator: " ")
    }

    public mutating func replaceRollingWindow(with text: String) {
        let nextWindowWords = Self.words(in: text)
        guard !nextWindowWords.isEmpty else { return }
        guard !previousWindowWords.isEmpty else {
            transcriptWords = nextWindowWords
            previousWindowWords = nextWindowWords
            return
        }

        let overlap = Self.overlap(
            between: previousWindowWords,
            and: nextWindowWords
        )
        let stablePrefixCount = previousWindowWords.count - overlap
        let transcriptPrefix = transcriptWords.dropLast(previousWindowWords.count)
        transcriptWords = Array(transcriptPrefix)
            + Array(previousWindowWords.prefix(stablePrefixCount))
            + nextWindowWords
        previousWindowWords = nextWindowWords
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func overlap(between previous: [String], and next: [String]) -> Int {
        let maximum = min(previous.count, next.count)
        for count in stride(from: maximum, through: 0, by: -1) {
            if previous.suffix(count).elementsEqual(next.prefix(count)) {
                return count
            }
        }
        return 0
    }
}
