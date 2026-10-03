import Foundation

enum SubscriptionSearch {
  static func filter(_ subscriptions: [Subscription], query: String) -> [Subscription] {
    let queryTokens = normalizedTokens(query)
    guard !queryTokens.isEmpty else { return subscriptions }

    return subscriptions.filter { subscription in
      matches(subscription, queryTokens: queryTokens)
    }
  }

  static func matches(_ subscription: Subscription, query: String) -> Bool {
    let queryTokens = normalizedTokens(query)
    guard !queryTokens.isEmpty else { return true }
    return matches(subscription, queryTokens: queryTokens)
  }

  private static func matches(_ subscription: Subscription, queryTokens: [String]) -> Bool {
    let values = [
      subscription.name,
      subscription.keyword,
    ] + subscription.aliases + (subscription.metadataTitles ?? [])
    let tokenizedValues = values.map(normalizedTokens)
    let fieldTokens = tokenizedValues.flatMap { $0 }
    let compactValues = tokenizedValues.map { $0.joined() }.filter { !$0.isEmpty }

    return queryTokens.allSatisfy { queryToken in
      fieldTokens.contains { $0.contains(queryToken) } ||
        compactValues.contains { $0.contains(queryToken) }
    }
  }

  static func normalizedTokens(_ value: String) -> [String] {
    let folded = value
      .precomposedStringWithCompatibilityMapping
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )

    var normalized = ""
    normalized.reserveCapacity(folded.count)
    var hasTrailingSeparator = true

    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        normalized.unicodeScalars.append(scalar)
        hasTrailingSeparator = false
      } else if !hasTrailingSeparator {
        normalized.append(" ")
        hasTrailingSeparator = true
      }
    }

    return normalized
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }
}

enum SearchQueryHistory {
  static let limit = 10

  static func storageKey(for backendURL: String) -> String {
    "resourceSearchHistory.v1.\(backendURL)"
  }

  static func adding(_ query: String, to entries: [String]) -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return entries }
    let remaining = entries.filter { $0.compare(trimmed, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame }
    return Array(([trimmed] + remaining).prefix(limit))
  }

  static func removing(_ query: String, from entries: [String]) -> [String] {
    entries.filter { $0 != query }
  }
}
