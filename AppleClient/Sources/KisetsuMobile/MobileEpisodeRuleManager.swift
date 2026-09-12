import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum MobileEpisodeRuleValidation {
  static func message(for rule: EpisodeParseRule) -> String? {
    let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return "请填写匹配表达式。" }

    let normalizedPattern = pattern.replacingOccurrences(of: "(?P<", with: "(?<")
    do {
      _ = try NSRegularExpression(pattern: normalizedPattern)
    } catch {
      return compilationMessage(pattern: pattern, error: error)
    }

    let episode = normalizedGroup(rule.episodeGroup, fallback: "episode")
    let start = normalizedGroup(rule.startGroup, fallback: "start")
    let end = normalizedGroup(rule.endGroup, fallback: "end")
    let hasEpisode = containsNamedGroup(episode, in: pattern)
    let hasRange = containsNamedGroup(start, in: pattern) && containsNamedGroup(end, in: pattern)
    guard hasEpisode || hasRange else {
      return "表达式必须包含单集捕获组，或同时包含合集开始和结束捕获组。"
    }
    return nil
  }

  static func hasInvalidRules(_ rules: [EpisodeParseRule], enabled: Bool) -> Bool {
    enabled && rules.contains { message(for: $0) != nil }
  }

  private static func normalizedGroup(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func containsNamedGroup(_ name: String, in pattern: String) -> Bool {
    pattern.contains("(?<\(name)>") || pattern.contains("(?P<\(name)>")
  }

  private static func compilationMessage(pattern: String, error: Error) -> String {
    if let issue = structuralIssue(in: pattern) {
      return "正则表达式无效（第 \(issue.position) 个字符附近）：\(issue.reason)"
    }
    return "正则表达式无效：\(error.localizedDescription)"
  }

  private static func structuralIssue(in pattern: String) -> (position: Int, reason: String)? {
    var parentheses: [Int] = []
    var characterClassStart: Int?
    var escaped = false

    for (offset, character) in pattern.enumerated() {
      let position = offset + 1
      if escaped {
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
        continue
      }
      if let start = characterClassStart {
        if character == "]" { characterClassStart = nil }
        if offset == pattern.count - 1 {
          return (start, "字符组左方括号没有闭合。")
        }
        continue
      }
      switch character {
      case "[":
        characterClassStart = position
      case "]":
        return (position, "右方括号没有对应的左方括号。")
      case "(":
        parentheses.append(position)
      case ")":
        guard !parentheses.isEmpty else {
          return (position, "右括号没有对应的左括号。")
        }
        parentheses.removeLast()
      case "*" where offset == 0,
           "+" where offset == 0,
           "?" where offset == 0:
        return (position, "量词前缺少可重复的内容。")
      default:
        break
      }
    }
    if escaped { return (max(1, pattern.count), "末尾的转义符缺少后续字符。") }
    if let start = characterClassStart { return (start, "字符组左方括号没有闭合。") }
    if let start = parentheses.last { return (start, "左括号没有闭合。") }
    return nil
  }
}

enum MobileEpisodeRuleEditorKind: String, Equatable {
  case visual
  case advanced
}

struct MobileEpisodeRuleEditorRoute: Identifiable, Hashable {
  let id: String
  var kind: MobileEpisodeRuleEditorKind
  var rule: EpisodeParseRule
  var isNew: Bool

  init(kind: MobileEpisodeRuleEditorKind, rule: EpisodeParseRule, isNew: Bool) {
    self.id = "\(kind.rawValue):\(rule.id)"
    self.kind = kind
    self.rule = rule
    self.isNew = isNew
  }
}

struct MobileEpisodeRuleManager: View {
  @Binding var rules: [EpisodeParseRule]
  var builtinRules: [EpisodeParseRule]
  @Binding var testTitle: String
  var testResponse: EpisodeRuleTestResponse?
  var isTesting: Bool
  var scopeTitle = "订阅专属规则"
  var fallbackTitle = "使用全局规则"
  var deleteMessage = "只删除当前订阅中的这条规则，不影响全局规则和系统内置规则。"
  var addTemplate: (String) -> Void
  var runTest: () async -> Void
  var presentEditor: (MobileEpisodeRuleEditorRoute) -> Void

  @State private var deletingRule: EpisodeParseRule?

