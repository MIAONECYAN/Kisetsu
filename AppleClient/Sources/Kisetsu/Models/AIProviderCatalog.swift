import Foundation

struct AIProviderOption: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
}

enum AIProviderCatalog {
  static let options = [
    AIProviderOption(id: "none", title: "不使用 AI"),
    AIProviderOption(id: "openai_compatible", title: "OpenAI-compatible"),
    AIProviderOption(id: "xai", title: "xAI"),
    AIProviderOption(id: "deepseek", title: "DeepSeek"),
  ]

  static func title(for provider: String) -> String {
    options.first(where: { $0.id == provider })?.title ?? "AI 服务"
  }

  static func defaultBaseURL(for provider: String) -> String {
    switch provider {
    case "xai": "https://api.x.ai/v1"
    case "deepseek": "https://api.deepseek.com"
    default: ""
    }
  }

  static func defaultModel(for provider: String) -> String {
    switch provider {
    case "xai": "grok-4.6"
    case "deepseek": "deepseek-v4-flash"
    default: ""
    }
  }

  static func baseURLPlaceholder(for provider: String) -> String {
    switch provider {
    case "xai": "https://api.x.ai/v1"
    case "deepseek": "https://api.deepseek.com"
    default: "例如：https://api.openai.com/v1"
    }
  }

  static func modelPlaceholder(for provider: String) -> String {
    switch provider {
    case "xai": "例如：grok-4.6"
    case "deepseek": "例如：deepseek-v4-flash"
    default: "例如：gpt-4.1-mini"
    }
  }
}
