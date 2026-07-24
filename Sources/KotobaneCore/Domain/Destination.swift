import Foundation

public enum Destination: String, CaseIterable, Codable, Equatable, Sendable {
    case codex
    case claude
    case clipboard
    case markdown

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .clipboard: "Clipboard"
        case .markdown: "Markdown file"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claude"
        case .clipboard, .markdown: nil
        }
    }

    public var url: URL? {
        switch self {
        case .codex: URL(string: "https://chatgpt.com/codex")
        case .claude: URL(string: "https://claude.ai/new")
        case .clipboard, .markdown: nil
        }
    }

    public var supportsPaste: Bool {
        switch self {
        case .codex, .claude: true
        case .clipboard, .markdown: false
        }
    }

    public static let builtIns: [Destination] = allCases
}