  var body: some View {
    Group {
      LabeledContent("规则范围", value: rules.isEmpty ? fallbackTitle : "\(rules.count) 条\(scopeTitle)")
      if !builtinRules.isEmpty {
        LabeledContent("系统内置", value: "\(builtinRules.filter(\.enabled).count) 条已启用")
      }

      ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
        ruleRow(rule, index: index)
      }

      Menu("添加识别规则", systemImage: "plus") {
        Button("新建可视化规则", systemImage: "viewfinder") {
          presentEditor(MobileEpisodeRuleEditorRoute(
            kind: .visual,
            rule: newVisualRule(),
            isNew: true
          ))
        }
        Button("新建高级规则", systemImage: "curlybraces") {
          presentEditor(MobileEpisodeRuleEditorRoute(
            kind: .advanced,
            rule: newAdvancedRule(),
            isNew: true
          ))
        }
        Divider()
        templateButton("第 01 话", template: "default")
        templateButton("[01]", template: "bracket")
        templateButton("[01-12] 合集", template: "bracket_range")
        templateButton("★01★", template: "star_single")
        templateButton("★01~12(完)★", template: "star_range")
        templateButton("01v2", template: "plain_v2")
        templateButton("12(完)", template: "final")
      }

      MobileFormTextField(
        label: "测试资源标题",
        prompt: "粘贴标题以测试集数识别",
        text: $testTitle
      )
      Button("测试集数识别", systemImage: "checkmark.seal") {
        Task { await runTest() }
      }
      .disabled(isTesting || testTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      if let testResponse {
        MobileEpisodeRuleTestResult(response: testResponse)
      }
    }
    .alert("删除这条识别规则？", isPresented: Binding(
      get: { deletingRule != nil },
      set: { if !$0 { deletingRule = nil } }
    )) {
      Button("删除", role: .destructive) {
        guard let deletingRule else { return }
        rules.removeAll { $0.id == deletingRule.id }
        normalizePriorities()
        self.deletingRule = nil
      }
      Button("取消", role: .cancel) { deletingRule = nil }
    } message: {
      Text(deleteMessage)
    }
  }

  @ViewBuilder
  private func ruleRow(_ rule: EpisodeParseRule, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Toggle(rule.name, isOn: enabledBinding(for: rule.id))
          .labelsHidden()
          .accessibilityLabel("启用 \(rule.name)")
        VStack(alignment: .leading, spacing: 3) {
          Text(rule.name.isEmpty ? "自定义规则 \(index + 1)" : rule.name)
            .font(.subheadline.weight(.semibold))
          Text(rule.mode == "visual" ? "可视化规则" : "高级正则")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(rule.exampleTitle ?? rule.sampleTitle ?? rule.pattern)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 4)
        Menu("规则操作", systemImage: "ellipsis.circle") {
          Button("编辑", systemImage: "pencil") {
            presentEditor(MobileEpisodeRuleEditorRoute(
              kind: rule.mode == "visual" ? .visual : .advanced,
              rule: rule,
              isNew: false
            ))
          }
          Button("上移", systemImage: "arrow.up") { moveRule(at: index, by: -1) }
            .disabled(index == 0)
          Button("下移", systemImage: "arrow.down") { moveRule(at: index, by: 1) }
            .disabled(index == rules.count - 1)
          Divider()
          Button("删除", systemImage: "trash", role: .destructive) { deletingRule = rule }
        }
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("\(rule.name) 的规则操作")
      }
      if let message = MobileEpisodeRuleValidation.message(for: rule) {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 3)
  }

  private func templateButton(_ title: String, template: String) -> some View {
    Button(title) {
      let existingIDs = Set(rules.map(\.id))
      addTemplate(template)
      if let added = rules.last(where: { !existingIDs.contains($0.id) }) {
        rules.removeAll { $0.id == added.id }
        normalizePriorities()
        presentEditor(MobileEpisodeRuleEditorRoute(kind: .advanced, rule: added, isNew: true))
      }
    }
  }

  private func newVisualRule() -> EpisodeParseRule {
    EpisodeParseRule(
      id: UUID().uuidString,
      name: "",
      pattern: "",
      enabled: true,
      priority: rules.count,
      episodeGroup: "episode",
      startGroup: "start",
      endGroup: "end",
      finalGroup: "final",
      mode: "visual",
      description: "由可视化标记生成"
    )
  }

  private func newAdvancedRule() -> EpisodeParseRule {
    EpisodeParseRule(
      id: UUID().uuidString,
      name: "自定义规则 \(rules.count + 1)",
      pattern: #"(?<episode>\d{1,3})"#,
      enabled: true,
      priority: rules.count,
      episodeGroup: "episode",
      startGroup: "start",
      endGroup: "end",
      finalGroup: "final"
    )
  }

  private func enabledBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { rules.first(where: { $0.id == id })?.enabled ?? false },
      set: { value in
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = value
      }
    )
  }

  private func moveRule(at index: Int, by offset: Int) {
    let target = index + offset
    guard rules.indices.contains(index), rules.indices.contains(target) else { return }
    rules.swapAt(index, target)
    normalizePriorities()
  }

  private func normalizePriorities() {
    for index in rules.indices { rules[index].priority = index }
  }
}

enum MobileEpisodeRuleCollection {
  static func save(_ updated: EpisodeParseRule, to rules: inout [EpisodeParseRule]) {
    if let index = rules.firstIndex(where: { $0.id == updated.id }) {
      rules[index] = updated
    } else {
      var added = updated
      added.priority = rules.count
      rules.append(added)
    }
    for index in rules.indices { rules[index].priority = index }
  }
}

struct MobileEpisodeRuleEditorDestination: View {
  var route: MobileEpisodeRuleEditorRoute
  var save: (EpisodeParseRule) -> Void

  @ViewBuilder
  var body: some View {
    switch route.kind {
    case .visual:
      MobileVisualEpisodeRuleEditor(initialRule: route.rule, save: save)
    case .advanced:
      MobileAdvancedEpisodeRuleEditor(initialRule: route.rule, save: save)
    }
  }
}

