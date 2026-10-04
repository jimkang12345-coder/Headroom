import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case subscription
    case wallet
    case apiCost
}

public enum ProviderLifecycleStatus: Equatable, Sendable {
    case implemented
    case comingSoon(description: String)
}

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseek
    case openai
    case anthropic
    case codex
    case claude
    case antigravity
    case zai
    case mimo
    case byteplus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek:
            return "DeepSeek"
        case .openai:
            return "OpenAI API"
        case .anthropic:
            return "Anthropic API"
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .antigravity:
            return "Antigravity"
        case .zai:
            return "Z.ai International"
        case .mimo:
            return "Xiaomi MiMo"
        case .byteplus:
            return "BytePlus ModelArk"
        }
    }

    public var kind: ProviderKind {
        switch self {
        case .deepseek, .zai, .mimo, .byteplus:
            return .wallet
        case .openai, .anthropic:
            return .apiCost
        case .codex, .claude, .antigravity:
            return .subscription
        }
    }

    public var systemImage: String {
        switch self {
        case .deepseek:
            return "creditcard.fill"
        case .openai:
            return "chart.bar.fill"
        case .anthropic:
            return "chart.pie.fill"
        case .codex:
            return "terminal.fill"
        case .claude:
            return "brain.head.profile"
        case .antigravity:
            return "sparkles"
        case .zai:
            return "globe"
        case .mimo:
            return "bolt.horizontal.fill"
        case .byteplus:
            return "cloud.fill"
        }
    }

    public var lifecycleStatus: ProviderLifecycleStatus {
        switch self {
        case .deepseek, .openai, .anthropic, .codex, .claude:
            return .implemented
        case .antigravity:
            return .comingSoon(description: "Subscription quota monitoring coming soon")
        case .zai, .mimo, .byteplus:
            return .comingSoon(description: "Wallet connection coming soon")
        }
    }

    public var isImplemented: Bool {
        lifecycleStatus == .implemented
    }

    /// API connection capability is separate from implemented local subscription readers.
    public var supportsAPIConnection: Bool {
        self == .deepseek || isAPICostProvider
    }

    public var isAPICostProvider: Bool {
        self == .openai || self == .anthropic
    }

    public var statusDescription: String {
        switch lifecycleStatus {
        case .implemented:
            return "Ready to connect"
        case .comingSoon(let desc):
            return desc
        }
    }
}
