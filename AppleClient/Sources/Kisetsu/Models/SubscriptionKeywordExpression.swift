import Foundation

enum SubscriptionKeywordExpression {
  enum ParseError: LocalizedError, Equatable {
    case emptyCondition
    case extraClosingParenthesis
    case unclosedParenthesis
    case trailingGroupContent
    case emptyGroup
    case emptyGroupTerm
    case nestedGroup

    var errorDescription: String? {
      switch self {
      case .emptyCondition:
        "关键词条件之间不能有空项。"
      case .extraClosingParenthesis:
        "存在多余的右括号。"
      case .unclosedParenthesis:
        "括号未闭合。"
      case .trailingGroupContent:
        "括号组后不能附加其他内容。"
      case .emptyGroup:
        "括号组不能为空。"
      case .emptyGroupTerm:
        "括号组内不能有空关键词。"
      case .nestedGroup:
        "暂不支持嵌套括号。"
      }
    }
  }

  private struct Clause {
    var terms: [String]
    var grouped: Bool

    var serialized: String {
      grouped ? "(\(terms.joined(separator: ", ")))" : terms[0]
    }
  }

  static func parse(_ value: String) throws -> [String] {
    let expression = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expression.isEmpty else { return [] }
    return try splitTopLevel(expression).map(parseClause).map(\.serialized)
  }

  static func validationMessage(_ value: String) -> String? {
    do {
      _ = try parse(value)
      return nil
    } catch let error as ParseError {
      return error.localizedDescription
    } catch {
      return "关键词表达式无效。"
    }
  }

  private static func syntaxCharacter(_ character: Character) -> Character {
    switch character {
    case "，": ","
    case "（": "("
    case "）": ")"
    default: character
    }
  }

  private static func splitTopLevel(_ value: String) throws -> [String] {
    var segments: [String] = []
    var current = ""
    var depth = 0
    for rawCharacter in value {
      let character = syntaxCharacter(rawCharacter)
      switch character {
      case "(":
        depth += 1
        current.append(rawCharacter)
      case ")":
        guard depth > 0 else { throw ParseError.extraClosingParenthesis }
        depth -= 1
        current.append(rawCharacter)
      case "," where depth == 0:
        let segment = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { throw ParseError.emptyCondition }
        segments.append(segment)
        current = ""
      default:
        current.append(rawCharacter)
      }
    }
    guard depth == 0 else { throw ParseError.unclosedParenthesis }
    let finalSegment = current.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalSegment.isEmpty else { throw ParseError.emptyCondition }
    segments.append(finalSegment)
    return segments
  }

  private static func parseClause(_ value: String) throws -> Clause {
    let clause = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = clause.first, syntaxCharacter(first) == "(" else {
      return Clause(terms: [clause], grouped: false)
    }
    guard let last = clause.last, syntaxCharacter(last) == ")" else {
      throw ParseError.trailingGroupContent
    }
    let inner = String(clause.dropFirst().dropLast())
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !inner.isEmpty else { throw ParseError.emptyGroup }
    guard !inner.contains(where: { ["(", ")"].contains(syntaxCharacter($0)) }) else {
      throw ParseError.nestedGroup
    }
    let terms = inner
      .replacingOccurrences(of: "，", with: ",")
      .components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard terms.allSatisfy({ !$0.isEmpty }) else { throw ParseError.emptyGroupTerm }
    return Clause(terms: terms, grouped: true)
  }
}