private struct MobileEpisodeRuleTestResult: View {
  var response: EpisodeRuleTestResponse

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        response.message,
        systemImage: response.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(response.ok ? .green : .orange)

      if let rule = response.parsedTitle.parseRuleName, !rule.isEmpty {
        LabeledContent("命中规则", value: rule)
      }
      if let episode = episodeDescription {
        LabeledContent("识别集数", value: episode)
      }
      if let reason = response.parsedTitle.parseFailureReason, !reason.isEmpty {
        LabeledContent("错误位置或原因", value: reason)
          .foregroundStyle(.red)
      }
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
  }

  private var episodeDescription: String? {
    if let start = response.parsedTitle.episodeStart,
       let end = response.parsedTitle.episodeEnd,
       end > start {
      return "第 \(start)-\(end) 集"
    }
    if let episode = response.parsedTitle.episodeNumber ?? response.parsedTitle.episode {
      return "第 \(episode) 集"
    }
    return response.parsedTitle.displayEpisodeLabel
  }

  private var accessibilitySummary: String {
    ["识别结果：\(response.message)", episodeDescription].compactMap { $0 }.joined(separator: "，")
  }
}

enum MobileEpisodeMarkMode: String, CaseIterable, Identifiable {
  case episode
  case start
  case end
  case final
  case split
  case clear

  var id: String { rawValue }

  var title: String {
    switch self {
    case .episode: "单集"
    case .start: "合集开始"
    case .end: "合集结束"
    case .final: "完结"
    case .split: "拆分"
    case .clear: "清除"
    }
  }

  var color: Color {
    switch self {
    case .episode: .blue
    case .start, .end: .purple
    case .final: .green
    case .split: .teal
    case .clear: .secondary
    }
  }
}

struct MobileEpisodeRuleMarkingState {
  struct Snapshot {
    var marks: [EpisodeRuleVisualMark]
    var splitTokenIDs: Set<Int>
  }

  var tokens: [EpisodeTitleToken] = []
  var marks: [EpisodeRuleVisualMark] = []
  var splitTokenIDs: Set<Int> = []
  var history: [Snapshot] = []

  var displayTokens: [EpisodeTitleToken] {
    tokens.flatMap { token in
      guard splitTokenIDs.contains(token.id), token.text.count > 1 else { return [token] }
      let groupID = "split-\(token.id)"
      return token.text.enumerated().map { offset, character in
        let text = String(character)
        return EpisodeTitleToken(
          id: token.id * 10_000 + offset + 1,
          text: text,
          startIndex: token.startIndex + offset,
          endIndex: token.startIndex + offset + 1,
          kind: text.rangeOfCharacter(from: .decimalDigits) == nil ? "text" : "number",
          splitGroupId: groupID,
          isSplit: true
        )
      }
    }
  }

  mutating func replaceTokens(_ newTokens: [EpisodeTitleToken]) {
    tokens = newTokens
    splitTokenIDs = splitTokenIDs.filter { id in newTokens.contains { $0.id == id } }
    marks = marks.filter { mark in
      displayTokens.contains {
        $0.id == mark.tokenId || ($0.startIndex == mark.startIndex && $0.endIndex == mark.endIndex)
      }
    }
  }

  @discardableResult
  mutating func apply(_ mode: MobileEpisodeMarkMode, to token: EpisodeTitleToken) -> String {
    history.append(Snapshot(marks: marks, splitTokenIDs: splitTokenIDs))
    if mode == .split {
      if let groupID = token.splitGroupId,
         let originalID = Int(groupID.replacingOccurrences(of: "split-", with: "")) {
        marks.removeAll { $0.splitGroupId == groupID }
        splitTokenIDs.remove(originalID)
        return "已合并拆分片段。"
      }
      guard token.text.count > 1 else {
        history.removeLast()
        return "这个片段已经足够细。"
      }
      splitTokenIDs.insert(token.id)
      return "已拆分“\(token.text)”。"
    }

    let existing = marks.first { $0.tokenId == token.id }
    if mode == .clear {
      marks.removeAll { $0.tokenId == token.id }
      return "已清除“\(token.text)”的标记。"
    }
    if existing?.markType == mode.rawValue {
      marks.removeAll { $0.tokenId == token.id }
      return "已清除“\(token.text)”的\(mode.title)标记。"
    }
    marks.removeAll { $0.tokenId == token.id || $0.markType == mode.rawValue }
    marks.append(EpisodeRuleVisualMark(
      tokenId: token.id,
      tokenText: token.text,
      markType: mode.rawValue,
      startIndex: token.startIndex,
      endIndex: token.endIndex,
      splitGroupId: token.splitGroupId
    ))
    return "已把“\(token.text)”标记为\(mode.title)。"
  }

  mutating func undo() -> Bool {
    guard let previous = history.popLast() else { return false }
    marks = previous.marks
    splitTokenIDs = previous.splitTokenIDs
    return true
  }

  mutating func reset() {
    history.append(Snapshot(marks: marks, splitTokenIDs: splitTokenIDs))
    marks = []
  }
}

