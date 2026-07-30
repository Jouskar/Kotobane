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
