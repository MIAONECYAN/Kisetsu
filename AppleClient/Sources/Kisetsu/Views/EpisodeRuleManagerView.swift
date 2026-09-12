import AppKit
import SwiftUI

private enum EpisodeMarkMode: String, CaseIterable, Identifiable {
  case episode
  case start
  case end
  case final
  case split
  case clear

  var id: String { rawValue }

  var title: String {
    switch self {
    case .episode: "标记单集"
    case .start: "标记合集开始"
    case .end: "标记合集结束"
    case .final: "标记完结"
    case .split: "拆分片段"
    case .clear: "清除标记"
    }
  }

  var shortTitle: String {
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

private struct EpisodeRuleEditorSnapshot {
  var marks: [EpisodeRuleVisualMark]
  var splitTokenIDs: Set<Int>
}

struct EpisodeRuleManagerView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var rules: [EpisodeParseRule]
  var builtinRules: [EpisodeParseRule]
  var scopeTitle: String
  var emptyTitle: String
  var emptyDescription: String
  var showBuiltinRules = true
  var compactMode = false

  @State private var showingRuleEditor = false
  @State private var ruleName = ""
  @State private var sampleTitle = ""
  @State private var tokens: [EpisodeTitleToken] = []
  @State private var marks: [EpisodeRuleVisualMark] = []
  @State private var markHistory: [EpisodeRuleEditorSnapshot] = []
  @State private var splitTokenIDs: Set<Int> = []
  @State private var markMode: EpisodeMarkMode = .episode
  @State private var preview: EpisodeRulePreviewResponse?
  @State private var tokenizeTask: Task<Void, Never>?
  @State private var ruleToDelete: EpisodeParseRule?
  @State private var testTitle = ""
  @State private var testExpectedMatch = true
  @State private var testCases: [EpisodeRuleTestCase] = []
  @State private var testResponse: EpisodeRuleTestResponse?
  @State private var regexName = ""
  @State private var regexPattern = ""
  @State private var regexEpisodeGroup = "episode"
  @State private var regexStartGroup = "start"
  @State private var regexEndGroup = "end"
  @State private var regexFinalGroup = "final"
  @State private var editingRuleID: String?
  @State private var markNotice: String?
  @State private var manualRegexMode = false
  @State private var regexCopiedMessage: String?
  @State private var showingManualConvertConfirmation = false
  @State private var aiAnalysis: AITitleAnalysisResponse?
  @State private var showingMoreTests = false
  @State private var showingAssistedTools = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(scopeTitle)
        .font(.headline)
      if compactMode {
        compactSummarySection
      }
      if showBuiltinRules && !compactMode {
        builtinSection
      }
      myRulesSection
      if showingRuleEditor {
        builderSection
      } else {
        Button {
          startNewRule()
        } label: {
          Label(rules.isEmpty ? "新增规则" : "添加另一条规则", systemImage: "plus.circle")
        }
      }
    }
  }

  private var compactSummarySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(rules.isEmpty ? "当前使用全局规则" : "已添加 \(rules.count) 条专属规则", systemImage: rules.isEmpty ? "globe" : "number.circle")
        .font(.subheadline.weight(.semibold))
      Text("只有当这个订阅的资源标题无法正确识别集数时，才需要添加专属规则。专属规则优先，未命中时回退全局规则。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
  }

  private var builtinSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("系统内置规则")
        .font(.headline)
      Text("软件自带，默认启用，用于识别常见资源标题格式。内置规则不可删除。")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(builtinRules) { rule in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(rule.enabled ? .green : .secondary)
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
              Text(rule.name)
                .font(.caption.weight(.semibold))
              Text("内置")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let example = rule.exampleTitle ?? rule.sampleTitle {
              Text(example)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            if let description = rule.description {
              Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
        .padding(.vertical, 5)
      }
    }
  }

  private var myRulesSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("我的规则")
            .font(.headline)
          Text("规则会按顺序尝试匹配。排在前面的规则优先。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      if rules.isEmpty && compactMode {
        EmptyView()
      } else if rules.isEmpty {
        ContentUnavailableView(emptyTitle, systemImage: "number", description: Text(emptyDescription))
          .frame(maxWidth: .infinity, minHeight: 120)
      } else {
        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
          userRuleRow(rule: rule, index: index)
          if index < rules.count - 1 {
            Divider()
          }
        }
      }
    }
  }

  private func userRuleRow(rule: EpisodeParseRule, index: Int) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Toggle("", isOn: Binding {
        rule.enabled
      } set: { value in
        rules[index].enabled = value
      })
      .labelsHidden()
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(rule.name)
            .font(.body.weight(.medium))
          Text(rule.mode == "visual" ? "我的 · 可视化" : "我的 · 高级")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(rule.exampleTitle ?? rule.sampleTitle ?? rule.pattern)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let description = rule.description {
          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button {
        moveRule(index, -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0)
      .help("上移")
      Button {
        moveRule(index, 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(index >= rules.count - 1)
      .help("下移")
      Button(role: .destructive) {
        ruleToDelete = rule
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("删除规则")
      Button {
        editRule(rule)
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("编辑规则")
    }
    .padding(.vertical, 6)
    .alert("删除这条规则？", isPresented: Binding {
      ruleToDelete != nil
    } set: { showing in
      if !showing {
        ruleToDelete = nil
      }
    }) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        if let ruleToDelete {
          rules.removeAll { $0.id == ruleToDelete.id }
          normalizePriorities()
        }
        ruleToDelete = nil
      }
    } message: {
      Text("只会删除这条自定义规则，不会影响系统内置规则。")
    }
  }

  private var builderSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Divider()
      editorHeader
      stepSampleTitle
      if sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lightEmptyHint
      } else {
        stepMarkEpisode
        recognitionResultCard
      }
      if preview?.rule != nil {
        testSection
      }
      if !sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        assistedToolsSection
      }
      editorActionBar
    }
  }

  private var editorHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(editingRuleID == nil ? "新增集数识别规则" : "编辑集数识别规则")
        .font(.title3.weight(.semibold))
      Text("粘贴一个资源标题，标记其中的集数片段。普通用户不需要写正则。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var lightEmptyHint: some View {
    Label("粘贴标题后，这里会显示可点击片段。", systemImage: "text.viewfinder")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
  }

  private func stepCard(_ number: Int, _ title: String, subtitle: String? = nil, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(number)")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .frame(width: 20, height: 20)
          .background(Color.accentColor, in: Circle())
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      content()
    }
    .padding(12)
    .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
  }

  private var stepSampleTitle: some View {
    stepCard(1, "样例标题", subtitle: "先粘贴一条识别失败或格式特殊的资源标题。") {
      LabeledTextField(label: "规则名称", placeholder: "可留空，保存时自动生成", text: $ruleName)
      FormField(label: "资源标题样例") {
        VStack(alignment: .leading, spacing: 8) {
          TextField("", text: $sampleTitle, prompt: Text("粘贴一个识别失败的资源标题"))
            .onSubmit { tokenizeAndPreview() }
            .onChange(of: sampleTitle) { _, _ in scheduleTokenize() }
            .accessibilityLabel("资源标题样例")
          HStack {
            Button {
              tokenizeAndPreview()
            } label: {
              Label("分析标题", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
            Text("例如：六四位元字幕组★番名★01~12(完)★1920x1080")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var stepMarkEpisode: some View {
    stepCard(2, "标记集数", subtitle: "选择标记类型，然后点击标题中的对应片段。") {
      if sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("标题拆分后，标记工具和可点击片段会显示在这里。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        HStack(alignment: .top, spacing: 12) {
          markModePicker
            .frame(width: 142, alignment: .topLeading)
          VStack(alignment: .leading, spacing: 8) {
            tokenizedTitleView
            HStack {
              if let markNotice {
                Label(markNotice, systemImage: "info.circle")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                undoMark()
              } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
              }
              .buttonStyle(.borderless)
              .disabled(markHistory.isEmpty)
              Button {
                resetMarks()
              } label: {
                Label("重置标记", systemImage: "arrow.counterclockwise")
              }
              .buttonStyle(.borderless)
              .disabled(marks.isEmpty)
            }
          }
        }
      }
    }
  }

  private var markModePicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("选择要标记的内容")
        .font(.caption.weight(.semibold))
      ForEach(EpisodeMarkMode.allCases) { mode in
        Button {
          markMode = mode
        } label: {
          HStack {
            Circle()
              .fill(mode.color.opacity(markMode == mode ? 0.9 : 0.35))
              .frame(width: 8, height: 8)
            Text(mode.shortTitle)
            Spacer()
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(markMode == mode ? mode.color.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(markModeHelp(mode))
      }
    }
  }

  private func markModeHelp(_ mode: EpisodeMarkMode) -> String {
    switch mode {
    case .episode: "例如 EP10 中的 10"
    case .start: "例如 01~12 中的 01"
    case .end: "例如 01~12 中的 12"
    case .final: "例如 完、END、Fin"
    case .split: "把一个片段拆得更细。再次点击拆分片段可合并。"
    case .clear: "清除已经标记的片段"
    }
  }

  private var recognitionResultCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("识别结果")
        .font(.headline)
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: preview?.ok == true ? "checkmark.circle.fill" : "info.circle")
          .foregroundStyle(preview?.ok == true ? .green : .secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(preview?.message ?? "请选择单集集数，或同时选择合集开始和合集结束。")
            .font(.body.weight(.medium))
          if preview?.rule != nil {
            Text("已生成规则。完整正则可在高级区域查看。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ForEach(preview?.warnings ?? [], id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
  }

  private var assistedToolsSection: some View {
    DisclosureGroup("辅助工具", isExpanded: $showingAssistedTools) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("AI 辅助")
            .font(.subheadline.weight(.semibold))
          Text("AI 只是辅助理解标题或生成草稿，不会自动覆盖当前标记，也不会直接保存规则。")
            .font(.caption)
            .foregroundStyle(.secondary)
          if store.aiSettings.configured {
            HStack(alignment: .top, spacing: 10) {
              Button {
                Task { await analyzeCurrentTitleWithAI(suggestedRule: false) }
              } label: {
                Label("AI 解析这个标题", systemImage: "sparkles")
              }
              .help("让 AI 判断番名、集数、分辨率、字幕组等信息，只用于理解这个标题。")
              Button {
                Task { await analyzeCurrentTitleWithAI(suggestedRule: true) }
              } label: {
                Label("AI 生成规则草稿", systemImage: "wand.and.stars")
              }
              .help("让 AI 根据当前标题生成一条可测试的规则草稿，确认后才会保存。")
            }
            .disabled(sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          } else {
            VStack(alignment: .leading, spacing: 6) {
              Text("AI 辅助未配置。你仍然可以使用本地可视化标记创建规则。")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("需要 AI 时，到 设置 → AI 辅助分析 配置 Provider、Base URL、模型和 API Key。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          if let aiAnalysis {
            aiAnalysisView(aiAnalysis)
          }
        }
        advancedRegexSection
      }
      .padding(.top, 6)
    }
  }

  private var editorActionBar: some View {
    HStack(alignment: .center, spacing: 10) {
      Button {
        cancelRuleEditing()
      } label: {
        Label("取消", systemImage: "xmark.circle")
      }
      Spacer()
      if let reason = saveDisabledReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.trailing)
      }
      Button {
        if manualRegexMode {
          saveRegexRule()
        } else {
          saveVisualRule()
        }
      } label: {
        Label(editingRuleID == nil ? "保存规则" : "保存修改", systemImage: "checkmark.circle")
      }
      .buttonStyle(.borderedProminent)
      .disabled(saveDisabledReason != nil)
    }
    .padding(.top, 4)
  }

  private var advancedRegexSection: some View {
    DisclosureGroup("高级：使用正则表达式") {
      VStack(alignment: .leading, spacing: 10) {
        if manualRegexMode {
          manualRegexEditor
        } else {
          generatedRegexPanel
        }
      }
      .padding(.top, 6)
    }
    .alert("转为手动编辑？", isPresented: $showingManualConvertConfirmation) {
      Button("取消", role: .cancel) {}
      Button("继续") {
        convertGeneratedPatternToManual()
      }
    } message: {
      Text("转为手动编辑后，系统将不再根据可视化标记自动更新这个正则。是否继续？")
    }
  }

  private var generatedRegexPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("以下正则由你的标记自动生成。通常不需要修改。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if generatedPatternText.isEmpty {
        Label(generatedPatternUnavailableText, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      } else {
        CodeBlockView(text: generatedPatternText, isReadOnly: true)
      }
      if let preview {
        HStack(spacing: 10) {
          Label(preview.message, systemImage: preview.ok ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(preview.ok ? .green : .orange)
          if let confidence = preview.confidence {
            Text("置信度 \(Int(confidence * 100))%")
              .foregroundStyle(confidence >= 0.75 ? .green : .orange)
          }
        }
        .font(.caption)
        if !preview.explanation.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(preview.explanation, id: \.self) { item in
              Label(item, systemImage: "lightbulb")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if !preview.warnings.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(preview.warnings, id: \.self) { item in
              Label(item, systemImage: "exclamationmark.triangle")
            }
          }
          .font(.caption)
          .foregroundStyle(.orange)
        }
        if !preview.positiveTests.isEmpty || !preview.negativeTests.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("建议测试")
              .font(.caption.weight(.semibold))
            ForEach(preview.positiveTests, id: \.self) { title in
              Button {
                testCases.append(EpisodeRuleTestCase(title: title, expectedMatch: true))
              } label: {
                Label("应该匹配：\(title)", systemImage: "plus.circle")
              }
              .buttonStyle(.link)
            }
            ForEach(preview.negativeTests, id: \.self) { title in
              Button {
                testCases.append(EpisodeRuleTestCase(title: title, expectedMatch: false))
              } label: {
                Label("不应该匹配：\(title)", systemImage: "plus.circle")
              }
              .buttonStyle(.link)
            }
          }
          .font(.caption)
        }
      }
      HStack(spacing: 8) {
        Button {
          copyGeneratedPattern()
        } label: {
          Label("复制", systemImage: "doc.on.doc")
        }
        .disabled(generatedPatternText.isEmpty)
        Button {
          Task { await refreshPreview() }
        } label: {
          Label("重新生成", systemImage: "arrow.clockwise")
        }
        .disabled(sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || marks.isEmpty)
        Button {
          showingManualConvertConfirmation = true
        } label: {
          Label("转为手动编辑", systemImage: "pencil")
        }
        .disabled(generatedPatternText.isEmpty)
        Button {
          manualRegexMode = true
          regexName = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
          regexPattern = generatedPatternText
        } label: {
          Label("手动创建正则规则", systemImage: "curlybraces")
        }
        Spacer()
        if let regexCopiedMessage {
          Text(regexCopiedMessage)
            .font(.caption)
            .foregroundStyle(.green)
        }
      }
    }
  }

  private var manualRegexEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("你正在手动编辑正则。可视化标记不会再自动更新它。")
        .font(.caption)
        .foregroundStyle(.secondary)
      LabeledTextField(label: "规则名称", placeholder: "例如：星号单集规则", text: $regexName)
      FormField(label: "正则表达式", help: "使用命名捕获组，例如 episode、start、end、final。") {
        TextField("", text: $regexPattern, prompt: Text("例如：★(?P<episode>\\d{1,3})★"))
          .font(.body.monospaced())
          .accessibilityLabel("正则表达式")
      }
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          TextField("集数捕获名称", text: $regexEpisodeGroup)
          TextField("合集开始捕获名称", text: $regexStartGroup)
        }
        GridRow {
          TextField("合集结束捕获名称", text: $regexEndGroup)
          TextField("完结标记捕获名称", text: $regexFinalGroup)
        }
      }
      .font(.caption)
      HStack {
        Button {
          saveRegexRule()
        } label: {
          Label(editingRuleID == nil ? "保存高级规则" : "保存高级修改", systemImage: "curlybraces")
        }
        .disabled(regexPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button {
          manualRegexMode = false
        } label: {
          Label("回到自动生成", systemImage: "wand.and.stars")
        }
      }
    }
  }

  private var tokenizedTitleView: some View {
    VStack(alignment: .leading, spacing: 8) {
      if displayTokens.isEmpty {
        Text("粘贴标题后，这里会出现可点击片段。数字如 24 会作为一个整体，方便直接标记。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        EpisodeTokenFlowLayout(spacing: 6, rowSpacing: 6) {
          ForEach(displayTokens) { token in
            Button {
              applyMark(to: token)
            } label: {
              tokenLabel(token)
            }
            .buttonStyle(.plain)
            .help(helpText(for: token))
          }
        }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }

  private var displayTokens: [EpisodeTitleToken] {
    tokens.flatMap { token -> [EpisodeTitleToken] in
      guard splitTokenIDs.contains(token.id), token.text.count > 1 else {
        return [token]
      }
      let groupID = "split-\(token.id)"
      return token.text.enumerated().map { offset, character in
        let text = String(character)
        return EpisodeTitleToken(
          id: token.id * 10000 + offset + 1,
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

  private func tokenLabel(_ token: EpisodeTitleToken) -> some View {
    let mark = marks.first { $0.tokenId == token.id }
    let mode = mark.flatMap { EpisodeMarkMode(rawValue: $0.markType) }
    return HStack(spacing: 4) {
      Text(token.text)
        .font(token.kind == "number" || token.kind == "final" ? .body.monospaced().weight(.semibold) : .body)
      if let mode {
        Text(mode.shortTitle)
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(mode.color.opacity(0.16), in: Capsule())
      }
      if token.isSplit, mark == nil {
        Text("已拆分")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background((mode?.color ?? Color.secondary).opacity(mark == nil ? 0.08 : 0.18), in: Capsule())
    .overlay(
      Capsule()
        .stroke(
          (mode?.color ?? (token.isSplit ? Color.teal : Color.secondary)).opacity(mark == nil ? 0.28 : 0.55),
          style: StrokeStyle(lineWidth: 1, dash: token.isSplit && mark == nil ? [3, 3] : [])
        )
    )
  }

  private var testSection: some View {
    DisclosureGroup("测试更多标题", isExpanded: $showingMoreTests) {
      VStack(alignment: .leading, spacing: 10) {
        Text("用其它标题确认这条规则不会误判。保存前测试几条正例和反例会更稳。")
          .font(.caption)
          .foregroundStyle(.secondary)
        FormField(label: "测试标题") {
          TextField("", text: $testTitle, prompt: Text("粘贴一个资源标题用于测试"))
            .accessibilityLabel("测试标题")
        }
        HStack(alignment: .center, spacing: 10) {
          Picker("预期", selection: $testExpectedMatch) {
            Text("应该匹配").tag(true)
            Text("不应该匹配").tag(false)
          }
          .pickerStyle(.segmented)
          .frame(width: 220)
          Spacer()
          if testTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && testCases.isEmpty {
            Text("请输入测试标题")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Button {
            addRuleTestCase()
          } label: {
            Label("添加测试", systemImage: "plus.circle")
          }
          .disabled(testTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button {
            Task { await runRuleTest() }
          } label: {
            Label("测试识别", systemImage: "checkmark.seal")
          }
          .disabled(testCases.isEmpty && testTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !testCases.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(testCases.enumerated()), id: \.offset) { index, item in
              ruleTestCaseRow(item: item, index: index)
            }
          }
          .padding(8)
          .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        }
        if let testResponse {
          SharedEpisodeRuleTestResult(response: testResponse)
          if !testResponse.results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(testResponse.results) { result in
                HStack(alignment: .top, spacing: 8) {
                  Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.passed ? .green : .orange)
                    .frame(width: 18)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                      .font(.caption.weight(.medium))
                      .lineLimit(1)
                    Text(result.message)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
      }
      .padding(.top, 6)
    }
  }

  private func ruleTestCaseRow(item: EpisodeRuleTestCase, index: Int) -> some View {
    let result = testResponse?.results.first { $0.title == item.title && $0.expectedMatch == item.expectedMatch }
    return HStack(alignment: .top, spacing: 8) {
      Label(item.expectedMatch ? "应该匹配" : "不应该匹配", systemImage: item.expectedMatch ? "checkmark.circle" : "xmark.circle")
        .frame(width: 110, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .lineLimit(1)
        if let result {
          Text(result.matched ? "实际：已匹配 · \(result.message)" : "实际：未匹配 · \(result.message)")
            .foregroundStyle(result.passed ? .green : .orange)
            .lineLimit(2)
        } else {
          Text("实际：尚未测试")
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if let result {
        Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(result.passed ? .green : .orange)
      }
      Button(role: .destructive) {
        testCases.remove(at: index)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
    }
    .font(.caption)
  }

  private func aiAnalysisView(_ analysis: AITitleAnalysisResponse) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(analysis.message, systemImage: analysis.ok ? "sparkles" : "info.circle")
        .foregroundStyle(analysis.ok ? .blue : .secondary)

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        aiResultRow("字幕组", analysis.fansub)
        aiResultRow("番名", analysis.animeTitle)
        aiResultRow("集数", aiEpisodeText(analysis))
        aiResultRow("分辨率", analysis.resolution)
        aiResultRow("字幕/语言", subtitleLanguageText(analysis.subtitleLanguage))
        aiResultRow("来源/格式", aiTagsText(analysis))
        aiResultRow("合集", analysis.isBatch ? "是" : "否")
        aiResultRow("完结", finalText(analysis.isFinal))
        aiResultRow("置信度", "\(Int(analysis.confidence * 100))%")
      }
      .font(.caption)

      if let reason = analysis.reason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if analysis.ok {
        HStack {
          Button {
            applyAIAnalysis(analysis)
          } label: {
            Label("采用这个结果", systemImage: "checkmark.circle")
          }
          Button {
            copyAIAnalysis(analysis)
          } label: {
            Label("复制结果", systemImage: "doc.on.doc")
          }
        }
      }
      if let regex = analysis.suggestedRegex, !regex.isEmpty {
        CodeBlockView(text: regex, isReadOnly: true)
        Button {
          manualRegexMode = true
          regexPattern = regex
          regexName = ruleName.isEmpty ? "AI 建议规则草稿" : ruleName
          markNotice = "AI 建议已作为草稿填入，请测试后再保存。"
        } label: {
          Label("作为正则草稿", systemImage: "doc.badge.plus")
        }
      }
      ForEach(analysis.warnings, id: \.self) { warning in
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
  }

  private func aiResultRow(_ label: String, _ value: String?) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value?.isEmpty == false ? value! : "未识别")
    }
  }

  private func aiEpisodeText(_ analysis: AITitleAnalysisResponse) -> String? {
    if analysis.isBatch, let start = analysis.episodeStart, let end = analysis.episodeEnd {
      return "合集 \(start)–\(end)"
    }
    if let episode = analysis.episodeNumber {
      return "第 \(episode) 集"
    }
    return nil
  }

  private func subtitleLanguageText(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    if value.uppercased() == "CHT" {
      return "CHT / 繁体中文"
    }
    if value.uppercased() == "CHS" {
      return "CHS / 简体中文"
    }
    return value
  }

  private func aiTagsText(_ analysis: AITitleAnalysisResponse) -> String? {
    let tags = Array(Set(analysis.sourceTags + analysis.formatTags)).sorted()
    return tags.isEmpty ? nil : tags.joined(separator: "、")
  }

  private func finalText(_ value: Bool?) -> String {
    if value == true { return "是" }
    if value == false { return "否" }
    return "未知"
  }

  private var saveDisabledReason: String? {
    if manualRegexMode {
      return regexPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请填写正则表达式。" : nil
    }
    guard !sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "请先粘贴一个资源标题样例。"
    }
    guard let preview else {
      return "请标记标题中的集数片段。"
    }
    guard preview.ok, preview.rule != nil else {
      return preview.message
    }
    return nil
  }

  private var editingRule: EpisodeParseRule? {
    guard let editingRuleID else { return nil }
    return rules.first { $0.id == editingRuleID }
  }

  private var generatedPatternText: String {
    if let generated = preview?.rule?.generatedPattern, !generated.isEmpty {
      return generated
    }
    if let pattern = preview?.rule?.pattern, !pattern.isEmpty {
      return pattern
    }
    if let generated = editingRule?.generatedPattern, !generated.isEmpty {
      return generated
    }
    if let rule = editingRule, rule.mode == "visual", !rule.pattern.isEmpty {
      return rule.pattern
    }
    return regexPattern
  }

  private var generatedPatternUnavailableText: String {
    if sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "先粘贴一个资源标题样例，然后标记集数片段。"
    }
    if marks.isEmpty {
      return "还没有标记集数，无法生成正则。"
    }
    return preview?.message ?? "暂时无法生成正则，请检查标记是否完整。"
  }

  private func helpText(for token: EpisodeTitleToken) -> String {
    switch markMode {
    case .episode: "点击后标记为单集集数"
    case .start: "点击后标记为合集开始"
    case .end: "点击后标记为合集结束"
    case .final: "点击后标记为完结标记"
    case .split: token.isSplit ? "拆分片段。再次使用拆分模式点击可合并。" : "点击后拆分这个片段"
    case .clear: "点击后清除这个片段的标记"
    }
  }

  private func pushEditorSnapshot() {
    markHistory.append(EpisodeRuleEditorSnapshot(marks: marks, splitTokenIDs: splitTokenIDs))
  }

  private func scheduleTokenize() {
    tokenizeTask?.cancel()
    tokenizeTask = Task {
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run { tokenizeAndPreview() }
    }
  }

  private func tokenizeAndPreview() {
    let title = sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      tokens = []
      marks = []
      splitTokenIDs = []
      preview = nil
      return
    }
    Task {
      do {
        let response = try await store.client.tokenizeEpisodeRuleTitle(title)
        await MainActor.run {
          tokens = response.tokens
          splitTokenIDs = splitTokenIDs.filter { id in response.tokens.contains { $0.id == id } }
          marks = marks.filter { mark in displayTokens.contains { $0.id == mark.tokenId || ($0.startIndex == mark.startIndex && $0.endIndex == mark.endIndex) } }
        }
        await refreshPreview()
      } catch {
        await MainActor.run {
          preview = EpisodeRulePreviewResponse(ok: false, message: error.localizedDescription, rule: nil, parsedTitle: nil, tokens: tokens, suggestions: [])
        }
      }
    }
  }

  private func refreshPreview() async {
    let title = sampleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    do {
      let response = try await store.client.previewEpisodeRule(title: title, marks: marks, name: ruleName)
      await MainActor.run {
        preview = response
        if tokens.isEmpty {
          tokens = response.tokens
        }
        if !manualRegexMode {
          regexPattern = response.rule?.generatedPattern ?? response.rule?.pattern ?? ""
        }
      }
    } catch {
      await MainActor.run {
        preview = EpisodeRulePreviewResponse(ok: false, message: error.localizedDescription, rule: nil, parsedTitle: nil, tokens: tokens, suggestions: [])
      }
    }
  }

  private func applyMark(to token: EpisodeTitleToken) {
    pushEditorSnapshot()
    if markMode == .split {
      toggleSplit(for: token)
      Task { await refreshPreview() }
      return
    }
    let existing = marks.first { $0.tokenId == token.id }
    if markMode == .clear {
      marks.removeAll { $0.tokenId == token.id }
      markNotice = "已清除“\(token.text)”的标记。"
    } else if existing?.markType == markMode.rawValue {
      marks.removeAll { $0.tokenId == token.id }
      markNotice = "已清除“\(token.text)”的\(markMode.shortTitle)标记。"
    } else {
      if let existingMode = existing.flatMap({ EpisodeMarkMode(rawValue: $0.markType) }) {
        markNotice = "“\(token.text)”已从\(existingMode.shortTitle)改为\(markMode.shortTitle)。"
      } else {
        markNotice = "已把“\(token.text)”标记为\(markMode.shortTitle)。"
      }
      marks.removeAll { $0.tokenId == token.id || $0.markType == markMode.rawValue }
      marks.append(
        EpisodeRuleVisualMark(
          tokenId: token.id,
          tokenText: token.text,
          markType: markMode.rawValue,
          startIndex: token.startIndex,
          endIndex: token.endIndex,
          splitGroupId: token.splitGroupId
        )
      )
    }
    Task { await refreshPreview() }
  }

  private func toggleSplit(for token: EpisodeTitleToken) {
    if let groupID = token.splitGroupId, let originalID = Int(groupID.replacingOccurrences(of: "split-", with: "")) {
      let groupHasMarks = marks.contains { $0.splitGroupId == groupID }
      marks.removeAll { $0.splitGroupId == groupID }
      splitTokenIDs.remove(originalID)
      markNotice = groupHasMarks ? "已合并拆分片段，并清除了该组内的标记。" : "已合并拆分片段。"
      return
    }
    guard token.text.count > 1 else {
      markNotice = "这个片段已经足够细，不需要拆分。"
      return
    }
    splitTokenIDs.insert(token.id)
    markNotice = "已拆分“\(token.text)”。再次使用拆分模式点击片段可合并。"
  }

  private func undoMark() {
    guard let previous = markHistory.popLast() else { return }
    marks = previous.marks
    splitTokenIDs = previous.splitTokenIDs
    Task { await refreshPreview() }
  }

  private func resetMarks() {
    pushEditorSnapshot()
    marks = []
    preview = nil
    markNotice = "已重置所有标记。"
  }

  private func saveVisualRule() {
    guard var rule = preview?.rule else { return }
    let existingID = editingRuleID
    rule.id = existingID ?? UUID().uuidString
    rule.name = ruleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rule.name : ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
    if let existingID, let index = rules.firstIndex(where: { $0.id == existingID }) {
      rule.priority = index
      rules[index] = rule
    } else {
      rule.priority = rules.count
      rules.append(rule)
    }
    normalizePriorities()
    ruleName = ""
    sampleTitle = ""
    tokens = []
    marks = []
    markHistory = []
    splitTokenIDs = []
    preview = nil
    markNotice = nil
    editingRuleID = nil
    regexPattern = ""
    manualRegexMode = false
    showingRuleEditor = false
  }

  private func saveRegexRule() {
    let name = regexName.trimmingCharacters(in: .whitespacesAndNewlines)
    let existingID = editingRuleID
    let rule = EpisodeParseRule(
      id: existingID ?? UUID().uuidString,
      name: name.isEmpty ? "高级正则规则 \(rules.count + 1)" : name,
      pattern: regexPattern,
      enabled: true,
      priority: existingID.flatMap { id in rules.firstIndex { $0.id == id } } ?? rules.count,
      episodeGroup: regexEpisodeGroup,
      startGroup: regexStartGroup,
      endGroup: regexEndGroup,
      finalGroup: regexFinalGroup,
      ruleType: "user",
      mode: "regex",
      sampleTitle: nil,
      exampleTitle: nil,
      description: "高级正则规则",
      visualMarks: [],
      generatedPattern: nil
    )
    if let existingID, let index = rules.firstIndex(where: { $0.id == existingID }) {
      rules[index] = rule
    } else {
      rules.append(rule)
    }
    normalizePriorities()
    regexName = ""
    regexPattern = ""
    editingRuleID = nil
    manualRegexMode = false
    showingRuleEditor = false
  }

  private func startNewRule() {
    ruleName = ""
    sampleTitle = ""
    tokens = []
    marks = []
    markHistory = []
    splitTokenIDs = []
    preview = nil
    regexName = ""
    regexPattern = ""
    editingRuleID = nil
    markNotice = nil
    manualRegexMode = false
    testCases = []
    testResponse = nil
    showingRuleEditor = true
  }

  private func cancelRuleEditing() {
    startNewRule()
    showingRuleEditor = false
  }

  private func copyGeneratedPattern() {
    let pattern = generatedPatternText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pattern, forType: .string)
    regexCopiedMessage = "已复制正则表达式"
  }

  private func convertGeneratedPatternToManual() {
    let pattern = generatedPatternText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else {
      markNotice = "请先完成标记生成正则。"
      return
    }
    manualRegexMode = true
    regexPattern = pattern
    regexName = ruleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? editingRule?.name ?? "高级正则规则 \(rules.count + 1)" : ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
    if let editingRuleID, let index = rules.firstIndex(where: { $0.id == editingRuleID }) {
      var updated = rules[index]
      updated.mode = "regex"
      updated.pattern = pattern
      updated.generatedPattern = pattern
      updated.description = "由可视化规则转为手动正则"
      rules[index] = updated
      normalizePriorities()
    }
    markNotice = "已转为手动编辑。"
  }

  private func addRuleTestCase() {
    let title = testTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    testCases.append(EpisodeRuleTestCase(title: title, expectedMatch: testExpectedMatch))
    testTitle = ""
  }

  private func analyzeCurrentTitleWithAI(suggestedRule: Bool) async {
    let response = await store.analyzeTitleWithAI(sampleTitle, suggestedRule: suggestedRule)
    await MainActor.run {
      aiAnalysis = response
    }
  }

  private func applyAIAnalysis(_ analysis: AITitleAnalysisResponse) {
    let parsed = ParsedAnimeTitle(
      originalTitle: analysis.rawTitle ?? sampleTitle,
      title: analysis.animeTitle,
      episode: analysis.episodeNumber,
      episodeNumber: analysis.episodeNumber,
      episodeStart: analysis.episodeStart ?? analysis.episodeNumber,
      episodeEnd: analysis.episodeEnd,
      isBatch: analysis.isBatch,
      isFinal: analysis.isFinal,
      parseRuleName: "AI 分析",
      parseConfidence: analysis.confidence,
      parseFailureReason: nil,
      season: nil,
      fansub: analysis.fansub,
      resolution: analysis.resolution,
      subtitleLanguage: analysis.subtitleLanguage,
      version: nil,
      confidence: analysis.confidence,
      needsConfirmation: analysis.confidence < 0.8
    )
    testResponse = EpisodeRuleTestResponse(ok: true, parsedTitle: parsed, message: "已采用 AI 结构化结果。")
    markNotice = "已采用 AI 结果，当前预览已更新。"
  }

  private func copyAIAnalysis(_ analysis: AITitleAnalysisResponse) {
    let lines = [
      "字幕组：\(analysis.fansub ?? "未识别")",
      "番名：\(analysis.animeTitle ?? "未识别")",
      "集数：\(aiEpisodeText(analysis) ?? "未识别")",
      "分辨率：\(analysis.resolution ?? "未识别")",
      "字幕/语言：\(subtitleLanguageText(analysis.subtitleLanguage) ?? "未识别")",
      "来源/格式：\(aiTagsText(analysis) ?? "未识别")",
      "合集：\(analysis.isBatch ? "是" : "否")",
      "完结：\(finalText(analysis.isFinal))",
    ]
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    markNotice = "已复制 AI 解析结果。"
  }

  private func runRuleTest() async {
    do {
      let tests = testCases.isEmpty ? [EpisodeRuleTestCase(title: testTitle, expectedMatch: true)] : testCases
      let testRules = currentDraftRuleForTesting().map { [$0] } ?? rules
      let response = try await store.client.testGlobalEpisodeRules(tests: tests, episodeParseRules: testRules)
      testResponse = response
    } catch {
      let parsed = ParsedAnimeTitle(originalTitle: testTitle, title: nil, episode: nil, episodeNumber: nil, episodeStart: nil, episodeEnd: nil, isBatch: nil, isFinal: nil, parseRuleName: nil, parseConfidence: nil, parseFailureReason: error.localizedDescription, season: nil, fansub: nil, resolution: nil, subtitleLanguage: nil, version: nil, confidence: 0, needsConfirmation: true)
      testResponse = EpisodeRuleTestResponse(ok: false, parsedTitle: parsed, message: error.localizedDescription)
    }
  }

  private func currentDraftRuleForTesting() -> EpisodeParseRule? {
    if manualRegexMode {
      let pattern = regexPattern.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !pattern.isEmpty else { return nil }
      let name = regexName.trimmingCharacters(in: .whitespacesAndNewlines)
      return EpisodeParseRule(
        id: editingRuleID ?? "draft",
        name: name.isEmpty ? "正在编辑的高级规则" : name,
        pattern: pattern,
        enabled: true,
        priority: 0,
        episodeGroup: regexEpisodeGroup,
        startGroup: regexStartGroup,
        endGroup: regexEndGroup,
        finalGroup: regexFinalGroup,
        ruleType: "user",
        mode: "regex",
        sampleTitle: sampleTitle,
        exampleTitle: sampleTitle,
        description: "测试中的高级规则",
        visualMarks: [],
        generatedPattern: nil
      )
    }
    return preview?.rule
  }

  private func moveRule(_ index: Int, _ direction: Int) {
    let target = index + direction
    guard rules.indices.contains(index), rules.indices.contains(target) else { return }
    rules.swapAt(index, target)
    normalizePriorities()
  }

  private func normalizePriorities() {
    rules = rules.enumerated().map { index, rule in
      var updated = rule
      updated.priority = index
      return updated
    }
  }

  private func editRule(_ rule: EpisodeParseRule) {
    editingRuleID = rule.id
    showingRuleEditor = true
    if rule.mode == "visual" {
      manualRegexMode = false
      ruleName = rule.name
      sampleTitle = rule.sampleTitle ?? rule.exampleTitle ?? ""
      regexPattern = rule.generatedPattern ?? rule.pattern
      marks = rule.visualMarks
      splitTokenIDs = Set(rule.visualMarks.compactMap { mark in
        mark.splitGroupId.flatMap { Int($0.replacingOccurrences(of: "split-", with: "")) }
      })
      markHistory = []
      markNotice = "正在编辑“\(rule.name)”。点击已标记片段可清除。"
      tokenizeAndPreview()
    } else {
      manualRegexMode = true
      sampleTitle = ""
      tokens = []
      marks = []
      splitTokenIDs = []
      preview = nil
      regexName = rule.name
      regexPattern = rule.pattern
      regexEpisodeGroup = rule.episodeGroup
      regexStartGroup = rule.startGroup
      regexEndGroup = rule.endGroup
      regexFinalGroup = rule.finalGroup
      markNotice = "正在编辑高级规则“\(rule.name)”。"
    }
  }
}

private struct EpisodeTokenFlowLayout: Layout {
  var spacing: CGFloat = 8
  var rowSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? 600
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maxWidth {
        x = 0
        y += rowHeight + rowSpacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: maxWidth, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + rowSpacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

private struct SharedEpisodeRuleTestResult: View {
  var response: EpisodeRuleTestResponse

  var body: some View {
    let parsed = response.parsedTitle
    VStack(alignment: .leading, spacing: 5) {
      Label(response.message, systemImage: parsed.episode == nil ? "exclamationmark.triangle" : "checkmark.circle")
        .foregroundStyle(parsed.episode == nil ? .orange : .green)
      HStack(spacing: 10) {
        if let ruleName = parsed.parseRuleName {
          Text("命中 \(ruleName)")
        }
        if parsed.isBatch == true {
          Text("合集")
          if let start = parsed.episodeStart, let end = parsed.episodeEnd {
            Text("第 \(start)-\(end) 集")
          }
        } else if let episode = parsed.episode {
          Text("第 \(episode) 集")
        }
        if parsed.isFinal == true {
          Text("完结")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let reason = parsed.parseFailureReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}