enum MobileEpisodeRuleFixtureEngine {
  static func tokenize(_ title: String) -> EpisodeRuleTokenizeResponse {
    let pattern = #"\d+|[A-Za-z]+|[\p{Han}]+|\s+|."#
    let expression = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(title.startIndex..<title.endIndex, in: title)
    let matches = expression?.matches(in: title, range: range) ?? []
    let tokens: [EpisodeTitleToken] = matches.enumerated().compactMap { index, match in
      guard let swiftRange = Range(match.range, in: title) else { return nil }
      let text = String(title[swiftRange])
      return EpisodeTitleToken(
        id: index,
        text: text,
        startIndex: match.range.location,
        endIndex: match.range.location + match.range.length,
        kind: tokenKind(text)
      )
    }
    return EpisodeRuleTokenizeResponse(title: title, tokens: tokens)
  }

  static func preview(
    title: String,
    marks: [EpisodeRuleVisualMark],
    name: String?,
    tokens: [EpisodeTitleToken]
  ) -> EpisodeRulePreviewResponse {
    let byType = Dictionary(grouping: marks, by: \.markType)
    let hasEpisode = byType["episode"]?.count == 1
    let hasRange = byType["start"]?.count == 1 && byType["end"]?.count == 1
    let invalidRange = (byType["start"]?.isEmpty == false) != (byType["end"]?.isEmpty == false)
    let message: String
    if hasEpisode && hasRange {
      message = "单集和合集范围不能同时标记，请保留一种。"
    } else if invalidRange {
      message = "合集开始和合集结束必须同时标记。"
    } else if !hasEpisode && !hasRange {
      message = "请选择单集集数，或同时选择合集开始和合集结束。"
    } else {
      message = hasRange ? rangeMessage(byType) : episodeMessage(byType)
    }
    guard (hasEpisode || hasRange) && !(hasEpisode && hasRange) && !invalidRange else {
      return EpisodeRulePreviewResponse(
        ok: false,
        message: message,
        rule: nil,
        parsedTitle: nil,
        tokens: tokens,
        suggestions: [message],
        markedTokens: marks
      )
    }

    let pattern = generatedPattern(title: title, marks: marks)
    let defaultName = hasRange ? "自定义合集规则" : "自定义单集规则"
    let rule = EpisodeParseRule(
      id: "fixture-visual-preview",
      name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : defaultName,
      pattern: pattern,
      enabled: true,
      priority: 0,
      episodeGroup: "episode",
      startGroup: "start",
      endGroup: "end",
      finalGroup: "final",
      mode: "visual",
      sampleTitle: title,
      exampleTitle: title,
      description: "由可视化标记生成",
      visualMarks: marks,
      generatedPattern: pattern
    )
    let start = markNumber(byType["start"]?.first)
    let end = markNumber(byType["end"]?.first)
    let episode = markNumber(byType["episode"]?.first)
    let parsed = ParsedAnimeTitle(
      originalTitle: title,
      episode: episode ?? start,
      episodeNumber: episode,
      episodeStart: episode ?? start,
      episodeEnd: episode ?? end,
      isBatch: hasRange,
      isFinal: byType["final"]?.isEmpty == false,
      displayEpisodeLabel: hasRange ? "合集 \(start ?? 0)-\(end ?? 0)" : "第 \(episode ?? 0) 集",
      parseRuleName: rule.name,
      confidence: 1,
      needsConfirmation: false
    )
    return EpisodeRulePreviewResponse(
      ok: true,
      message: message,
      rule: rule,
      parsedTitle: parsed,
      tokens: tokens,
      suggestions: [],
      generatedPattern: pattern,
      confidence: 0.92,
      explanation: ["根据标记位置生成了专属集数规则。"],
      warnings: [],
      markedTokens: marks,
      positiveTests: [title]
    )
  }

  static func test(_ cases: [EpisodeRuleTestCase], rule: EpisodeParseRule) -> EpisodeRuleTestResponse {
    let normalized = rule.pattern.replacingOccurrences(of: "(?P<", with: "(?<")
    let expression = try? NSRegularExpression(pattern: normalized)
    let results = cases.map { item in
      let range = NSRange(item.title.startIndex..<item.title.endIndex, in: item.title)
      let matched = expression?.firstMatch(in: item.title, range: range) != nil
      let parsed = ParsedAnimeTitle(
        originalTitle: item.title,
        parseRuleName: matched ? rule.name : nil,
        parseFailureReason: matched ? nil : "未命中当前规则",
        confidence: matched ? 1 : 0,
        needsConfirmation: !matched
      )
      return EpisodeRuleTestItem(
        title: item.title,
        expectedMatch: item.expectedMatch,
        matched: matched,
        passed: matched == item.expectedMatch,
        parsedTitle: parsed,
        message: matched ? "已匹配" : "未匹配"
      )
    }
    let allPassed = results.allSatisfy(\.passed)
    return EpisodeRuleTestResponse(
      ok: allPassed,
      parsedTitle: results.first?.parsedTitle ?? ParsedAnimeTitle(originalTitle: ""),
      message: allPassed ? "全部测试通过" : "有测试未通过",
      results: results
    )
  }

