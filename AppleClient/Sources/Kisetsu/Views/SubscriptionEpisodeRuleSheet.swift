import SwiftUI

private struct RuleSample: Identifiable {
  let id = UUID()
  var title = ""
  var shouldMatch = true
  var expectedEpisode = ""
  var expectedEnd = ""
  var tokens: [EpisodeTitleToken] = []
  var marks: [EpisodeRuleVisualMark] = []
  var splitTokenIDs: Set<Int> = []

  var labeledExample: EpisodeRuleLabeledExample {
    EpisodeRuleLabeledExample(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      expectedEpisode: shouldMatch ? Int(expectedEpisode) : nil,
      expectedEnd: shouldMatch ? Int(expectedEnd) : nil,
      shouldMatch: shouldMatch,
      marks: shouldMatch ? marks : []
    )
  }
}

private enum RuleSampleMark: String, CaseIterable, Identifiable {
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
    case .start: "开始"
    case .end: "结束"
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

private struct RuleGroup: Identifiable {
  var id: String
  var rules: [EpisodeParseRule]
}

@MainActor
struct SubscriptionEpisodeRuleSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding private var rules: [EpisodeParseRule]
  @Binding private var useCustom: Bool

  @State private var draftRules: [EpisodeParseRule]
  @State private var draftUseCustom: Bool
  @State private var ruleName = "专属集数规则"
  @State private var samples = [RuleSample()]
  @State private var response: EpisodeRuleGenerateResponse?
  @State private var generatedExamples: [EpisodeRuleLabeledExample]?
  @State private var generatedName: String?
  @State private var selectedProfile = "default"
  @State private var isGenerating = false
  @State private var tokenizingID: UUID?
  @State private var errorMessage: String?
  @State private var appliedGroupID: String?

  init(rules: Binding<[EpisodeParseRule]>, useCustom: Binding<Bool>) {
    _rules = rules
    _useCustom = useCustom
    _draftRules = State(initialValue: rules.wrappedValue)
    _draftUseCustom = State(initialValue: useCustom.wrappedValue)
  }

  private var groups: [RuleGroup] {
    var result: [RuleGroup] = []
    for rule in draftRules {
      let key = rule.generationGroupId ?? rule.id
      if let index = result.firstIndex(where: { $0.id == key }) {
        result[index].rules.append(rule)
      } else {
        result.append(RuleGroup(id: key, rules: [rule]))
      }
    }
    return result
  }

  private var candidate: EpisodeRuleGeneratedCandidate? {
    response?.candidates.first { $0.profile == selectedProfile }
  }

