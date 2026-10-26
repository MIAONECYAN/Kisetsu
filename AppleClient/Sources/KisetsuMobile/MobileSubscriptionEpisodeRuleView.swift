import SwiftUI

struct MobileSubscriptionRuleSample: Identifiable {
  let id = UUID()
  var title = ""
  var shouldMatch = true
  var marking = MobileEpisodeRuleMarkingState()

  var expectedEpisode: Int? {
    marking.marks.first { $0.markType == MobileEpisodeMarkMode.episode.rawValue
      || $0.markType == MobileEpisodeMarkMode.start.rawValue }
      .flatMap { Int($0.tokenText) }
  }

  var expectedEnd: Int? {
    marking.marks.first { $0.markType == MobileEpisodeMarkMode.end.rawValue }
      .flatMap { Int($0.tokenText) }
  }

  var labeledExample: EpisodeRuleLabeledExample {
    EpisodeRuleLabeledExample(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      expectedEpisode: shouldMatch ? expectedEpisode : nil,
      expectedEnd: shouldMatch ? expectedEnd : nil,
      shouldMatch: shouldMatch,
      marks: shouldMatch ? marking.marks : []
    )
  }
}

private struct MobileSubscriptionRuleGroup: Identifiable {
  var id: String
  var rules: [EpisodeParseRule]
}