  private static func tokenKind(_ text: String) -> String {
    if text.rangeOfCharacter(from: .decimalDigits) != nil,
       text.rangeOfCharacter(from: .letters) == nil { return "number" }
    if ["完", "完结", "END", "Fin"].contains(text) { return "final" }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "space" }
    return "text"
  }

  private static func markNumber(_ mark: EpisodeRuleVisualMark?) -> Int? {
    guard let text = mark?.tokenText else { return nil }
    return Int(text.filter(\.isNumber))
  }

  private static func episodeMessage(_ marks: [String: [EpisodeRuleVisualMark]]) -> String {
    "识别结果：第 \(markNumber(marks["episode"]?.first) ?? 0) 集"
  }

  private static func rangeMessage(_ marks: [String: [EpisodeRuleVisualMark]]) -> String {
    let start = markNumber(marks["start"]?.first) ?? 0
    let end = markNumber(marks["end"]?.first) ?? 0
    return "识别结果：合集 · 第 \(start)-\(end) 集"
  }

  private static func generatedPattern(title: String, marks: [EpisodeRuleVisualMark]) -> String {
    let ordered = marks
      .filter { ["episode", "start", "end", "final"].contains($0.markType) }
      .sorted { $0.startIndex < $1.startIndex }
    var cursor = 0
    var pieces = ["^"]
    for mark in ordered where mark.startIndex >= cursor {
      let prefix = substring(title, start: cursor, end: mark.startIndex)
      pieces.append(NSRegularExpression.escapedPattern(for: prefix))
      switch mark.markType {
      case "episode": pieces.append(#"(?<episode>\d{1,4})"#)
      case "start": pieces.append(#"(?<start>\d{1,4})"#)
      case "end": pieces.append(#"(?<end>\d{1,4})"#)
      case "final": pieces.append(#"(?<final>完|完结|END|Fin)"#)
      default: break
      }
      cursor = mark.endIndex
    }
    pieces.append(NSRegularExpression.escapedPattern(for: substring(title, start: cursor, end: title.utf16.count)))
    pieces.append("$")
    return pieces.joined()
  }

  private static func substring(_ text: String, start: Int, end: Int) -> String {
    let utf16 = text.utf16
    guard start >= 0, end >= start,
          let lower = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
          let upper = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex),
          let lowerIndex = String.Index(lower, within: text),
          let upperIndex = String.Index(upper, within: text) else { return "" }
    return String(text[lowerIndex..<upperIndex])
  }
}

struct MobileVisualEpisodeRuleEditor: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  var initialRule: EpisodeParseRule
  var save: (EpisodeParseRule) -> Void

  @State private var ruleName: String
  @State private var sampleTitle: String
  @State private var enabled: Bool
  @State private var marking: MobileEpisodeRuleMarkingState
  @State private var markMode = MobileEpisodeMarkMode.episode
  @State private var preview: EpisodeRulePreviewResponse?
  @State private var notice: String?
  @State private var isAnalyzing = false
  @State private var isTesting = false
  @State private var testTitle = ""
  @State private var testExpectedMatch = true
  @State private var testCases: [EpisodeRuleTestCase] = []
  @State private var testResponse: EpisodeRuleTestResponse?
  @State private var manualRegexMode = false
  @State private var manualRegexPattern: String
  @State private var showingConvertConfirmation = false
  @State private var aiAnalysis: AITitleAnalysisResponse?
  @State private var isAnalyzingWithAI = false

  init(initialRule: EpisodeParseRule, save: @escaping (EpisodeParseRule) -> Void) {
    self.initialRule = initialRule
    self.save = save
    _ruleName = State(initialValue: initialRule.name)
    _sampleTitle = State(initialValue: initialRule.sampleTitle ?? initialRule.exampleTitle ?? "")
    _enabled = State(initialValue: initialRule.enabled)
    _marking = State(initialValue: MobileEpisodeRuleMarkingState(marks: initialRule.visualMarks))
    _manualRegexPattern = State(initialValue: initialRule.generatedPattern ?? initialRule.pattern)
  }

  var body: some View {
    Form {
        Section("样例标题") {
          MobileFormTextField(label: "规则名称", prompt: "可留空，保存时自动生成", text: $ruleName)
          MobileFormTextEditor(
            label: "资源标题样例",
            hint: "粘贴一条识别失败或格式特殊的资源标题。",
            text: $sampleTitle,
            minHeight: 72
          )
          Button {
            Task { await analyzeTitle() }
          } label: {
            if isAnalyzing {
              ProgressView().controlSize(.small)
            } else {
              Label("分析标题", systemImage: "sparkle.magnifyingglass")
            }
          }
          .buttonStyle(.glass)
          .disabled(isAnalyzing || sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Section("标记集数") {
          Picker("标记类型", selection: $markMode) {
            ForEach(MobileEpisodeMarkMode.allCases) { mode in
              Label(mode.title, systemImage: markSymbol(mode)).tag(mode)
            }
          }

          if marking.displayTokens.isEmpty {
            ContentUnavailableView(
              "等待分析标题",
              systemImage: "text.viewfinder",
              description: Text("分析后，标题会拆成可点击片段。")
            )
          } else {
            MobileTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 7) {
              ForEach(marking.displayTokens) { token in
                tokenButton(token)
              }
            }
            HStack {
              if let notice {
                Text(notice)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer(minLength: 8)
              Button("撤销", systemImage: "arrow.uturn.backward") {
                if marking.undo() {
                  Task { await refreshPreview() }
                }
              }
              .disabled(marking.history.isEmpty)
              Button("重置", systemImage: "arrow.counterclockwise") {
                marking.reset()
                Task { await refreshPreview() }
              }
              .disabled(marking.marks.isEmpty)
            }
            .font(.caption)
          }
        }

        Section("识别结果") {
          Label(
            preview?.message ?? "请选择单集集数，或同时选择合集开始和合集结束。",
            systemImage: preview?.ok == true ? "checkmark.circle.fill" : "info.circle"
          )
          .foregroundStyle(preview?.ok == true ? Color.green : Color.secondary)
          if let confidence = preview?.confidence {
            LabeledContent("置信度", value: "\(Int(confidence * 100))%")
          }
          ForEach(preview?.warnings ?? [], id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("测试更多标题") {
          MobileFormTextEditor(
            label: "测试标题",
            hint: "先选择预期结果，再加入测试列表。",
            text: $testTitle,
            minHeight: 58
          )
          Picker("预期结果", selection: $testExpectedMatch) {
            Text("应该匹配").tag(true)
            Text("不应该匹配").tag(false)
          }
          .pickerStyle(.segmented)
          HStack {
            Button("加入测试", systemImage: "plus") { addTestCase() }
              .disabled(testTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
            Button {
              Task { await runTests() }
            } label: {
              if isTesting { ProgressView().controlSize(.small) }
              else { Label("测试识别", systemImage: "checkmark.seal") }
            }
            .disabled(isTesting || testCases.isEmpty || ruleForTesting == nil)
          }
          ForEach(testCases) { item in
            HStack(alignment: .firstTextBaseline) {
              Image(systemName: item.expectedMatch ? "checkmark.circle" : "xmark.circle")
              Text(item.title).lineLimit(2)
              Spacer()
              Button(role: .destructive) { testCases.removeAll { $0.id == item.id } } label: {
                Image(systemName: "trash")
              }
            }
            .font(.caption)
          }
          if let testResponse {
            Label(
              testResponse.message,
              systemImage: testResponse.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(testResponse.ok ? .green : .orange)
            ForEach(testResponse.results) { result in
              LabeledContent(result.title, value: result.passed ? "通过" : result.message)
                .font(.caption)
            }
          }
        }

        Section("辅助工具") {
          DisclosureGroup("生成的正则表达式") {
            if manualRegexMode {
              MobileFormTextEditor(
                label: "正则表达式",
                hint: "手动编辑后，将按高级正则规则保存。",
                text: $manualRegexPattern,
                minHeight: 110
              )
              .font(.body.monospaced())
              MobileFormValidationMessage(message: manualRegexValidationMessage)
            } else if generatedPattern.isEmpty {
              Text("完成集数标记后会自动生成。")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              Text(generatedPattern)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              HStack {
                Button("复制", systemImage: "doc.on.doc") { copyPattern() }
                Button("重新生成", systemImage: "arrow.clockwise") {
                  Task { await refreshPreview() }
                }
                Button("转为高级正则", systemImage: "curlybraces") {
                  showingConvertConfirmation = true
                }
              }
              .font(.caption)
            }
          }

          DisclosureGroup("AI 辅助") {
            if store.aiSettings.configured {
              HStack {
                Button("AI 解析标题", systemImage: "sparkles") {
                  Task { await analyzeWithAI(suggestedRule: false) }
                }
                Button("生成规则草稿", systemImage: "wand.and.stars") {
                  Task { await analyzeWithAI(suggestedRule: true) }
                }
              }
              .disabled(isAnalyzingWithAI || sampleTitle.isEmpty)
              if isAnalyzingWithAI { ProgressView("正在分析") }
              if let aiAnalysis {
                Label(aiAnalysis.message, systemImage: aiAnalysis.ok ? "sparkles" : "info.circle")
                if let suggested = aiAnalysis.suggestedRegex, !suggested.isEmpty {
                  Button("采用正则草稿", systemImage: "doc.badge.plus") {
                    manualRegexPattern = suggested
                    manualRegexMode = true
                  }
                }
              }
            } else {
              Text("AI 未配置，仍可完整使用本地可视化标记。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        if let saveDisabledReason {
          Section {
            Label(saveDisabledReason, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .mobileStatusNavigationTitle(initialRule.name.isEmpty ? "新增识别规则" : "编辑识别规则")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            guard let draft = ruleForSave else { return }
            save(draft)
            dismiss()
          }
          .disabled(saveDisabledReason != nil)
        }
      }
      .alert("转为高级正则？", isPresented: $showingConvertConfirmation) {
        Button("取消", role: .cancel) {}
        Button("继续") {
          manualRegexPattern = generatedPattern
          manualRegexMode = true
        }
      } message: {
        Text("转为高级正则后，可视化标记将不再自动更新表达式。")
      }
      .task {
        if !sampleTitle.isEmpty { await analyzeTitle() }
      }
      .onChange(of: sampleTitle) { _, _ in
        preview = nil
        marking = MobileEpisodeRuleMarkingState()
        notice = nil
      }
  }

  private func tokenButton(_ token: EpisodeTitleToken) -> some View {
    let selectedMode = marking.marks.first { $0.tokenId == token.id }
      .flatMap { MobileEpisodeMarkMode(rawValue: $0.markType) }
    return Button {
      notice = marking.apply(markMode, to: token)
      Task { await refreshPreview() }
    } label: {
      HStack(spacing: 4) {
        Text(token.text)
          .font(token.kind == "number" ? .body.monospaced().weight(.semibold) : .body)
        if let selectedMode {
          Text(selectedMode.title)
            .font(.caption2.weight(.semibold))
        }
      }
      .padding(.horizontal, 9)
      .frame(minHeight: 36)
      .background((selectedMode?.color ?? Color.secondary).opacity(selectedMode == nil ? 0.08 : 0.18), in: Capsule())
      .overlay(Capsule().stroke((selectedMode?.color ?? Color.secondary).opacity(0.32)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .frame(minHeight: 44)
  }

  private var generatedPattern: String {
    if manualRegexMode { return manualRegexPattern }
    if let preview {
      return preview.generatedPattern ?? preview.rule?.generatedPattern ?? preview.rule?.pattern ?? ""
    }
    return initialRule.mode == "visual" ? (initialRule.generatedPattern ?? initialRule.pattern) : ""
  }

  private var ruleForTesting: EpisodeParseRule? {
    if manualRegexMode { return advancedDraft }
    return visualDraft
  }

  private var ruleForSave: EpisodeParseRule? {
    ruleForTesting
  }

  private var visualDraft: EpisodeParseRule? {
    guard var rule = preview?.rule, preview?.ok == true else { return nil }
    rule.id = initialRule.id
    rule.name = normalizedRuleName(rule.name)
    rule.enabled = enabled
    rule.priority = initialRule.priority
    rule.mode = "visual"
    rule.sampleTitle = sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    rule.exampleTitle = rule.sampleTitle
    rule.visualMarks = marking.marks.sorted { $0.startIndex < $1.startIndex }
    rule.generatedPattern = rule.pattern
    return rule
  }

  private var advancedDraft: EpisodeParseRule? {
    var rule = initialRule
    rule.name = normalizedRuleName("高级正则规则")
    rule.pattern = manualRegexPattern
    rule.enabled = enabled
    rule.mode = "regex"
    rule.sampleTitle = nil
    rule.exampleTitle = sampleTitle.isEmpty ? nil : sampleTitle
    rule.visualMarks = []
    rule.generatedPattern = nil
    rule.description = "高级正则规则"
    return MobileEpisodeRuleValidation.message(for: rule) == nil ? rule : nil
  }

  private var manualRegexValidationMessage: String? {
    guard manualRegexMode else { return nil }
    var rule = initialRule
    rule.pattern = manualRegexPattern
    return MobileEpisodeRuleValidation.message(for: rule)
  }

  private var saveDisabledReason: String? {
    if manualRegexMode {
      return manualRegexValidationMessage
    }
    if sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "请先填写资源标题样例。"
    }
    guard let preview else { return "请先分析标题并标记集数。" }
    return preview.ok && visualDraft != nil ? nil : preview.message
  }

  private func normalizedRuleName(_ fallback: String) -> String {
    let trimmed = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private func markSymbol(_ mode: MobileEpisodeMarkMode) -> String {
    switch mode {
    case .episode: "number.circle"
    case .start: "arrow.right.to.line"
    case .end: "arrow.left.to.line"
    case .final: "flag.checkered"
    case .split: "scissors"
    case .clear: "eraser"
    }
  }

  @MainActor
  private func analyzeTitle() async {
    let title = sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    isAnalyzing = true
    defer { isAnalyzing = false }
    do {
      let response: EpisodeRuleTokenizeResponse
      if MobileDebugConfiguration.usesFixturesAtRuntime {
        response = MobileEpisodeRuleFixtureEngine.tokenize(title)
      } else {
        response = try await store.client.tokenizeEpisodeRuleTitle(title)
      }
      marking.replaceTokens(response.tokens)
      await refreshPreview()
    } catch {
      preview = EpisodeRulePreviewResponse(
        ok: false,
        message: error.localizedDescription,
        rule: nil,
        parsedTitle: nil,
        tokens: marking.tokens,
        suggestions: []
      )
    }
  }

  @MainActor
  private func refreshPreview() async {
    let title = sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    do {
      if MobileDebugConfiguration.usesFixturesAtRuntime {
        preview = MobileEpisodeRuleFixtureEngine.preview(
          title: title,
          marks: marking.marks,
          name: ruleName,
          tokens: marking.displayTokens
        )
      } else {
        preview = try await store.client.previewEpisodeRule(
          title: title,
          marks: marking.marks,
          name: ruleName
        )
      }
      if let pattern = preview?.generatedPattern ?? preview?.rule?.pattern {
        manualRegexPattern = pattern
      }
    } catch {
      preview = EpisodeRulePreviewResponse(
        ok: false,
        message: error.localizedDescription,
        rule: nil,
        parsedTitle: nil,
        tokens: marking.tokens,
        suggestions: []
      )
    }
  }

  private func addTestCase() {
    let title = testTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    let item = EpisodeRuleTestCase(title: title, expectedMatch: testExpectedMatch)
    if !testCases.contains(item) { testCases.append(item) }
    testTitle = ""
  }

  @MainActor
  private func runTests() async {
    guard let rule = ruleForTesting, !testCases.isEmpty else { return }
    isTesting = true
    defer { isTesting = false }
    do {
      if MobileDebugConfiguration.usesFixturesAtRuntime {
        testResponse = MobileEpisodeRuleFixtureEngine.test(testCases, rule: rule)
      } else {
        testResponse = try await store.client.testGlobalEpisodeRules(
          tests: testCases,
          episodeParseRules: [rule]
        )
      }
    } catch {
      testResponse = EpisodeRuleTestResponse(
        ok: false,
        parsedTitle: ParsedAnimeTitle(originalTitle: "", parseFailureReason: error.localizedDescription),
        message: error.localizedDescription
      )
    }
  }

  @MainActor
  private func analyzeWithAI(suggestedRule: Bool) async {
    isAnalyzingWithAI = true
    aiAnalysis = await store.analyzeTitleWithAI(sampleTitle, suggestedRule: suggestedRule)
    isAnalyzingWithAI = false
  }

  private func copyPattern() {
    #if canImport(UIKit)
    UIPasteboard.general.string = generatedPattern
    #endif
    notice = "已复制生成的正则表达式。"
  }
}

struct MobileAdvancedEpisodeRuleEditor: View {
  @Environment(\.dismiss) private var dismiss
  var initialRule: EpisodeParseRule
  var save: (EpisodeParseRule) -> Void

  @State private var name: String
  @State private var pattern: String
  @State private var enabled: Bool
  @State private var episodeGroup: String
  @State private var startGroup: String
  @State private var endGroup: String
  @State private var finalGroup: String
  @State private var editsPattern: Bool
  @State private var showingConversionConfirmation = false

  init(initialRule: EpisodeParseRule, save: @escaping (EpisodeParseRule) -> Void) {
    self.initialRule = initialRule
    self.save = save
    _name = State(initialValue: initialRule.name)
    _pattern = State(initialValue: initialRule.pattern)
    _enabled = State(initialValue: initialRule.enabled)
    _episodeGroup = State(initialValue: initialRule.episodeGroup)
    _startGroup = State(initialValue: initialRule.startGroup)
    _endGroup = State(initialValue: initialRule.endGroup)
    _finalGroup = State(initialValue: initialRule.finalGroup)
    _editsPattern = State(initialValue: initialRule.mode != "visual")
  }

  var body: some View {
    Form {
        Section("规则") {
          Toggle("启用规则", isOn: $enabled)
          MobileFormTextField(label: "规则名称", prompt: "例如：星号单集规则", text: $name)
          LabeledContent("规则类型", value: editsPattern ? "高级正则" : "可视化规则")
          if editsPattern {
            MobileFormTextEditor(
              label: "正则表达式",
              hint: "使用命名捕获组标记单集 episode，或合集 start 与 end。",
              text: $pattern,
              minHeight: 110
            )
            .font(.body.monospaced())
            MobileFormValidationMessage(message: validationMessage)
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Text("生成的正则表达式")
                .font(.subheadline)
              Text(pattern)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              Text("该规则包含桌面端的可视化标记。启停或改名不会改变标记内容。")
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("转为高级正则编辑", systemImage: "chevron.left.forwardslash.chevron.right") {
                showingConversionConfirmation = true
              }
            }
          }
        }

        Section("命名捕获组") {
          MobileFormTextField(label: "单集集数", prompt: "episode", text: $episodeGroup)
          MobileFormTextField(label: "合集开始", prompt: "start", text: $startGroup)
          MobileFormTextField(label: "合集结束", prompt: "end", text: $endGroup)
          MobileFormTextField(label: "完结标记", prompt: "final", text: $finalGroup)
        }

        if let sample = initialRule.exampleTitle ?? initialRule.sampleTitle, !sample.isEmpty {
          Section("样例标题") {
            Text(sample)
              .font(.subheadline.monospaced())
              .textSelection(.enabled)
          }
        }
      }
      .alert("转为高级正则？", isPresented: $showingConversionConfirmation) {
        Button("取消", role: .cancel) {}
        Button("继续") { editsPattern = true }
      } message: {
        Text("转为高级正则后将不再保留可视化标记，但当前生成的正则表达式不会改变。")
      }
      .mobileStatusNavigationTitle("编辑识别规则")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            save(draft)
            dismiss()
          }
          .disabled(validationMessage != nil)
        }
      }
  }

  private var draft: EpisodeParseRule {
    var rule = initialRule
    rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自定义规则" : name
    rule.pattern = pattern
    rule.enabled = enabled
    rule.episodeGroup = normalized(episodeGroup, fallback: "episode")
    rule.startGroup = normalized(startGroup, fallback: "start")
    rule.endGroup = normalized(endGroup, fallback: "end")
    rule.finalGroup = normalized(finalGroup, fallback: "final")
    if initialRule.mode == "visual", editsPattern {
      rule.mode = "regex"
      rule.visualMarks = []
      rule.generatedPattern = nil
      rule.description = "由可视化规则转为高级正则"
    }
    return rule
  }

  private var validationMessage: String? {
    MobileEpisodeRuleValidation.message(for: draft)
  }

  private func normalized(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