  private var samplesChanged: Bool {
    generatedExamples != samples.map(\.labeledExample)
      || generatedName != ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("订阅专属集数规则")
            .font(.title3.weight(.semibold))
          Text("用真实资源标题标记集数，再验证同一作品的不同发布格式。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 18)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          currentRules
          Divider()
          sampleEditor
          if let response {
            Divider()
            resultSection(response)
          }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()
      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("完成") {
          rules = draftRules.enumerated().map { index, rule in
            var copy = rule
            copy.priority = index
            return copy
          }
          useCustom = draftUseCustom && !draftRules.isEmpty
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
    }
    .frame(minWidth: 640, idealWidth: 780, minHeight: 580, idealHeight: 700)
  }

  private var currentRules: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("当前规则")
        .font(.headline)
      if groups.isEmpty {
        Text("尚无专属规则，当前使用全局集数识别。")
          .foregroundStyle(.secondary)
      } else {
        Toggle("启用专属规则", isOn: $draftUseCustom)
        ForEach(groups) { group in
          HStack(spacing: 12) {
            Toggle(isOn: Binding(
              get: { group.rules.allSatisfy(\.enabled) },
              set: { enabled in
                for index in draftRules.indices where group.rules.contains(where: { $0.id == draftRules[index].id }) {
                  draftRules[index].enabled = enabled
                }
              }
            )) {
              VStack(alignment: .leading, spacing: 2) {
                Text(group.rules[0].name)
                Text(group.rules[0].mode == "examples"
                     ? "\(group.rules[0].examples.count) 条样例 · \(group.rules.count) 种标题格式"
                     : "旧版规则 · \(group.rules.count) 条")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
              draftRules.removeAll { rule in group.rules.contains(where: { $0.id == rule.id }) }
              if draftRules.isEmpty { draftUseCustom = false }
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移除这组规则")
            .accessibilityLabel("移除\(group.rules[0].name)")
          }
          if group.id != groups.last?.id { Divider() }
        }
      }
    }
  }

  private var sampleEditor: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("制作规则")
        .font(.headline)
      TextField("规则名称", text: $ruleName)
        .accessibilityLabel("规则名称")

      ForEach($samples) { $sample in
        RuleSampleRow(
          sample: $sample,
          isTokenizing: tokenizingID == sample.id,
          tokenize: { Task { await tokenize(sample.id) } },
          remove: samples.count > 1 ? { samples.removeAll { $0.id == sample.id } } : nil
        )
        if sample.id != samples.last?.id { Divider() }
      }

      HStack(spacing: 8) {
        Button("添加标题", systemImage: "plus") {
          if samples.count < 20 { samples.append(RuleSample()) }
        }
        .disabled(samples.count >= 20)
        Button("添加反例", systemImage: "plus.circle") {
          if samples.count < 20 { samples.append(RuleSample(shouldMatch: false)) }
        }
        .disabled(samples.count >= 20)
      }

      Divider()

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("生成规则")
            .font(.subheadline.weight(.semibold))
          Text("用全部样例检查集数与误匹配。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Button {
          Task { await generate(useAI: true) }
        } label: {
          Label("AI 生成候选", systemImage: "sparkles")
        }
        .disabled(isGenerating)

        Button {
          Task { await generate(useAI: false) }
        } label: {
          Label("生成并验证", systemImage: "checkmark.seal")
        }
        .disabled(isGenerating)
        .buttonStyle(.borderedProminent)

        if isGenerating { ProgressView().controlSize(.small) }
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  private func resultSection(_ response: EpisodeRuleGenerateResponse) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("验证结果")
        .font(.headline)
      if response.candidates.count > 1 {
        Picker("候选范围", selection: $selectedProfile) {
          ForEach(response.candidates) { candidate in
            Text(profileTitle(candidate.profile)).tag(candidate.profile)
          }
        }
        .pickerStyle(.segmented)
      }
      if let candidate {
        Label(candidate.message, systemImage: candidate.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(candidate.ok && !samplesChanged ? .green : .orange)
        if !candidate.anchors.isEmpty {
          Text("共同关键词：\(candidate.anchors.joined(separator: "、"))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(Array(candidate.results.enumerated()), id: \.offset) { index, result in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.status == "correct" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
              .foregroundStyle(result.status == "correct" ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
              Text("样例 \(index + 1) · \(result.message)")
                .font(.subheadline.weight(.medium))
              Text(result.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            }
          }
        }
        if samplesChanged {
          Text("样例已更改，请重新生成并验证。")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Button("采用此候选") { apply(candidate) }
          .disabled(!candidate.ok || samplesChanged || candidate.rules.isEmpty)
      }
      if !response.aiConfigured && response.candidates.count == 1 {
        Text(response.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func profileTitle(_ profile: String) -> String {
    switch profile {
    case "lenient": "宽松"
    case "balanced": "均衡"
    case "strict": "严格"
    default: "默认"
    }
  }

  private func tokenize(_ id: UUID) async {
    guard let index = samples.firstIndex(where: { $0.id == id }) else { return }
    let title = samples[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { errorMessage = "请先输入资源标题。"; return }
    tokenizingID = id
    errorMessage = nil
    defer { tokenizingID = nil }
    do {
      let result = try await store.client.tokenizeEpisodeRuleTitle(title)
      guard let current = samples.firstIndex(where: { $0.id == id }),
            samples[current].title.trimmingCharacters(in: .whitespacesAndNewlines) == title else { return }
      samples[current].tokens = result.tokens
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func validatedExamples() -> [EpisodeRuleLabeledExample]? {
    guard !samples.isEmpty, samples.count <= 20 else { errorMessage = "最多添加 20 条标题。"; return nil }
    let examples = samples.map(\.labeledExample)
    for example in examples {
      if example.title.isEmpty || example.title.count > 512 {
        errorMessage = "每条样例都需要 1 至 512 字的资源标题。"
        return nil
      }
      if example.shouldMatch {
        guard let episode = example.expectedEpisode, (1...999).contains(episode), !example.marks.isEmpty else {
          errorMessage = "请解析正例标题，点击集数数字并确认预期集数。"
          return nil
        }
        if let end = example.expectedEnd, end <= episode {
          errorMessage = "合集结束集数必须大于开始集数。"
          return nil
        }
      }
    }
    guard examples.contains(where: \.shouldMatch) else {
      errorMessage = "至少需要一条应匹配的标题。"
      return nil
    }
    return examples
  }

  private func generate(useAI: Bool) async {
    guard !isGenerating else { return }
    errorMessage = nil
    guard let examples = validatedExamples() else { return }
    let name = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80 else { errorMessage = "请输入 1 至 80 字的规则名称。"; return }
    let backendURL = store.backendURL
    isGenerating = true
    defer { isGenerating = false }
    do {
      let value = try await store.client.generateEpisodeRules(
        EpisodeRuleGenerateRequest(name: name, examples: examples, useAi: useAI)
      )
      guard store.backendURL == backendURL,
            samples.map(\.labeledExample) == examples,
            ruleName.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return }
      response = value
      generatedExamples = examples
      generatedName = name
      selectedProfile = "default"
    } catch {
      if store.backendURL == backendURL { errorMessage = error.localizedDescription }
    }
  }

  private func apply(_ candidate: EpisodeRuleGeneratedCandidate) {
    guard candidate.ok, !samplesChanged, let groupID = candidate.rules.first?.generationGroupId else { return }
    if let appliedGroupID {
      draftRules.removeAll { $0.generationGroupId == appliedGroupID }
    }
    draftRules.append(contentsOf: candidate.rules)
    draftUseCustom = true
    appliedGroupID = groupID
    errorMessage = nil
  }
}

@MainActor
private struct RuleSampleRow: View {
  @Binding var sample: RuleSample
  var isTokenizing: Bool
  var tokenize: () -> Void
  var remove: (() -> Void)?
  @State private var markType: RuleSampleMark = .episode
  @State private var history: [RuleSample] = []

  private var displayTokens: [EpisodeTitleToken] {
    sample.tokens.flatMap { token in
      guard sample.splitTokenIDs.contains(token.id), token.text.count > 1 else { return [token] }
      let groupID = "split-\(token.id)"
      return token.text.enumerated().map { offset, character in
        let value = String(character)
        return EpisodeTitleToken(
          id: token.id * 10000 + offset + 1,
          text: value,
          startIndex: token.startIndex + offset,
          endIndex: token.startIndex + offset + 1,
          kind: value.rangeOfCharacter(from: .decimalDigits) == nil ? "text" : "number",
          splitGroupId: groupID,
          isSplit: true
        )
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Toggle("应匹配", isOn: $sample.shouldMatch)
          .toggleStyle(.checkbox)
        Spacer()
        if let remove {
          Button(role: .destructive, action: remove) {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("移除这条标题")
          .accessibilityLabel("移除这条标题")
        }
      }
      TextField("资源标题", text: Binding(
        get: { sample.title },
        set: { value in
          guard value != sample.title else { return }
          sample.title = value
          sample.tokens = []
          sample.marks = []
          sample.splitTokenIDs = []
          sample.expectedEpisode = ""
          sample.expectedEnd = ""
          history.removeAll()
        }
      ))
      .accessibilityLabel("资源标题")

      if sample.shouldMatch {
        HStack {
          Button("分析标题", systemImage: "sparkle.magnifyingglass", action: tokenize)
            .disabled(isTokenizing || sample.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if isTokenizing { ProgressView().controlSize(.small) }
        }
        if !sample.tokens.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("标记集数")
              .font(.headline)
            Text("选择标记类型，然后点击标题中的对应片段。")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
              markPicker
                .frame(width: 142, alignment: .topLeading)
              VStack(alignment: .leading, spacing: 8) {
                EpisodeTokenFlowLayout(spacing: 6, rowSpacing: 6) {
                  ForEach(displayTokens) { token in
                    Button { applyMark(token) } label: { tokenLabel(token) }
                      .buttonStyle(.plain)
                      .help("\(markType.title)：\(token.text)")
                  }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                  Text(markSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button("撤销", systemImage: "arrow.uturn.backward") { undoMark() }
                    .disabled(history.isEmpty)
                  Button("重置标记", systemImage: "arrow.counterclockwise") { resetMarks() }
                    .disabled(sample.marks.isEmpty && sample.splitTokenIDs.isEmpty)
                }
                .buttonStyle(.borderless)
              }
            }
          }
          .padding(12)
          .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        }
      } else {
        Text("此标题不应被专属规则匹配。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var markPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("选择要标记的内容")
        .font(.caption.weight(.semibold))
      ForEach(RuleSampleMark.allCases) { mode in
        Button {
          markType = mode
        } label: {
          HStack {
            Circle()
              .fill(mode.color.opacity(markType == mode ? 0.9 : 0.35))
              .frame(width: 8, height: 8)
            Text(mode.title)
            Spacer()
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(markType == mode ? mode.color.opacity(0.13) : Color.clear,
                      in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var markSummary: String {
    if let episode = Int(sample.expectedEpisode) {
      if let end = Int(sample.expectedEnd) { return "已标记第 \(episode) 至 \(end) 集。" }
      return "已标记第 \(episode) 集。"
    }
    return "请选择单集集数，或同时标记合集开始和结束。"
  }

  private func tokenLabel(_ token: EpisodeTitleToken) -> some View {
    let selectedMark = sample.marks.first { $0.tokenId == token.id }
    let mode = selectedMark.flatMap { RuleSampleMark(rawValue: $0.markType) }
    return HStack(spacing: 4) {
      Text(token.text)
        .font(token.kind == "number" || token.kind == "final" ? .body.monospaced().weight(.semibold) : .body)
      if let mode {
        Text(mode.title)
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(mode.color.opacity(0.16), in: Capsule())
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background((mode?.color ?? Color.secondary).opacity(selectedMark == nil ? 0.08 : 0.18), in: Capsule())
    .overlay {
      Capsule().stroke((mode?.color ?? Color.secondary).opacity(selectedMark == nil ? 0.28 : 0.55))
    }
  }

  private func applyMark(_ token: EpisodeTitleToken) {
    history.append(sample)
    if markType == .split {
      if let groupID = token.splitGroupId,
         let originalID = Int(groupID.replacingOccurrences(of: "split-", with: "")) {
        sample.marks.removeAll { $0.splitGroupId == groupID }
        sample.splitTokenIDs.remove(originalID)
      } else if token.text.count > 1 {
        sample.splitTokenIDs.insert(token.id)
      }
    } else if markType == .clear {
      sample.marks.removeAll { $0.tokenId == token.id }
    } else {
      if markType != .final {
        guard let number = Int(token.text), (1...999).contains(number) else {
          history.removeLast()
          return
        }
      }
      let wasSelected = sample.marks.contains { $0.tokenId == token.id && $0.markType == markType.rawValue }
      sample.marks.removeAll { $0.tokenId == token.id || $0.markType == markType.rawValue }
      if !wasSelected {
        sample.marks.append(EpisodeRuleVisualMark(
          tokenId: token.id,
          tokenText: token.text,
          markType: markType.rawValue,
          startIndex: token.startIndex,
          endIndex: token.endIndex,
          splitGroupId: token.splitGroupId
        ))
      }
      if markType == .episode {
        sample.marks.removeAll { $0.markType == RuleSampleMark.start.rawValue || $0.markType == RuleSampleMark.end.rawValue }
      } else if markType == .start || markType == .end {
        sample.marks.removeAll { $0.markType == RuleSampleMark.episode.rawValue }
      }
    }
    sample.expectedEpisode = sample.marks.first { $0.markType == RuleSampleMark.episode.rawValue
      || $0.markType == RuleSampleMark.start.rawValue }.flatMap { Int($0.tokenText) }.map(String.init) ?? ""
    sample.expectedEnd = sample.marks.first { $0.markType == RuleSampleMark.end.rawValue }
      .flatMap { Int($0.tokenText) }.map(String.init) ?? ""
  }

  private func undoMark() {
    guard let previous = history.popLast() else { return }
    sample = previous
  }

  private func resetMarks() {
    history.append(sample)
    sample.marks = []
    sample.splitTokenIDs = []
    sample.expectedEpisode = ""
    sample.expectedEnd = ""
  }
}
