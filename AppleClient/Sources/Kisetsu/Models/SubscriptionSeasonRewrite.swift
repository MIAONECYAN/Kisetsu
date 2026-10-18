import Foundation

enum SubscriptionSeasonRewrite {
  enum ParseError: LocalizedError, Equatable {
    case invalidRule
    case invalidSeason
    case conflictingSource(Int)

    var errorDescription: String? {
      switch self {
      case .invalidRule:
        "Season Rewrite 格式应为 2-1, 3-1；请使用英文逗号分隔。"
      case .invalidSeason:
        "Season Rewrite 的原季度和目标季度必须大于 0。"
      case .conflictingSource(let season):
        "Season \(season) 不能改写到两个不同的季度。"
      }
    }
  }

  static func normalized(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    var targets: [Int: Int] = [:]
    var rules: [String] = []
    for item in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
      let parts = item.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw ParseError.invalidRule }
      let sourceText = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let targetText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !sourceText.isEmpty, !targetText.isEmpty,
            sourceText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            targetText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let source = Int(sourceText), let target = Int(targetText) else {
        throw ParseError.invalidRule
      }
      guard source > 0, target > 0 else { throw ParseError.invalidSeason }
      if let previous = targets[source], previous != target {
        throw ParseError.conflictingSource(source)
      }
      if targets[source] == nil {
        targets[source] = target
        rules.append("\(source)-\(target)")
      }
    }
    return rules.joined(separator: ", ")
  }

  static func validationMessage(_ value: String) -> String? {
    do {
      _ = try normalized(value)
      return nil
    } catch let error as ParseError {
      return error.localizedDescription
    } catch {
      return "Season Rewrite 格式无效。"
    }
  }
}