@MainActor
struct MobileSubscriptionEpisodeRuleView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding private var rules: [EpisodeParseRule]
  @Binding private var useCustom: Bool

  @State private var draftRules: [EpisodeParseRule]
  @State private var draftUseCustom: Bool
  @State private var ruleName = "专属集数规则"
  @State private var samples = [MobileSubscriptionRuleSample()]
  @State private var response: EpisodeRuleGenerateResponse?
  @State private var generatedExamples: [EpisodeRuleLabeledExample]?
  @State private var generatedName: String?
  @State private var selectedProfile = "default"
  @State private var isGenerating = false
  @State private var aiConfigured = false
  @State private var tokenizingID: UUID?
  @State private var errorMessage: String?
  @State private var appliedGroupID: String?
  @State private var legacyEditorRoute: MobileEpisodeRuleEditorRoute?

  init(rules: Binding<[EpisodeParseRule]>, useCustom: Binding<Bool>) {
    _rules = rules
    _useCustom = useCustom
    _draftRules = State(initialValue: rules.wrappedValue)
    _draftUseCustom = State(initialValue: useCustom.wrappedValue)
  }

  private var groups: [MobileSubscriptionRuleGroup] {
    var result: [MobileSubscriptionRuleGroup] = []
    for rule in draftRules {
      let key = rule.generationGroupId ?? rule.id
      if let index = result.firstIndex(where: { $0.id == key }) {
        result[index].rules.append(rule)
      } else {
        result.append(MobileSubscriptionRuleGroup(id: key, rules: [rule]))
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
    Form {
      Section("当前规则") {
        if groups.isEmpty {
          Text("尚无专属规则，当前使用全局集数识别。")
            .foregroundStyle(.secondary)
        } else {
          Toggle("启用专属规则", isOn: $draftUseCustom)
          ForEach(groups) { group in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(group.rules[0].name)
                Text(group.rules[0].mode == "examples"
                     ? "\(group.rules[0].examples.count) 条样例 · \(group.rules.count) 种标题格式"
                     : "旧版规则 · \(group.rules.count) 条")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Toggle("启用\(group.rules[0].name)", isOn: Binding(
                get: { group.rules.allSatisfy(\.enabled) },
                set: { enabled in
                  for index in draftRules.indices where group.rules.contains(where: { $0.id == draftRules[index].id }) {
                    draftRules[index].enabled = enabled
                  }
                }
              ))
              .labelsHidden()
              Button(role: .destructive) {
                draftRules.removeAll { rule in group.rules.contains(where: { $0.id == rule.id }) }
                if draftRules.isEmpty { draftUseCustom = false }
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("移除\(group.rules[0].name)")
            }
            if group.rules[0].mode != "examples" {
              Button("编辑旧版规则") {
                let rule = group.rules[0]
                legacyEditorRoute = MobileEpisodeRuleEditorRoute(
                  kind: rule.mode == "regex" ? .advanced : .visual,
                  rule: rule,
                  isNew: false
                )
              }
            }
          }
        }
      }

      Section("制作规则") {
        MobileFormTextField(label: "规则名称", prompt: "例如：专属集数规则", text: $ruleName)
        ForEach($samples) { $sample in
          MobileSubscriptionRuleSampleEditor(
            sample: $sample,
            isTokenizing: tokenizingID == sample.id,
            tokenize: { Task { await tokenize(sample.id) } },
            remove: samples.count > 1 ? { samples.removeAll { $0.id == sample.id } } : nil
          )
        }
        GlassEffectContainer(spacing: 10) {
          HStack(spacing: 10) {
            Button {
              samples.append(MobileSubscriptionRuleSample())
            } label: {
              Label("添加标题", systemImage: "plus")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            Button {
              samples.append(MobileSubscriptionRuleSample(shouldMatch: false))
            } label: {
              Label("添加反例", systemImage: "plus.circle")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
          }
        }
        .controlSize(.large)
        .disabled(samples.count >= 20)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }

      Section("生成规则") {
        VStack(alignment: .leading, spacing: 12) {
          Text("使用所有标题验证具体集数；反例不应匹配。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button {
            Task { await generate(useAI: false) }
          } label: {
            Label("生成并验证", systemImage: "checkmark.seal")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
          .fontWeight(.semibold)
          .disabled(isGenerating)
          if aiConfigured {
            Button {
              Task { await generate(useAI: true) }
            } label: {
              Label("AI 生成候选", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(isGenerating)
          }
          if isGenerating { ProgressView("正在验证样例") }
          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .controlSize(.large)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }

      if let response {
        resultSection(response)
      }
    }
    .mobileStatusNavigationTitle("订阅专属集数规则")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("完成") {
          rules = draftRules.enumerated().map { index, rule in
            var copy = rule
            copy.priority = index
            return copy
          }
          useCustom = draftUseCustom && !draftRules.isEmpty
          dismiss()
        }
        .disabled(isGenerating)
      }
    }
    .navigationDestination(item: $legacyEditorRoute) { route in
      MobileEpisodeRuleEditorDestination(route: route) { updated in
        MobileEpisodeRuleCollection.save(updated, to: &draftRules)
      }
      .environmentObject(store)
    }
    .task(id: store.backendURL) {
      await loadAIConfiguration()
    }
  }

  private func resultSection(_ response: EpisodeRuleGenerateResponse) -> some View {
    Section("验证结果") {
      if response.candidates.count > 1 {
        Picker("候选范围", selection: $selectedProfile) {
          ForEach(response.candidates) { item in
            Text(profileTitle(item.profile)).tag(item.profile)
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
          VStack(alignment: .leading, spacing: 4) {
            Label("样例 \(index + 1) · \(result.message)",
                  systemImage: result.status == "correct" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
              .foregroundStyle(result.status == "correct" ? .green : .orange)
            Text(result.title)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
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
      Text(response.message)
        .font(.caption)
        .foregroundStyle(.secondary)
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

  private func loadAIConfiguration() async {
    let backendURL = store.backendURL
    aiConfigured = false
    do {
      let settings = try await store.client.aiSettings()
      guard !Task.isCancelled, store.backendURL == backendURL else { return }
      aiConfigured = settings.configured
    } catch {
      guard !Task.isCancelled, store.backendURL == backendURL else { return }
      errorMessage = "AI 设置读取失败，仍可使用默认规则：\(error.localizedDescription)"
    }
  }

  private func tokenize(_ id: UUID) async {
    guard let sample = samples.first(where: { $0.id == id }) else { return }
    let title = sample.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { errorMessage = "请先输入资源标题。"; return }
    let backendURL = store.backendURL
    tokenizingID = id
    errorMessage = nil
    defer { tokenizingID = nil }
    do {
      let result = try await store.client.tokenizeEpisodeRuleTitle(title)
      guard store.backendURL == backendURL,
            let index = samples.firstIndex(where: { $0.id == id }),
            samples[index].title.trimmingCharacters(in: .whitespacesAndNewlines) == title else { return }
      samples[index].marking.replaceTokens(result.tokens)
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
          errorMessage = "请分析正例标题，点击集数数字并确认预期集数。"
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
      errorMessage = error.localizedDescription
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
private struct MobileSubscriptionRuleSampleEditor: View {
  @Binding var sample: MobileSubscriptionRuleSample
  var isTokenizing: Bool
  var tokenize: () -> Void
  var remove: (() -> Void)?
  @State private var markMode = MobileEpisodeMarkMode.episode

  var body: some View {
    Toggle("应匹配", isOn: $sample.shouldMatch)
    MobileFormTextEditor(label: "资源标题", text: $sample.title, minHeight: 62)
      .onChange(of: sample.title) { _, _ in
        sample.marking = MobileEpisodeRuleMarkingState()
      }
    if sample.shouldMatch {
      Button(action: tokenize) {
        Label("分析标题", systemImage: "sparkle.magnifyingglass")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glass)
      .controlSize(.large)
      .disabled(isTokenizing || sample.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      if isTokenizing { ProgressView() }
      if !sample.marking.tokens.isEmpty {
        markModeSelector
        MobileTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 7) {
          ForEach(sample.marking.displayTokens) { token in
            tokenButton(token)
          }
        }
        Text(markSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("撤销", systemImage: "arrow.uturn.backward") { _ = sample.marking.undo() }
            .disabled(sample.marking.history.isEmpty)
          Spacer()
          Button("重置标记", systemImage: "arrow.counterclockwise") { sample.marking.reset() }
            .disabled(sample.marking.marks.isEmpty)
        }
        .font(.caption)
      }
    } else {
      Text("此标题不应被专属规则匹配。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    if let remove {
      Button("移除这条标题", systemImage: "trash", role: .destructive, action: remove)
    }
  }

  private var markSummary: String {
    guard let episode = sample.expectedEpisode else { return "点击标题中的集数数字完成标记。" }
    if let end = sample.expectedEnd { return "已标记第 \(episode) 至 \(end) 集。" }
    return "已标记第 \(episode) 集。"
  }

  private var markModeSelector: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("选择要标记的内容")
        .font(.caption.weight(.semibold))
      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(MobileEpisodeMarkMode.allCases) { mode in
              Button { markMode = mode } label: {
                HStack(spacing: 7) {
                  Circle()
                    .fill(mode.color.opacity(markMode == mode ? 0.9 : 0.4))
                    .frame(width: 8, height: 8)
                  Text(markModeTitle(mode))
                    .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Capsule())
              }
              .buttonStyle(.plain)
              .glassEffect(
                markMode == mode
                  ? .regular.tint(mode.color.opacity(0.2)).interactive()
                  : .regular.interactive(),
                in: .capsule
              )
              .accessibilityLabel(mode.title)
              .accessibilityAddTraits(markMode == mode ? .isSelected : [])
            }
          }
        }
      }
      .scrollIndicators(.hidden)
    }
  }

  private func markModeTitle(_ mode: MobileEpisodeMarkMode) -> String {
    switch mode {
    case .episode: "单集"
    case .start: "开始"
    case .end: "结束"
    case .final: "完结"
    case .split: "拆分"
    case .clear: "清除"
    }
  }

  private func tokenButton(_ token: EpisodeTitleToken) -> some View {
    let selected = sample.marking.marks.first { $0.tokenId == token.id }
      .flatMap { MobileEpisodeMarkMode(rawValue: $0.markType) }
    let requiresNumber = markMode == .episode || markMode == .start || markMode == .end
    let validNumber = Int(token.text).map { (1...999).contains($0) } ?? false
    return Button {
      _ = sample.marking.apply(markMode, to: token)
      if markMode == .episode {
        sample.marking.marks.removeAll { $0.markType == MobileEpisodeMarkMode.start.rawValue
          || $0.markType == MobileEpisodeMarkMode.end.rawValue }
      } else if markMode == .start || markMode == .end {
        sample.marking.marks.removeAll { $0.markType == MobileEpisodeMarkMode.episode.rawValue }
      }
    } label: {
      HStack(spacing: 4) {
        Text(token.text)
          .font(token.kind == "number" ? .body.monospaced().weight(.semibold) : .body)
        if let selected { Text(selected.title).font(.caption2.weight(.semibold)) }
      }
      .padding(.horizontal, 9)
      .frame(minHeight: 36)
      .background((selected?.color ?? Color.secondary).opacity(selected == nil ? 0.08 : 0.18), in: Capsule())
      .overlay(Capsule().stroke((selected?.color ?? Color.secondary).opacity(0.32)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .frame(minHeight: 44)
    .disabled(requiresNumber && !validNumber)
  }
}
