import OSLog
import SwiftUI

private let subscriptionSearchLogger = Logger(
  subsystem: "com.kisetsu.app",
  category: "SubscriptionSearch"
)

struct SubscriptionSearchFocusKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var focusSubscriptionSearch: (() -> Void)? {
    get { self[SubscriptionSearchFocusKey.self] }
    set { self[SubscriptionSearchFocusKey.self] = newValue }
  }
}

struct SubscriptionsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingEditor = false
  @State private var showingDetail = false
  @State private var showingRefreshLog = false
  @State private var subscriptionSearch = SubscriptionSearchPresentationState()
  @State private var subscriptionSearchFocusID: Int?

  private var filteredSubscriptions: [Subscription] {
    let scopedSubscriptions = store.subscriptionListFilter.apply(to: store.subscriptions)
    return SubscriptionSearch.filter(scopedSubscriptions, query: subscriptionSearch.query)
  }

  var body: some View {
    VStack(spacing: 0) {
      SubscriptionToolbar(
        search: subscriptionSearch,
        searchResultCount: filteredSubscriptions.count,
        totalSubscriptionCount: store.subscriptions.count,
        toggleSearch: {
          toggleSubscriptionSearch()
        },
        newSubscription: {
          store.prepareNewSubscription()
          showingEditor = true
        },
        showRefreshLog: {
          showingRefreshLog = true
        }
      )

      SubscriptionList(
        subscriptions: filteredSubscriptions,
        searchText: subscriptionSearch.query,
        filter: store.subscriptionListFilter,
        showAll: {
          store.subscriptionListFilter = .all
        },
        edit: { subscription in
          store.editSubscription(subscription)
          showingEditor = true
        },
        detail: { subscription in
          Task {
            await store.loadMatches(for: subscription)
            showingDetail = true
          }
        }
      )
    }
    .overlayPreferenceValue(CompactListSearchAnchorKey.self) { anchor in
      if let anchor,
         let presentationID = subscriptionSearch.presentationID {
        GeometryReader { proxy in
          let anchorRect = proxy[anchor]
          let panelLeading = max(
            12,
            min(anchorRect.maxX - 300, proxy.size.width - 312)
          )

          ZStack(alignment: .topLeading) {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture {
                requestSubscriptionSearchDismissal(source: "outside")
              }
              .accessibilityHidden(true)

            CompactListSearchOverlay(
              query: $subscriptionSearch.query,
              presentationID: presentationID,
              focusID: subscriptionSearchFocusID,
              resultCount: filteredSubscriptions.count,
              prompt: "搜索订阅",
              itemName: "订阅",
              attachedToWindow: { id, windowIsVisible in
                subscriptionSearchAttached(
                  presentationID: id,
                  windowIsVisible: windowIsVisible
                )
              },
              escape: {
                handleSubscriptionSearchEscape()
              }
            )
            .padding(.leading, panelLeading)
            .padding(.top, anchorRect.maxY + 6)
          }
        }
        .zIndex(100)
      }
    }
    .focusedSceneValue(\.focusSubscriptionSearch) {
      requestSubscriptionSearchPresentation(source: "command-f")
    }
    .onKeyPress(phases: .down) { keyPress in
      if keyPress.key == .escape,
         handleSubscriptionSearchEscape() {
        return .handled
      }
      return .ignored
    }
    .sheet(isPresented: $showingEditor) {
      SubscriptionEditorSheet {
        showingEditor = false
      }
    }
    .onChange(of: showingEditor) { _, isShowing in
      guard !isShowing else { return }
      Task { await store.runPendingMetadataRecognitionIfNeeded() }
    }
    .sheet(isPresented: $showingDetail) {
      SubscriptionDetailSheet {
        showingDetail = false
      }
    }
    .sheet(isPresented: $showingRefreshLog) {
      RefreshLogSheet()
    }
    .onAppear {
      Task { await store.loadSchedulerStatus(silent: true) }
    }
    .onDisappear {
      guard subscriptionSearch.phase != .closed else { return }
      subscriptionSearchLogger.debug(
        "event=force_close source=page_disappear request=\(subscriptionSearch.requestID)"
      )
      subscriptionSearchFocusID = nil
      subscriptionSearch.forceDismiss()
    }
    .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
      Task {
        await store.loadSchedulerStatus(silent: true)
        if store.schedulerStatus?.running == true {
          await store.loadSubscriptions(silent: true)
        }
      }
    }
  }

  private func requestSubscriptionSearchPresentation(source: String) {
    guard let id = subscriptionSearch.requestPresentation() else {
      subscriptionSearchLogger.debug(
        "event=open_merged source=\(source, privacy: .public) request=\(subscriptionSearch.requestID)"
      )
      return
    }
    subscriptionSearchLogger.debug(
      "event=opening source=\(source, privacy: .public) request=\(id)"
    )
  }

  private func toggleSubscriptionSearch() {
    if subscriptionSearch.isPresented {
      requestSubscriptionSearchDismissal(source: "button")
    } else {
      requestSubscriptionSearchPresentation(source: "button")
    }
  }

  private func requestSubscriptionSearchDismissal(source: String) {
    guard let id = subscriptionSearch.requestDismissal() else { return }
    subscriptionSearchFocusID = nil
    subscriptionSearchLogger.debug(
      "event=closing source=\(source, privacy: .public) request=\(id)"
    )
    completeSubscriptionSearchDismissal(id)
  }

  private func completeSubscriptionSearchDismissal(_ id: Int) {
    Task { @MainActor in
      await Task.yield()
      guard subscriptionSearch.completeDismissal(id) else { return }
      subscriptionSearchLogger.debug("event=closed request=\(id)")
    }
  }

  private func subscriptionSearchAttached(
    presentationID: Int,
    windowIsVisible: Bool
  ) {
    guard windowIsVisible,
          subscriptionSearch.confirmPresentation(presentationID)
    else {
      subscriptionSearchLogger.debug(
        "event=attachment_ignored request=\(presentationID) window_visible=\(windowIsVisible)"
      )
      return
    }
    subscriptionSearchFocusID = presentationID
    subscriptionSearchLogger.debug(
      "event=opened request=\(presentationID) anchor_in_window=true window_visible=true"
    )
  }

  private func handleSubscriptionSearchEscape() -> Bool {
    let action = subscriptionSearch.handleEscape()
    switch action {
    case .clearedQuery:
      subscriptionSearchLogger.debug(
        "event=query_cleared source=escape request=\(subscriptionSearch.requestID)"
      )
      return true
    case .dismissedPopover:
      subscriptionSearchFocusID = nil
      if let id = subscriptionSearch.closingRequestID {
        subscriptionSearchLogger.debug(
          "event=closing source=escape request=\(id)"
        )
        completeSubscriptionSearchDismissal(id)
      }
      return true
    case .ignored:
      return false
    }
  }
}

private struct SubscriptionToolbar: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingTools = false
  var search: SubscriptionSearchPresentationState
  var searchResultCount: Int
  var totalSubscriptionCount: Int
  var toggleSearch: () -> Void
  var newSubscription: () -> Void
  var showRefreshLog: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      toolbarControls
      Spacer(minLength: 12)
      searchButton
    }
    .appToolbarSurface()
  }

  @ViewBuilder
  private var toolbarControls: some View {
    Group {
      Button {
        newSubscription()
      } label: {
        Label("新建订阅", systemImage: "plus.circle")
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.isLoading)

      Button {
        Task { await store.loadSubscriptions() }
      } label: {
        Label("重新加载", systemImage: "arrow.clockwise")
      }
      .disabled(store.isLoading)

      Button {
        Task { await store.refreshAllSubscriptions() }
      } label: {
        Label("刷新全部", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(store.isLoading || store.refreshQueueRunning)

      Button {
        showRefreshLog()
      } label: {
        Label("刷新日志", systemImage: "list.bullet.rectangle")
      }
      .disabled(store.lastRefreshResponse == nil && store.lastRefreshAllResponse == nil)

      Divider()
        .frame(height: 20)

      Button {
        showingTools.toggle()
      } label: {
        Image(
          systemName: store.subscriptionListFilter == .completed
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        )
      }
      .help("订阅工具")
      .accessibilityLabel("订阅工具")
      .popover(isPresented: $showingTools, arrowEdge: .bottom) {
        SubscriptionToolsPopover()
          .environmentObject(store)
      }
    }
  }

  private var searchButton: some View {
    CompactListSearchButton(
      search: search,
      label: "搜索订阅",
      resultCount: searchResultCount,
      totalCount: totalSubscriptionCount,
      itemName: "订阅",
      toggle: toggleSearch
    )
  }
}

private struct SubscriptionToolsPopover: View {
  @EnvironmentObject private var store: AppStore
  @State private var isReadingSchedulerStatus = false
  @State private var schedulerStatusReadFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("显示")
        .font(.caption)
        .foregroundStyle(.secondary)

      Button {
        store.subscriptionListFilter = store.subscriptionListFilter == .completed ? .all : .completed
      } label: {
        HStack(spacing: 8) {
          Image(
            systemName: store.subscriptionListFilter == .completed
              ? "checkmark.circle.fill"
              : "circle"
          )
          .foregroundStyle(store.subscriptionListFilter == .completed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          Text("订阅完成")
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(minHeight: 28)
      .accessibilityValue(store.subscriptionListFilter == .completed ? "已开启" : "已关闭")

      Divider()

      Text("自动刷新")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let status = store.schedulerStatus {
        HStack {
          Label(
            status.running ? "运行中" : "已停止",
            systemImage: status.running ? "clock.badge.checkmark" : "clock"
          )
          .foregroundStyle(status.running ? .green : .secondary)
          Spacer()
          if store.isLoading {
            ProgressView()
              .controlSize(.small)
          }
        }

        Stepper(value: $store.schedulerIntervalSeconds, in: 60...86400, step: 60) {
          LabeledContent("刷新间隔", value: intervalText)
        }

        if status.running {
          Button("停止自动刷新", systemImage: "stop.fill") {
            Task { await store.stopScheduler() }
          }
          .disabled(store.isLoading)
        } else {
          Button("开启自动刷新", systemImage: "play.fill") {
            Task { await store.startScheduler() }
          }
          .disabled(store.isLoading)
        }

        if let scheduleText {
          Text(scheduleText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if isReadingSchedulerStatus {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在读取自动刷新状态")
            .foregroundStyle(.secondary)
        }
      } else {
        HStack(spacing: 8) {
          Label(
            schedulerStatusReadFailed ? "无法读取自动刷新状态" : "尚未读取自动刷新状态",
            systemImage: schedulerStatusReadFailed ? "exclamationmark.triangle" : "clock"
          )
          .foregroundStyle(schedulerStatusReadFailed ? .orange : .secondary)
          Spacer()
          Button("重新读取", systemImage: "arrow.clockwise") {
            Task { await readSchedulerStatus() }
          }
          .labelStyle(.iconOnly)
          .disabled(isReadingSchedulerStatus || store.isLoading)
        }
      }
    }
    .padding(16)
    .frame(width: 320)
    .task {
      guard store.schedulerStatus == nil else { return }
      await readSchedulerStatus()
    }
  }

  @MainActor
  private func readSchedulerStatus() async {
    guard !isReadingSchedulerStatus else { return }
    isReadingSchedulerStatus = true
    schedulerStatusReadFailed = false
    await store.loadSchedulerStatus(silent: true)
    schedulerStatusReadFailed = store.schedulerStatus == nil
    isReadingSchedulerStatus = false
  }

  private var intervalText: String {
    let seconds = store.schedulerIntervalSeconds
    return seconds.isMultiple(of: 60) ? "\(seconds / 60) 分钟" : "\(seconds) 秒"
  }

  private var scheduleText: String? {
    guard let status = store.schedulerStatus else { return nil }
    let values = [
      timeText(status.nextRunAt).map { "下次 \($0)" },
      timeText(status.lastRunAt).map { "上次 \($0)" },
    ].compactMap { $0 }
    return values.isEmpty ? nil : values.joined(separator: " · ")
  }

  private func timeText(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    guard let date else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

private struct SubscriptionForm: View {
  @EnvironmentObject private var store: AppStore
  @State private var showEpisodeRules = false
  @State private var showEpisodeRecognition = false
  @State private var showAdvancedMatching = false
  @State private var showMatchRuleHelp = false
  @State private var showAISmartPrefillSummary = true
  var saved: () -> Void = {}
  var cancelled: () -> Void = {}

  private var enabledTargets: [OrganizeTarget] {
    store.organizeTargets.filter(\.enabled)
  }

  private var canSave: Bool {
    !store.isLoading && disabledReason == nil
  }

  private var disabledReason: String? {
    if store.subscriptionSourceType == "rss" {
      if store.subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
          store.subscriptionKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请输入订阅名称"
      }
      if store.subscriptionRSSURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请输入 RSS 地址"
      }
    } else if store.subscriptionKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "请输入订阅关键词"
    }
    if store.subscriptionSourceType == "mikan_bangumi" &&
        store.subscriptionSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "请输入 Mikan Bangumi 地址"
    }
    if store.selectedSiteIDs.isEmpty {
      return "请选择至少一个站点"
    }
    if let message = store.subscriptionIncludeKeywordValidationMessage {
      return message
    }
    if let message = store.subscriptionExcludeKeywordValidationMessage {
      return message
    }
    if let message = store.subscriptionSizeValidationMessage {
      return message
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.subscriptionEditorTitle)
        .font(.title3.bold())

      if let prefill = store.lastSmartPrefill {
        SmartPrefillSummaryView(prefill: prefill, isExpanded: $showAISmartPrefillSummary)
      }

      GroupBox("基本信息") {
        VStack(alignment: .leading, spacing: 10) {
          LabeledTextField(label: "订阅名称", placeholder: "例如：葬送的芙莉莲", text: $store.subscriptionName)
          FormField(label: "订阅来源", help: "关键词会在所选站点搜索；Mikan 番组只读取 Mikan Bangumi；RSS 只读取 RSS 地址。") {
            Picker("订阅来源", selection: $store.subscriptionSourceType) {
              Text("关键词搜索").tag("keyword")
              Text("Mikan 番组").tag("mikan_bangumi")
              Text("RSS").tag("rss")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
          if store.subscriptionSourceType == "keyword" {
            LabeledTextField(label: "关键词", placeholder: "例如：葬送的芙莉莲", text: $store.subscriptionKeyword, help: "会在下方勾选的站点中搜索。")
          } else if store.subscriptionSourceType == "mikan_bangumi" {
            LabeledTextField(label: "关键词", placeholder: "例如：葬送的芙莉莲", text: $store.subscriptionKeyword, help: "用于显示、匹配和整理命名。")
            LabeledTextField(label: "Mikan 番组地址", placeholder: "例如：https://mikanani.me/Home/Bangumi/3891", text: $store.subscriptionSourceURL, help: "刷新时只读取这个 Mikan 番组页面。")
          } else {
            LabeledTextField(label: "关键词", placeholder: "例如：葬送的芙莉莲", text: $store.subscriptionKeyword, help: "用于显示、匹配和整理命名；RSS 抓取只使用下方 RSS 地址。")
          }
          LabeledTextField(label: "别名", placeholder: "多个用逗号分隔", text: $store.subscriptionAliases, help: "任一别名命中即可匹配，例如：最强的职业不是勇者也不是贤者好像是鉴定士 的样子？, Kanteishi")
          LabeledTextField(label: "总集数（可选）", placeholder: "例如：12", text: $store.subscriptionTotalEpisodes)
        }
      }

      GroupBox("资源筛选") {
        VStack(alignment: .leading, spacing: 10) {
          FormField(label: "字幕组", help: "优先匹配标题开头的字幕组标记；空着表示不限字幕组。") {
            HStack(spacing: 8) {
              TextField("例如：六四位元字幕组", text: $store.subscriptionFansub)
              if !store.smartSubscriptionFansubOptions.isEmpty {
                Menu {
                  Button("不限字幕组") {
                    store.subscriptionFansub = ""
                  }
                  Divider()
                  ForEach(store.smartSubscriptionFansubOptions, id: \.self) { fansub in
                    Button {
                      store.subscriptionFansub = fansub
                    } label: {
                      if store.subscriptionFansub == fansub {
                        Label(fansub, systemImage: "checkmark")
                      } else {
                        Text(fansub)
                      }
                    }
                  }
                } label: {
                  Image(systemName: "chevron.up.chevron.down")
                    .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("选择本次搜索发现的字幕组")
                .accessibilityLabel("选择字幕组")
              }
            }
          }
          FormField(label: "分辨率") {
            Picker("分辨率", selection: $store.subscriptionResolution) {
              Text("不限").tag("")
              Text("720p").tag("720p")
              Text("1080p").tag("1080p")
              Text("2160p").tag("2160p")
              Text("自定义").tag("custom")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
          if store.subscriptionResolution == "custom" {
            LabeledTextField(label: "自定义分辨率关键词", placeholder: "例如：1440p、HEVC、AV1、BDRip、WebDL", text: $store.subscriptionResolutionCustom, help: "多个关键词可用逗号分隔；留空会按“不限”保存。")
          }
          FormField(
            label: "视频体积",
            help: "不设置则不过滤。体积未知的资源无法通过已启用的体积过滤。",
            error: store.subscriptionSizeValidationMessage
          ) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 10) {
                SubscriptionSizeBoundField(
                  label: "最小体积",
                  text: $store.subscriptionMinSize,
                  unit: store.subscriptionMinSizeUnit,
                  setUnit: store.setSubscriptionMinSizeUnit
                )
                SubscriptionSizeBoundField(
                  label: "最大体积",
                  text: $store.subscriptionMaxSize,
                  unit: store.subscriptionMaxSizeUnit,
                  setUnit: store.setSubscriptionMaxSizeUnit
                )
              }
              VStack(spacing: 8) {
                SubscriptionSizeBoundField(
                  label: "最小体积",
                  text: $store.subscriptionMinSize,
                  unit: store.subscriptionMinSizeUnit,
                  setUnit: store.setSubscriptionMinSizeUnit
                )
                SubscriptionSizeBoundField(
                  label: "最大体积",
                  text: $store.subscriptionMaxSize,
                  unit: store.subscriptionMaxSizeUnit,
                  setUnit: store.setSubscriptionMaxSizeUnit
                )
              }
            }
          }
          LabeledTextField(
            label: "包含词",
            placeholder: "例如：(简体, 1080p), WEB-DL",
            text: $store.subscriptionIncludeKeywords,
            help: "逗号分隔表示任意匹配；括号内表示全部匹配。",
            error: store.subscriptionIncludeKeywordValidationMessage
          )
          LabeledTextField(
            label: "排除词",
            placeholder: "例如：(先行, 1080p), CAM",
            text: $store.subscriptionExcludeKeywords,
            help: "任一条件成立即排除；括号内关键词必须全部命中才触发排除。",
            error: store.subscriptionExcludeKeywordValidationMessage
          )
          FormField(label: "过滤顺序") {
            Picker("过滤顺序", selection: $store.subscriptionFilterOrder) {
              Text("先包含后排除").tag("include_first")
              Text("先排除后包含").tag("exclude_first")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
        }
      }

      DisclosureGroup("集数规则", isExpanded: $showEpisodeRules) {
        VStack(alignment: .leading, spacing: 10) {
          LabeledTextField(label: "Season 编号", placeholder: "例如：1", text: $store.subscriptionSeason, help: "代表这个订阅要追的季度；无明确季度的资源会按它处理，明确跨季资源会提示确认。")
          LabeledTextField(label: "指定集数", placeholder: "例如：1-6, 8, 10-12", text: $store.subscriptionEpisodeFilter, help: "为空表示订阅全部集数。指定集数会按集数偏移后的显示集数判断。")
          LabeledTextField(label: "起始集数", placeholder: "1", text: $store.subscriptionEpisodeStart, help: "通常从第 1 集开始。只有资源标题和实际集数不一致时才需要修改。")
          LabeledTextField(label: "集数偏移", placeholder: "例如：-12", text: $store.subscriptionEpisodeOffset, help: "当资源标题集数和显示/整理集数不一致时使用。例如资源第 13 集希望显示为 S02E01，则填写 -12。")
        }
      }

      DisclosureGroup("集数识别", isExpanded: $showEpisodeRecognition) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("规则来源", selection: Binding {
            store.subscriptionUseCustomEpisodeRules ? "subscription" : "global"
          } set: { value in
            store.subscriptionUseCustomEpisodeRules = value == "subscription"
          }) {
            Text("使用全局规则").tag("global")
            Text("为这个订阅添加专属规则").tag("subscription")
          }
          .pickerStyle(.segmented)

          Text("大多数订阅使用全局规则即可。如果这个订阅的资源标题无法正确识别集数，可以添加专属规则。专属规则会先于全局规则尝试。")
            .font(.caption)
            .foregroundStyle(.secondary)

          if store.subscriptionUseCustomEpisodeRules {
            EpisodeRuleManagerView(
              rules: $store.subscriptionEpisodeParseRules,
              builtinRules: store.builtinEpisodeParseRules,
              scopeTitle: "订阅专属规则",
              emptyTitle: "还没有专属规则",
              emptyDescription: "这个订阅会先使用全局规则。只有特殊标题格式识别失败时，才需要添加专属规则。",
              showBuiltinRules: false,
              compactMode: true
            )
          } else {
            Text("当前使用设置页里的全局规则。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      DisclosureGroup("高级匹配", isExpanded: $showAdvancedMatching) {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("启用正则表达式", isOn: $store.subscriptionRegexEnabled)
          LabeledTextField(
            label: "正则表达式",
            placeholder: "例如：\\[Baha\\].*1080P",
            text: $store.subscriptionRegex,
            help: "对资源主标题与副标题进行匹配；留空或关闭时不参与匹配。",
            disabled: !store.subscriptionRegexEnabled
          )
        }
      }

      DisclosureGroup("匹配规则说明", isExpanded: $showMatchRuleHelp) {
        VStack(alignment: .leading, spacing: 5) {
          Text("1. 从站点或 Mikan Bangumi URL 获取候选资源")
          Text("2. 用主标题、副标题中的番名与别名，或明确的 Mikan 来源判断是否属于该番")
          Text("3. 应用字幕组过滤")
          Text("4. 应用包含词过滤")
          Text("5. 应用排除词过滤")
          Text("6. 应用分辨率过滤")
          Text("7. 应用可选的视频体积过滤")
          Text("8. 启用正则后，对资源主标题与副标题应用正则")
          Text("9. 解析集数并应用指定集数和集数偏移")
          Text("10. 自动下载时，同集普通资源选择体积最大的一个")
          Text("11. 去重并写入剧集状态")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if store.subscriptionSourceType == "rss" {
        Text("RSS 地址")
          .font(.caption)
          .foregroundStyle(.secondary)
        SecretValueField(label: "RSS 地址", prompt: "每行一个 RSS 地址", text: $store.subscriptionRSSURLs)
        Button {
          Task { await store.testRSSForm() }
        } label: {
          Label("测试 RSS", systemImage: "antenna.radiowaves.left.and.right")
        }
        .disabled(store.subscriptionRSSURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.selectedSiteIDs.isEmpty)
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(store.subscriptionSiteOptions) { site in
          HStack(spacing: 8) {
            Toggle(site.label, isOn: Binding {
              store.selectedSiteIDs.contains(site.id)
            } set: { isOn in
              if isOn {
                store.selectedSiteIDs.insert(site.id)
              } else {
                store.selectedSiteIDs.remove(site.id)
              }
            })
            .toggleStyle(.checkbox)

            if let hint = store.legacySiteHint(for: site) {
              Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Toggle("启用订阅", isOn: $store.subscriptionEnabled)
      Toggle("自动下载", isOn: $store.subscriptionAutoDownload)
      Toggle("下载完成后自动整理", isOn: $store.subscriptionAutoOrganize)
      Picker("整理后任务处理", selection: $store.subscriptionPostOrganizeAction) {
        Text("使用全局默认").tag("default")
        Text("继续做种").tag("keep_seeding")
        Text("移除任务").tag("remove_task_keep_files")
        Text("移除任务和原文件").tag("remove_task_delete_files")
        Text("手动处理").tag("manual")
      }
      Text(store.subscriptionPostOrganizeAction == "default" ? "使用设置页里的默认整理策略" : store.organizePolicyDescription(store.subscriptionPostOrganizeAction))
        .font(.caption)
        .foregroundStyle(.secondary)
      if store.subscriptionPostOrganizeAction == "keep_seeding" {
        Picker("做种规则", selection: $store.subscriptionSeedingPolicyMode) {
          Text("使用全局设置").tag("inherit")
          Text("当前订阅自定义").tag("custom")
        }
        .pickerStyle(.segmented)

        if store.subscriptionSeedingPolicyMode == "inherit" {
          Text(store.subscriptionGlobalSeedingSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Toggle("目标做种时间", isOn: $store.subscriptionSeedingTimeEnabled)
          if store.subscriptionSeedingTimeEnabled {
            HStack {
              TextField("小时", text: $store.subscriptionSeedingHours, prompt: Text("输入时长"))
                .frame(maxWidth: 180)
              Text("小时")
                .foregroundStyle(.secondary)
            }
          }
          Toggle("目标分享率", isOn: $store.subscriptionSeedingRatioEnabled)
          if store.subscriptionSeedingRatioEnabled {
            HStack {
              TextField("分享率", text: $store.subscriptionSeedingRatioPercent, prompt: Text("输入百分比"))
                .frame(maxWidth: 180)
              Text("%")
                .foregroundStyle(.secondary)
            }
          }
          if store.subscriptionSeedingTimeEnabled && store.subscriptionSeedingRatioEnabled {
            Picker("达标方式", selection: $store.subscriptionSeedingStopMode) {
              Text("任一目标达成").tag("any")
              Text("全部目标达成").tag("all")
            }
            .pickerStyle(.segmented)
          }
          Picker("达标后处理", selection: $store.subscriptionPostSeedingAction) {
            Text("暂停任务").tag("pause")
            Text("移除任务，保留文件").tag("remove_task_keep_files")
            Text("移除任务和下载数据").tag("remove_task_delete_files")
            Text("等待手动处理").tag("manual")
          }
          Text(store.subscriptionSeedingValidationMessage ?? store.subscriptionCustomSeedingSummary)
            .font(.caption)
            .foregroundStyle(store.subscriptionSeedingValidationMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
      }
      Picker("整理目标", selection: $store.subscriptionOrganizeTargetID) {
        Text("使用默认目标").tag(Optional<Int>.none)
        ForEach(enabledTargets) { target in
          Text(target.isDefault ? "\(target.name)（默认）" : target.name)
            .tag(Optional<Int>.some(target.id))
        }
      }
      if enabledTargets.isEmpty {
        Label("还没有可用整理目标，仍可先创建订阅；需要自动整理时再到设置中添加。", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("下载设置")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("保存路径", text: $store.subscriptionSavePath)
      TextField("分类", text: $store.subscriptionCategory)
      TextField("标签，多个用逗号分隔", text: $store.subscriptionTags)

      HStack {
        Button {
          Task { await store.testSubscriptionForm() }
        } label: {
          Label("测试匹配", systemImage: "checkmark.seal")
        }
        .disabled(!canSave)

        Button {
          Task {
            if await store.saveSubscriptionForm() {
              saved()
            }
          }
        } label: {
          Label(
            store.subscriptionPrimaryActionTitle,
            systemImage: store.editingSubscriptionID == nil ? "plus.circle" : "square.and.arrow.down"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
        .help(disabledReason ?? store.subscriptionPrimaryActionTitle)

        if store.editingSubscriptionID != nil {
          Button {
            cancelled()
          } label: {
            Label("取消编辑", systemImage: "xmark.circle")
          }
        } else {
          Button {
            cancelled()
          } label: {
            Label("取消", systemImage: "xmark.circle")
          }
        }
      }
      if let disabledReason {
        Text(disabledReason)
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let response = store.lastSubscriptionTestMatchResponse {
        SubscriptionTestMatchSummary(response: response)
      }
    }
    .textFieldStyle(.roundedBorder)
  }
}

@MainActor
private struct SubscriptionSizeBoundField: View {
  var label: String
  @Binding var text: String
  var unit: SubscriptionSizeUnit
  var setUnit: (SubscriptionSizeUnit) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 52, alignment: .leading)
      TextField("不限", text: $text)
        .accessibilityLabel(label)
        .frame(minWidth: 92, maxWidth: .infinity)
      Picker("\(label)单位", selection: Binding(get: { unit }, set: { setUnit($0) })) {
        ForEach(SubscriptionSizeUnit.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 72)
      .help("\(label)单位")
      .accessibilityLabel("\(label)单位")
    }
  }
}

private struct EpisodeParseRuleRow: View {
  @Binding var rule: EpisodeParseRule
  var moveUp: () -> Void
  var moveDown: () -> Void
  var remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Toggle("", isOn: $rule.enabled)
          .labelsHidden()
        FormField(label: "规则名称") {
          TextField("", text: $rule.name, prompt: Text("例如：星号单集规则"))
            .accessibilityLabel("规则名称")
        }
        Spacer()
        Button {
          moveUp()
        } label: {
          Image(systemName: "arrow.up")
        }
        .help("上移")
        Button {
          moveDown()
        } label: {
          Image(systemName: "arrow.down")
        }
        .help("下移")
        Button(role: .destructive) {
          remove()
        } label: {
          Image(systemName: "trash")
        }
        .help("删除规则")
      }
      FormField(label: "正则表达式") {
        TextField("", text: $rule.pattern, prompt: Text("例如：★(?<episode>\\d{1,3})★"))
          .font(.system(.body, design: .monospaced))
          .accessibilityLabel("正则表达式")
      }
      DisclosureGroup("高级捕获组") {
        VStack(alignment: .leading, spacing: 8) {
          Text("通常不用改。正则里用 `(?<episode>...)` 捕获单集；合集可用 `(?<start>...)` 和 `(?<end>...)`；完结标记可用 `(?<final>...)`。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
              TextField("单集：episode", text: $rule.episodeGroup)
              TextField("合集开始：start", text: $rule.startGroup)
            }
            GridRow {
              TextField("合集结束：end", text: $rule.endGroup)
              TextField("完结标记：final", text: $rule.finalGroup)
            }
          }
        }
        .padding(.top, 4)
      }
      .font(.caption)
      Text("规则按当前顺序依次尝试；命中后优先于内置集数识别。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct EpisodeRuleTestResult: View {
  var response: EpisodeRuleTestResponse

  var body: some View {
    let parsed = response.parsedTitle
    VStack(alignment: .leading, spacing: 6) {
      Label(response.message, systemImage: parsed.episode == nil ? "exclamationmark.triangle" : "checkmark.circle")
        .foregroundStyle(parsed.episode == nil ? .orange : .green)
      HStack(spacing: 12) {
        Text(parsed.isBatch == true ? "合集" : "单集")
        if let episode = parsed.episode {
          Text("集数 \(episode)")
        }
        if let start = parsed.episodeStart, let end = parsed.episodeEnd, parsed.isBatch == true {
          Text("范围 \(start)-\(end)")
        }
        if parsed.isFinal == true {
          Text("完结")
        }
        if let ruleName = parsed.parseRuleName {
          Text("规则 \(ruleName)")
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
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }
}

struct SubscriptionEditorSheet: View {
  @EnvironmentObject private var store: AppStore
  var close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        SubscriptionForm(saved: close, cancelled: close)
          .padding(22)
          .frame(maxWidth: 620, alignment: .topLeading)
      }
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 680, idealHeight: 760)
    .onDisappear {
      store.cancelSubscriptionEditing()
    }
  }
}

private struct SubscriptionTestMatchSummary: View {
  var response: SubscriptionTestMatchResponse

  var body: some View {
    GroupBox("测试匹配结果") {
      VStack(alignment: .leading, spacing: 8) {
        Text(response.message)
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          if let pages = response.diagnostics.pagesFetched {
            Label("搜索 \(pages) 页", systemImage: "doc.text.magnifyingglass")
          }
          Label("抓取 \(response.diagnostics.totalFetched)", systemImage: "tray")
          if let totalUnique = response.diagnostics.totalUnique {
            Label("去重后 \(totalUnique)", systemImage: "square.stack.3d.up")
          }
          Label("匹配 \(response.diagnostics.matchedCount)", systemImage: "checkmark.circle")
          Label("字幕组过滤 \(response.diagnostics.excludedByFansub)", systemImage: "person.crop.rectangle")
          Label("集数过滤 \(response.diagnostics.excludedByEpisodeFilter)", systemImage: "number")
          if let reason = response.diagnostics.stopReasons?.first {
            Label("停止：\(reason)", systemImage: "checkmark.circle")
          }
          if response.diagnostics.reachedInternalSafetyLimit == true || response.diagnostics.hasMore == true {
            Label("可能还有更多", systemImage: "ellipsis.circle")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption)

        if (response.diagnostics.matchedBySubtitle ?? 0) > 0 ||
            (response.diagnostics.episodeParsedFromSubtitle ?? 0) > 0 ||
            (response.diagnostics.excludedByBatchPolicy ?? 0) > 0 ||
            (response.diagnostics.excludedByEpisodeCoverage ?? 0) > 0 {
          HStack(spacing: 12) {
            if let count = response.diagnostics.matchedBySubtitle, count > 0 {
              Label("副标题命中 \(count)", systemImage: "text.magnifyingglass")
            }
            if let count = response.diagnostics.episodeParsedFromSubtitle, count > 0 {
              Label("副标题解析集数 \(count)", systemImage: "number.square")
            }
            if let count = response.diagnostics.excludedByBatchPolicy, count > 0 {
              Label("合集策略排除 \(count)", systemImage: "rectangle.stack.badge.minus")
            }
            if let count = response.diagnostics.excludedByEpisodeCoverage, count > 0 {
              Label("范围未覆盖 \(count)", systemImage: "rectangle.and.text.magnifyingglass")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if !response.matchedSamples.isEmpty {
          Text("会匹配")
            .font(.caption.weight(.semibold))
          ForEach(response.matchedSamples.prefix(5)) { item in
            MatchDiagnosticSampleRow(item: item, accent: .green)
          }
        } else if !response.matched.isEmpty {
          Text("会匹配")
            .font(.caption.weight(.semibold))
          ForEach(response.matched.prefix(5)) { result in
            Text(result.title)
              .font(.caption)
              .lineLimit(2)
          }
        }

        if !response.excluded.isEmpty {
          Text("被排除示例")
            .font(.caption.weight(.semibold))
          ForEach(response.excluded.prefix(5)) { item in
            MatchDiagnosticSampleRow(item: item, accent: .orange)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct MatchDiagnosticSampleRow: View {
  var item: MatchDiagnosticSample
  var accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(item.title)
        .font(.caption)
        .lineLimit(2)
      Text(item.reason)
        .font(.caption2)
        .foregroundStyle(accent)
      HStack(spacing: 10) {
        if let fansub = item.parsedFansub {
          Text("字幕组 \(fansub)")
        }
        if let siteFansub = item.siteFansub,
           siteFansub != item.parsedFansub {
          Text("站点分组 \(siteFansub)")
        }
        if let resolution = item.parsedResolution {
          Text("分辨率 \(resolution)")
        }
        if item.isBatch == true, let start = item.parsedEpisodeStart, let end = item.parsedEpisodeEnd {
          Text("合集 \(start)-\(end)")
        } else if let episode = item.parsedEpisode {
          Text("第 \(episode) 集")
        }
        if item.isFinal == true {
          Text("完结")
        }
        if let seasonText {
          Text(seasonText)
        }
        if let ruleName = item.parseRuleName {
          Text("规则 \(ruleName)")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      if !subtitleEvidence.isEmpty {
        Text("副标题提供：\(subtitleEvidence.joined(separator: "、"))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let reason = item.parseFailureReason {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      if let reason = item.parseConflictReason {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  private var subtitleEvidence: [String] {
    var fields: [String] = []
    if item.titleMatchSource == "subtitle" { fields.append("番名") }
    if item.episodeParseSource == "subtitle" { fields.append("集数") }
    if item.seasonParseSource == "subtitle" { fields.append("季度") }
    if item.fansubParseSource == "subtitle" { fields.append("字幕组") }
    if item.resolutionParseSource == "subtitle" { fields.append("分辨率") }
    return fields
  }

  private var seasonText: String? {
    if let reason = item.seasonConflictReason {
      return reason
    }
    if let effective = item.effectiveSeasonNumber {
      switch item.seasonSource {
      case "subscription":
        return "使用订阅季 S\(String(format: "%02d", effective))"
      case "title_explicit":
        return "标题指定 S\(String(format: "%02d", effective))"
      case "default":
        return "默认推断 S\(String(format: "%02d", effective))"
      default:
        return "S\(String(format: "%02d", effective))"
      }
    }
    return nil
  }
}

private struct SmartPrefillSummaryView: View {
  var prefill: SmartSubscriptionPrefillResponse
  @Binding var isExpanded: Bool

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        if let ai = prefill.aiResult, prefill.source == "ai" {
          SmartPrefillField(label: "番名", value: ai.animeTitle)
          SmartPrefillField(label: "字幕组", value: ai.fansub)
          SmartPrefillField(label: "分辨率", value: ai.resolution)
          SmartPrefillField(label: "字幕语言", value: subtitleLanguageText(ai.subtitleLanguage))
          SmartPrefillField(label: "来源/格式", value: tagsText(ai))
          SmartPrefillField(label: "集数", value: ai.episodeNumber.map { "第 \($0) 集" })
          if ai.confidence < 0.8 {
            Label("AI 识别不确定，请检查后再保存。", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        } else {
          SmartPrefillField(label: "番名", value: prefill.localResult.title)
          SmartPrefillField(label: "字幕组", value: prefill.localResult.fansub)
          SmartPrefillField(label: "分辨率", value: prefill.localResult.resolution)
          SmartPrefillField(label: "字幕语言", value: subtitleLanguageText(prefill.localResult.subtitleLanguage))
        }
        ForEach(prefill.warnings, id: \.self) { warning in
          Label(warning, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
    } label: {
      Label(prefill.source == "ai" ? "AI 已填充" : "已使用本地解析", systemImage: prefill.source == "ai" ? "sparkles" : "text.magnifyingglass")
        .font(.subheadline.weight(.semibold))
    }
    .padding(10)
    .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
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

  private func tagsText(_ ai: AITitleAnalysisResponse) -> String? {
    let tags = Array(Set(ai.sourceTags + ai.formatTags)).sorted()
    return tags.isEmpty ? nil : tags.joined(separator: "、")
  }
}

private struct SmartPrefillField: View {
  var label: String
  var value: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Text(value?.isEmpty == false ? value! : "未识别")
        .font(.caption)
      Spacer()
    }
  }
}

private struct SubscriptionList: View {
  @EnvironmentObject private var store: AppStore
  var subscriptions: [Subscription]
  var searchText: String
  var filter: SubscriptionListFilter
  var showAll: () -> Void
  var edit: (Subscription) -> Void
  var detail: (Subscription) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if store.subscriptions.isEmpty {
        ContentUnavailableView("暂无订阅", systemImage: "dot.radiowaves.left.and.right", description: Text("当前没有保存的订阅。"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if subscriptions.isEmpty {
        ContentUnavailableView {
          Label(emptyTitle, systemImage: searchIsActive ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
        } description: {
          Text(emptyDescription)
        } actions: {
          if filter != .all {
            Button("显示全部") {
              showAll()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        if !store.refreshQueueProgressText.isEmpty {
          HStack {
            if store.refreshQueueRunning {
              ProgressView()
                .controlSize(.small)
            }
            Text(store.refreshQueueProgressText)
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
        }
        List(subscriptions) { subscription in
          SubscriptionRow(
            subscription: subscription,
            edit: { edit(subscription) },
            detail: { detail(subscription) }
          )
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.plain)
      }

    }
  }

  private var searchIsActive: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var emptyTitle: String {
    if searchIsActive {
      return filter == .all ? "没有匹配的订阅" : "当前范围内没有匹配的订阅"
    }
    return filter.emptyTitle
  }

  private var emptyDescription: String {
    if searchIsActive {
      return "没有找到与“\(searchText)”匹配的订阅。"
    }
    return filter == .all ? "当前没有保存的订阅。" : "当前显示：\(filter.title)"
  }
}

private struct SubscriptionRow: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.colorScheme) private var colorScheme
  @State private var confirmDelete = false
  @State private var isPosterVisible = false
  var subscription: Subscription
  var edit: () -> Void
  var detail: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      PosterView(
        urlString: subscription.posterLocalUrl ?? subscription.posterUrl,
        width: 92,
        height: 132,
        isActive: isPosterVisible
      )
        .padding(.top, 1)
        .appleTVPosterHover(.list)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(subscription.name)
            .font(.title3.weight(.semibold))
            .lineLimit(2)
          if let refreshState {
            Label(refreshState.title, systemImage: refreshState.systemImage)
              .font(.caption)
              .foregroundStyle(refreshState.color)
          }
          if !subscription.enabled {
            Text("已停用")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(metadataSummary ?? subscription.keyword)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        FlowLayout(spacing: 6) {
          CompactStatusBadge(text: sourceLabel, color: .secondary)
          if let resolution = subscription.resolution {
            CompactStatusBadge(text: resolution, color: .secondary)
          }
          if let season = subscription.season {
            CompactStatusBadge(text: "S\(String(format: "%02d", season))", color: .secondary)
          }
          if let startBadgeText = progressPresentation.startBadgeText {
            CompactStatusBadge(text: startBadgeText, color: .secondary)
          }
          if let fansub = subscription.fansub {
            CompactStatusBadge(text: fansub, color: .secondary)
          }
        }

        if let progress = progressMetrics {
          SubscriptionProgressView(progress: progress, palette: subscription.posterPalette)
        } else if let progressFallbackText {
          Text(progressFallbackText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        FlowLayout(spacing: 6) {
          if let matched = subscription.matchedCount, matched > 0 {
            CompactStatusBadge(text: "匹配 \(matched)", color: KisetsuStyle.animeTint)
          }
          if let queued = subscription.queuedCount, queued > 0 {
            CompactStatusBadge(text: "已提交 \(queued)", color: .green)
          }
          if let skipped = subscription.skippedCount, skipped > 0 {
            CompactStatusBadge(text: "跳过 \(skipped)", color: .secondary)
          }
          if let errors = subscription.errorCount, errors > 0 {
            CompactStatusBadge(text: "错误 \(errors)", color: .orange)
          }
        }

        FlowLayout(spacing: 8) {
          SubscriptionTimeStatus(text: latestRefreshLine, systemImage: "clock.arrow.circlepath", help: latestRefreshHelp)
          SubscriptionTimeStatus(text: latestOrganizedLine, systemImage: "checkmark.circle", help: latestOrganizedHelp)
        }
        if let latestError = subscription.latestError, !latestError.isEmpty {
          Text("最近错误：\(StatusLabels.message(latestError))")
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(2)
        }
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 8) {
        if subscription.autoDownload {
          Label("自动下载", systemImage: "arrow.down.circle.fill")
            .font(.caption)
            .foregroundStyle(autoDownloadColor)
        }
        HStack(spacing: 8) {
          Button { edit() } label: {
            Label("编辑", systemImage: "pencil")
          }
          .disabled(store.isLoading)

          Button {
            Task { await store.refreshSubscription(subscription) }
          } label: {
            Label("刷新", systemImage: "arrow.clockwise")
          }
          .disabled(store.isLoading)

          Menu {
            Button {
              Task { await store.toggleSubscriptionEnabled(subscription) }
            } label: {
              Label(subscription.enabled ? "停用" : "启用", systemImage: subscription.enabled ? "pause.circle" : "play.circle")
            }
            Button {
              detail()
            } label: {
              Label("详情", systemImage: "tray.full")
            }
            Button(role: .destructive) {
              confirmDelete = true
            } label: {
              Label("删除", systemImage: "trash")
            }
          } label: {
            Label("更多", systemImage: "ellipsis.circle")
          }
          .disabled(store.isLoading)
        }
      }
    }
    .padding(14)
    .animeCard()
    .subscriptionRowHoverLift()
    .contentShape(Rectangle())
    .onTapGesture {
      detail()
    }
    .onScrollVisibilityChange(threshold: 0.05) { isVisible in
      isPosterVisible = isVisible
    }
    .alert("删除订阅？", isPresented: $confirmDelete) {
      Button("取消", role: .cancel) {}
      Button("删除", role: .destructive) {
        Task { await store.deleteSubscription(subscription) }
      }
    } message: {
      Text("将删除“\(subscription.name)”的订阅规则、匹配历史、刷新历史、番剧识别结果和关联整理记录。下载历史会保留并解除订阅关联；不会删除下载器任务或真实文件。")
    }
  }

  private var sourceLabel: String {
    if subscription.sourceType == "rss" {
      let count = subscription.rssUrls.count
      return count > 0 ? "RSS \(count)" : "RSS"
    }
    return subscription.sites.isEmpty
      ? "未选择站点"
      : subscription.sites.map { store.siteLabel(for: $0) }.joined(separator: ", ")
  }

  private var refreshState: RefreshQueueVisualState? {
    guard let value = store.refreshQueueStates[subscription.id] else { return nil }
    return RefreshQueueVisualState(rawValue: value)
  }

  private var progressMetrics: SubscriptionProgressMetrics? {
    progressPresentation.metrics
  }

  private var progressPresentation: SubscriptionTargetProgressPresentation {
    SubscriptionTargetProgressPresentation(subscription: subscription)
  }

  private var progressFallbackText: String? {
    progressPresentation.fallbackText
  }

  private var latestRefreshLine: String? {
    if let latestRefresh = subscription.latestRefreshAt {
      return SubscriptionRelativeTime.actionText(from: latestRefresh, action: "刷新")
    }
    return "未刷新"
  }

  private var latestRefreshHelp: String? {
    guard let latestRefresh = subscription.latestRefreshAt else {
      return subscription.latestRefreshSummary
    }
    return "最近刷新：\(SubscriptionRelativeTime.absoluteString(from: latestRefresh) ?? latestRefresh)"
  }

  private var latestOrganizedLine: String? {
    if let latestOrganized = subscription.latestOrganizedAt {
      return SubscriptionRelativeTime.actionText(from: latestOrganized, action: "整理")
    }
    let organized = subscription.coverage?.organizedCount ?? subscription.organizedCount ?? 0
    if organized > 0 {
      return "已整理 \(organized) 集"
    }
    return "未整理"
  }

  private var latestOrganizedHelp: String? {
    if let latestOrganized = subscription.latestOrganizedAt {
      return "最近整理：\(SubscriptionRelativeTime.absoluteString(from: latestOrganized) ?? latestOrganized)"
    }
    let organized = subscription.coverage?.organizedCount ?? subscription.organizedCount ?? 0
    return organized > 0 ? "媒体库中已确认整理 \(organized) 集" : "还没有确认到已整理媒体文件"
  }

  private var metadataSummary: String? {
    let count = subscription.metadataBindingCount ?? 0
    let titles = subscription.metadataTitles ?? []
    if !titles.isEmpty {
      return titles.joined(separator: " / ")
    }
    if count > 0 {
      return "已识别 \(count) 条"
    }
    return nil
  }

  private var autoDownloadColor: Color {
    SubscriptionPalettePresentation.colors(
      palette: subscription.posterPalette,
      colorScheme: colorScheme
    ).primary
  }

}

private struct SubscriptionTimeStatus: View {
  var text: String?
  var systemImage: String
  var help: String?

  var body: some View {
    if let text, !text.isEmpty {
      Label(text, systemImage: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(help ?? text)
    }
  }
}

private struct SubscriptionProgressView: View {
  var progress: SubscriptionProgressMetrics
  var palette: PosterPalette?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.08))
          .frame(height: 6)
        Capsule()
          .fill(trackColor)
          .frame(width: max(8, CGFloat(progress.downloadedFraction) * 220), height: 6)
        Capsule()
          .fill(organizedColor)
          .frame(width: max(progress.organized > 0 ? 8 : 0, CGFloat(progress.organizedFraction) * 220), height: 6)
      }
      .frame(width: 220, alignment: .leading)
      Text("下载 \(progress.downloadedText) · 整理 \(progress.organizedText)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private var organizedColor: Color {
    SubscriptionPalettePresentation.colors(palette: palette, colorScheme: colorScheme).primary
  }

  private var trackColor: Color {
    SubscriptionPalettePresentation.colors(palette: palette, colorScheme: colorScheme).downloadedTrack
  }
}

private enum SubscriptionRelativeTime {
  static func actionText(from raw: String, action: String, now: Date = Date()) -> String {
    "\(relativeString(from: raw, now: now))\(action)"
  }

  static func relativeString(from raw: String, now: Date = Date()) -> String {
    guard let date = parse(raw) else {
      return "最近"
    }
    let interval = max(0, Int(now.timeIntervalSince(date)))
    if interval < 60 {
      return "刚刚"
    }
    if interval < 3600 {
      return "\(interval / 60) 分钟前"
    }
    if interval < 86400 {
      return "\(interval / 3600) 小时前"
    }
    return "\(max(1, interval / 86400)) 天前"
  }

  static func absoluteString(from raw: String) -> String? {
    guard let date = parse(raw) else {
      return nil
    }
    return absoluteFormatter.string(from: date)
  }

  private static func parse(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) {
      return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }

  private static let absoluteFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
  }()
}

private enum RefreshQueueVisualState: String {
  case waiting
  case running
  case done
  case failed
  case skipped

  var title: String {
    switch self {
    case .waiting: "等待中"
    case .running: "刷新中"
    case .done: "已刷新"
    case .failed: "失败"
    case .skipped: "已跳过"
    }
  }

  var systemImage: String {
    switch self {
    case .waiting: "clock"
    case .running: "arrow.triangle.2.circlepath"
    case .done: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    case .skipped: "minus.circle"
    }
  }

  var color: Color {
    switch self {
    case .waiting: .secondary
    case .running: .blue
    case .done: .green
    case .failed: .orange
    case .skipped: .secondary
    }
  }
}

private struct SubscriptionDetailSheet: View {
  @EnvironmentObject private var store: AppStore
  var close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.selectedSubscriptionDetail?.subscription.name ?? "订阅详情")
            .font(.title3.weight(.semibold))
          Text(store.selectedSubscriptionDetail?.subscription.keyword ?? "正在加载详情")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          close()
        } label: {
          Label("关闭", systemImage: "xmark.circle")
        }
      }
      .padding()

      Divider()

      if store.selectedSubscriptionDetail == nil {
        ContentUnavailableView("正在加载订阅详情", systemImage: "tray.full")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        SubscriptionDetailPanel()
      }
    }
    .frame(minWidth: 1120, idealWidth: 1240, minHeight: 760, idealHeight: 900)
  }
}

private struct MatchRecordsSection: View {
  @EnvironmentObject private var store: AppStore
  @State private var confirmAllDownload = false
  var matches: [SubscriptionMatch]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("匹配记录")
            .font(.headline)
          Text(matchSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !matches.isEmpty {
          Button {
            confirmAllDownload = true
          } label: {
            Label("全部下载", systemImage: "arrow.down.circle")
          }
          .disabled(store.isLoading)
        }
      }

      if matches.isEmpty {
        ContentUnavailableView("暂无匹配记录", systemImage: "tray", description: Text("刷新订阅后会在这里显示匹配到的资源。"))
          .frame(maxWidth: .infinity, minHeight: 160)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(matches, id: \.stableDisplayID) { match in
            MatchRow(match: match)
            if match.stableDisplayID != matches.last?.stableDisplayID {
              Divider()
            }
          }
        }
        .padding(.horizontal, 12)
        .animeCard()
      }
    }
    .alert("提交全部匹配下载？", isPresented: $confirmAllDownload) {
      Button("取消", role: .cancel) {}
      Button("提交下载") {
        Task { await store.downloadAllVisibleMatches() }
      }
    } message: {
      Text("将按当前订阅设置把已加载匹配条目提交到订阅下载器。")
    }
  }

  private var matchSummary: String {
    let queued = matches.filter { $0.status == "queued" }.count
    let skipped = matches.filter { $0.status == "skipped" }.count
    let errors = matches.filter { $0.status == "error" }.count
    let fresh = max(0, matches.count - queued - skipped - errors)
    var parts = ["共 \(matches.count) 条"]
    if fresh > 0 {
      parts.append("新匹配 \(fresh)")
    }
    if queued > 0 {
      parts.append("已提交 \(queued)")
    }
    if skipped > 0 {
      parts.append("跳过 \(skipped)")
    }
    if errors > 0 {
      parts.append("错误 \(errors)")
    }
    return parts.joined(separator: " / ")
  }
}

private struct MatchRow: View {
  @EnvironmentObject private var store: AppStore
  @State private var confirmDownload = false
  var match: SubscriptionMatch

  private var metadataSummary: String {
    var parts: [String] = []
    if let title = match.parsedTitle.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      parts.append(title)
    }
    parts.append(match.displayEpisodeLabel)
    if match.parsedTitle.isFinal == true {
      parts.append("完结")
    }
    if let resolution = match.parsedTitle.resolution?.trimmingCharacters(in: .whitespacesAndNewlines), !resolution.isEmpty {
      parts.append(resolution)
    }
    if let ruleName = match.parsedTitle.parseRuleName?.trimmingCharacters(in: .whitespacesAndNewlines), !ruleName.isEmpty {
      parts.append("规则 \(ruleName)")
    }
    parts.append(store.siteLabel(for: match.displaySourceID))
    parts.append(match.displaySize)
    parts.append(match.displayPublishedAt)
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(match.result.title)
          .font(.body.weight(.semibold))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text(metadataSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        if let mapping = match.episodeMappingLabel, !mapping.isEmpty {
          EpisodeMappingPill(text: mapping)
        }
        if let reason = match.parsedTitle.parseFailureReason, !reason.isEmpty {
          Text(reason)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
      }
      Spacer()

      Text(StatusLabels.match(match.status))
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusColor)
        .frame(width: 72, alignment: .trailing)

      Menu {
        Button {
          Task { await store.matchMetadata(for: match) }
        } label: {
          Label("识别番剧", systemImage: "film.stack")
        }
        Button {
          Task { await store.previewMatch(match) }
        } label: {
          Label("预览整理", systemImage: "eye")
        }
        Button {
          confirmDownload = true
        } label: {
          Label("下载", systemImage: "arrow.down.circle")
        }
      } label: {
        Label("更多", systemImage: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .disabled(store.isLoading)
      .frame(width: 72, alignment: .trailing)
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .alert("提交此匹配下载？", isPresented: $confirmDownload) {
      Button("取消", role: .cancel) {}
      Button("提交下载") {
        Task { await store.downloadMatch(match) }
      }
    } message: {
      Text("将把“\(match.result.title)”提交到订阅下载器。")
    }
  }

  private var statusColor: Color {
    switch match.status {
    case "queued":
      .green
    case "pending_confirmation":
      .orange
    case "skipped":
      .secondary
    case "error":
      .red
    default:
      .blue
    }
  }
}

private struct SubscriptionDetailPanel: View {
  @EnvironmentObject private var store: AppStore
  @State private var detailMode: SubscriptionDetailMode = .summary
  @State private var confirmReset = false
  @State private var confirmClearRecognition = false
  @State private var confirmClearMatches = false
  @State private var confirmClearOrganize = false
  @State private var confirmOrganizeAll = false
  @State private var pendingHistoryManage: SubscriptionHistoryManageAction?
  @State private var pendingHistoryDeletion: DownloadHistory?
  @State private var pendingHistoryClear: SubscriptionHistoryClearAction?
  @State private var pendingEpisodeAction: SubscriptionEpisodeAction?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("订阅详情")
          .font(.headline)
        Spacer()
        if let detail = store.selectedSubscriptionDetail {
          Text("匹配 \(detail.matchedCount) / 已提交 \(detail.queuedCount) / \(autoOrganizeText(detail))")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button {
            confirmOrganizeAll = true
          } label: {
            Label("整理全部", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.isLoading || !detail.episodeStatuses.contains(where: \.organizeAvailable))
          .help("整理全部已下载且未整理的剧集")
          Button {
            Task { await store.matchMetadataForSelectedSubscription() }
          } label: {
            Label("重新识别", systemImage: "sparkles.tv")
          }
          .disabled(store.isLoading)
          .help("重新搜索并确认这个订阅的番剧信息")
          Menu {
            Button(role: .destructive) {
              confirmClearRecognition = true
            } label: {
              Label("清除识别结果", systemImage: "sparkles.rectangle.stack")
            }
            .disabled(detail.metadataBindings.isEmpty && detail.plexMappings.isEmpty)

            Button(role: .destructive) {
              confirmClearMatches = true
            } label: {
              Label("清空匹配历史", systemImage: "tray.and.arrow.down")
            }
            .disabled(detail.matches.isEmpty)

            Button(role: .destructive) {
              confirmClearOrganize = true
            } label: {
              Label("清空整理记录", systemImage: "folder.badge.minus")
            }

            Divider()

            Button(role: .destructive) {
              pendingHistoryClear = SubscriptionHistoryClearAction(
                subscription: detail.subscription,
                scope: "refresh",
                title: "清空刷新历史？",
                message: "将清空“\(detail.subscription.name)”的刷新历史，不会删除匹配记录、下载记录或订阅规则。"
              )
            } label: {
              Label("清空刷新历史", systemImage: "clock.badge.xmark")
            }
            .disabled(detail.refreshHistory.isEmpty)

            Button(role: .destructive) {
              pendingHistoryClear = SubscriptionHistoryClearAction(
                subscription: detail.subscription,
                scope: "download",
                title: "清空下载历史？",
                message: "将清空“\(detail.subscription.name)”的下载历史记录，不会删除下载器任务或文件。关联匹配会回到新匹配。"
              )
            } label: {
              Label("清空下载历史", systemImage: "xmark.bin")
            }
            .disabled(detail.history.isEmpty)

            Button(role: .destructive) {
              pendingHistoryClear = SubscriptionHistoryClearAction(
                subscription: detail.subscription,
                scope: "all",
                title: "清空刷新与下载历史？",
                message: "将清空“\(detail.subscription.name)”的刷新历史和下载历史，不会删除订阅规则、番剧信息或整理规则。"
              )
            } label: {
              Label("清空两类历史", systemImage: "eraser")
            }
            .disabled(detail.refreshHistory.isEmpty && detail.history.isEmpty)
          } label: {
            Label("清理历史", systemImage: "eraser")
          }
          .disabled(store.isLoading)
          .help("只清理当前订阅详情里的历史记录")

          Button(role: .destructive) {
            confirmReset = true
          } label: {
            Label("重置状态", systemImage: "arrow.counterclockwise")
          }
          .disabled(store.isLoading)
          .help("清空当前订阅的匹配、刷新、下载和整理状态，保留订阅规则")
        }
      }
      .padding(.horizontal)
      .padding(.top, 10)

      if let detail = store.selectedSubscriptionDetail {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            SubscriptionDetailHero(detail: detail)

            Picker("详情视图", selection: $detailMode) {
              ForEach(SubscriptionDetailMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol)
                  .tag(mode)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520, alignment: .leading)

            switch detailMode {
            case .summary:
              SubscriptionOverviewView(detail: detail)
            case .episodes:
              MetadataHierarchyView(
                detail: detail,
                download: { resource, dryRun in
                  if let match = match(for: resource, in: detail) {
                    Task { await store.downloadMatch(match, dryRun: dryRun) }
                  }
                },
                preview: { resource in
                  Task { await store.previewResource(resource) }
                },
                deleteRecord: { resource in
                  if let history = history(for: resource, in: detail) {
                    pendingHistoryDeletion = history
                  }
                },
                deleteTask: { resource in
                  if let history = history(for: resource, in: detail) {
                    pendingHistoryManage = SubscriptionHistoryManageAction(
                      history: history,
                      action: "delete",
                      title: "删除这一集下载任务？",
                      message: "将从原下载器删除这一集的下载任务，但不会删除已下载文件；Kisetsu 会保留本地下载记录并刷新状态。",
                      confirmTitle: "删除下载任务"
                    )
                  }
                },
                deleteOrganizeRecord: { resource in
                  pendingEpisodeAction = SubscriptionEpisodeAction(
                    subscriptionID: detail.subscription.id,
                    matchID: resource.matchId,
                    title: "删除这一集整理记录？",
                    message: "只删除这一集在 Kisetsu 中的整理预览和整理记录，不会删除真实文件。",
                    confirmTitle: "删除整理记录",
                    kind: .deleteOrganize
                  )
                },
                resetEpisode: { resource in
                  pendingEpisodeAction = SubscriptionEpisodeAction(
                    subscriptionID: detail.subscription.id,
                    matchID: resource.matchId,
                    title: "重置这一集状态？",
                    message: "将删除这一集的本地下载记录、整理记录，并把匹配状态回到新匹配。不会删除下载器任务或真实文件。",
                    confirmTitle: "重置本集",
                    kind: .reset
                  )
                },
                organizeSelected: { episodeNumbers in
                  Task { await store.organizeCurrentSubscriptionEpisodes(episodeNumbers) }
                }
              )
            case .matches:
              MatchRecordsSection(matches: detail.matches)
            }
          }
          .padding(.horizontal)
          .padding(.bottom, 18)
        }
        .frame(minHeight: 360, idealHeight: 520, maxHeight: .infinity)
      } else {
        Text("尚未加载订阅详情")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal)
          .padding(.bottom, 12)
      }
    }
    .alert("重置订阅状态？", isPresented: $confirmReset) {
      Button("取消", role: .cancel) {}
      Button("重置状态", role: .destructive) {
        guard let subscription = store.selectedSubscriptionDetail?.subscription else { return }
        Task { await store.resetSubscriptionState(subscription) }
      }
    } message: {
      if let subscription = store.selectedSubscriptionDetail?.subscription {
        Text("将清空“\(subscription.name)”的匹配记录、刷新历史、下载历史和整理状态。订阅规则、订阅级番剧信息和整理规则会保留。")
      } else {
        Text("请先加载一个订阅详情。")
      }
    }
    .alert("清除识别结果？", isPresented: $confirmClearRecognition) {
      Button("取消", role: .cancel) {}
      Button("清除识别结果", role: .destructive) {
        guard let subscription = store.selectedSubscriptionDetail?.subscription else { return }
        Task { await store.clearSubscriptionRecognition(subscription) }
      }
    } message: {
      if let subscription = store.selectedSubscriptionDetail?.subscription {
        Text("将清除“\(subscription.name)”的 Bangumi/TMDB 识别结果、集数识别缓存和整理规则缓存。不会删除订阅、下载记录、下载器任务或真实文件。")
      } else {
        Text("请先加载一个订阅详情。")
      }
    }
    .alert("清空匹配历史？", isPresented: $confirmClearMatches) {
      Button("取消", role: .cancel) {}
      Button("清空匹配历史", role: .destructive) {
        guard let subscription = store.selectedSubscriptionDetail?.subscription else { return }
        Task { await store.clearSubscriptionMatchHistory(subscription) }
      }
    } message: {
      if let subscription = store.selectedSubscriptionDetail?.subscription {
        Text("将清空“\(subscription.name)”的资源匹配历史和对应集数识别缓存，不会删除订阅规则、下载历史、下载器任务或文件。")
      } else {
        Text("请先加载一个订阅详情。")
      }
    }
    .alert("清空整理记录？", isPresented: $confirmClearOrganize) {
      Button("取消", role: .cancel) {}
      Button("清空整理记录", role: .destructive) {
        guard let subscription = store.selectedSubscriptionDetail?.subscription else { return }
        Task { await store.clearSubscriptionOrganizeRecords(subscription) }
      }
    } message: {
      if let subscription = store.selectedSubscriptionDetail?.subscription {
        Text("将清空“\(subscription.name)”相关的整理预览和整理执行记录，不会删除真实文件。")
      } else {
        Text("请先加载一个订阅详情。")
      }
    }
    .alert("整理全部已下载剧集？", isPresented: $confirmOrganizeAll) {
      Button("取消", role: .cancel) {}
      Button("整理全部") {
        Task { await store.organizeCurrentSubscriptionAll() }
      }
    } message: {
      if let detail = store.selectedSubscriptionDetail {
        Text("将整理“\(detail.subscription.name)”中已下载且未整理的剧集到 \(detail.organizeTarget?.name ?? "默认整理目标")。整理成功后会按订阅策略处理原下载器任务。")
      } else {
        Text("请先加载一个订阅详情。")
      }
    }
    .alert("删除下载记录？", isPresented: Binding {
      pendingHistoryDeletion != nil
    } set: { isPresented in
      if !isPresented {
        pendingHistoryDeletion = nil
      }
    }) {
      Button("取消", role: .cancel) {
        pendingHistoryDeletion = nil
      }
      Button("删除记录", role: .destructive) {
        guard let item = pendingHistoryDeletion else { return }
        pendingHistoryDeletion = nil
        Task { await store.deleteHistoryRecord(item) }
      }
    } message: {
      if let item = pendingHistoryDeletion {
        Text("只删除 Kisetsu 的下载历史记录，不会删除原下载器任务或文件：\(item.title)")
      } else {
        Text("请选择要删除的下载记录。")
      }
    }
    .alert(pendingHistoryManage?.title ?? "管理下载任务？", isPresented: Binding {
      pendingHistoryManage != nil
    } set: { isPresented in
      if !isPresented {
        pendingHistoryManage = nil
      }
    }) {
      Button("取消", role: .cancel) {
        pendingHistoryManage = nil
      }
      Button(pendingHistoryManage?.confirmTitle ?? "确认", role: .destructive) {
        guard let action = pendingHistoryManage else { return }
        pendingHistoryManage = nil
        Task { await store.manageHistory(action.history, action: action.action) }
      }
    } message: {
      Text(pendingHistoryManage?.message ?? "")
    }
    .alert(pendingHistoryClear?.title ?? "清空历史？", isPresented: Binding {
      pendingHistoryClear != nil
    } set: { isPresented in
      if !isPresented {
        pendingHistoryClear = nil
      }
    }) {
      Button("取消", role: .cancel) {
        pendingHistoryClear = nil
      }
      Button("清空历史", role: .destructive) {
        guard let action = pendingHistoryClear else { return }
        pendingHistoryClear = nil
        Task { await store.clearSubscriptionHistory(action.subscription, scope: action.scope) }
      }
    } message: {
      Text(pendingHistoryClear?.message ?? "")
    }
    .alert(pendingEpisodeAction?.title ?? "确认单集操作？", isPresented: Binding {
      pendingEpisodeAction != nil
    } set: { isPresented in
      if !isPresented {
        pendingEpisodeAction = nil
      }
    }) {
      Button("取消", role: .cancel) {
        pendingEpisodeAction = nil
      }
      Button(pendingEpisodeAction?.confirmTitle ?? "确认", role: .destructive) {
        guard let action = pendingEpisodeAction else { return }
        pendingEpisodeAction = nil
        switch action.kind {
        case .deleteOrganize:
          Task { await store.deleteEpisodeOrganizeRecord(subscriptionID: action.subscriptionID, matchID: action.matchID) }
        case .reset:
          Task { await store.resetEpisodeState(subscriptionID: action.subscriptionID, matchID: action.matchID) }
        }
      }
    } message: {
      Text(pendingEpisodeAction?.message ?? "")
    }
    .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
      guard store.selectedSubscriptionDetail != nil, !store.isLoading else { return }
      Task { await store.refreshSelectedSubscriptionDetail(silent: true) }
    }
    .sheet(isPresented: $store.showingMetadataReview) {
      MetadataReviewSheet {
        store.showingMetadataReview = false
        Task { await store.refreshSelectedSubscriptionDetail(silent: true) }
      }
    }
  }

  private func match(for resource: SubscriptionEpisodeResource, in detail: SubscriptionDetail) -> SubscriptionMatch? {
    detail.matches.first { $0.id == resource.matchId }
  }

  private func history(for resource: SubscriptionEpisodeResource, in detail: SubscriptionDetail) -> DownloadHistory? {
    if let historyID = resource.downloadRecordId {
      return detail.history.first { $0.id == historyID }
    }
    guard let match = match(for: resource, in: detail) else {
      return nil
    }
    return detail.history.first { $0.fingerprint == match.fingerprint }
  }

  private func autoOrganizeText(_ detail: SubscriptionDetail) -> String {
    if let target = detail.organizeTarget, detail.subscription.autoOrganize == true {
      return "自动整理：\(detail.autoOrganizeStatus) → \(target.name)"
    }
    return "自动整理：\(detail.autoOrganizeStatus)"
  }
}

private struct SubscriptionHistoryClearAction {
  var subscription: Subscription
  var scope: String
  var title: String
  var message: String
}

private struct SubscriptionHistoryManageAction {
  var history: DownloadHistory
  var action: String
  var title: String
  var message: String
  var confirmTitle: String
}

private struct SubscriptionEpisodeAction {
  var subscriptionID: Int
  var matchID: Int
  var title: String
  var message: String
  var confirmTitle: String
  var kind: SubscriptionEpisodeActionKind
}

private enum SubscriptionEpisodeActionKind {
  case deleteOrganize
  case reset
}

private enum SubscriptionDetailMode: String, CaseIterable, Identifiable {
  case summary
  case episodes
  case matches

  var id: String { rawValue }

  var title: String {
    switch self {
    case .summary:
      return "订阅概况"
    case .episodes:
      return "剧集状态"
    case .matches:
      return "匹配记录"
    }
  }

  var symbol: String {
    switch self {
    case .summary:
      return "info.circle"
    case .episodes:
      return "list.bullet.rectangle"
    case .matches:
      return "line.3.horizontal.decrease.circle"
    }
  }
}

private struct DetailSummarySection: View {
  var detail: SubscriptionDetail

  var body: some View {
    SubscriptionOverviewGrid(
      left: [
        OverviewMetric(title: "来源", value: sourceSummary, symbol: "antenna.radiowaves.left.and.right"),
        OverviewMetric(title: "来源地址", value: sourceAddressSummary, symbol: "link"),
        OverviewMetric(title: "站点", value: siteSummary, symbol: "network"),
        OverviewMetric(title: "过滤器", value: filterSummary, symbol: "line.3.horizontal.decrease.circle"),
      ],
      right: [
        OverviewMetric(title: "Season", value: seasonSummary, symbol: "rectangle.stack"),
        OverviewMetric(title: "起始集数", value: episodeStartSummary, symbol: "number"),
        OverviewMetric(title: "下载设置", value: downloadSummary, symbol: "arrow.down.circle"),
        OverviewMetric(title: "最近刷新", value: detail.latestRefreshAt ?? "未知", symbol: "clock.arrow.circlepath"),
        OverviewMetric(title: "最近刷新摘要", value: StatusLabels.message(detail.latestRefreshSummary), symbol: "checklist"),
      ],
      footer: detail.latestError == nil ? nil : OverviewMetric(title: "最近错误", value: StatusLabels.message(detail.latestError), symbol: "exclamationmark.triangle")
    )
  }

  private var filterSummary: String {
    var items = ["关键词 \(detail.subscription.keyword)"]
    if let regex = detail.subscription.regex {
      items.append("Regex \(regex)")
    }
    if !detail.subscription.includeKeywords.isEmpty {
      items.append("包含 \(detail.subscription.includeKeywords.joined(separator: ","))")
    }
    if !detail.subscription.excludeKeywords.isEmpty {
      items.append("排除 \(detail.subscription.excludeKeywords.joined(separator: ","))")
    }
    if !detail.subscription.includeKeywords.isEmpty && !detail.subscription.excludeKeywords.isEmpty {
      items.append(detail.subscription.filterOrder == "exclude_first" ? "先排除后包含" : "先包含后排除")
    }
    if let fansub = detail.subscription.fansub {
      items.append("字幕组 \(fansub)")
    }
    if let resolution = detail.subscription.resolution {
      items.append("分辨率 \(resolution)")
    }
    if detail.subscription.minSizeBytes != nil || detail.subscription.maxSizeBytes != nil {
      let minimum = SubscriptionSizeFilterDraft.display(bytes: detail.subscription.minSizeBytes)
      let maximum = SubscriptionSizeFilterDraft.display(bytes: detail.subscription.maxSizeBytes)
      let minimumText = minimum.text.isEmpty ? "不限" : "\(minimum.text) \(minimum.unit.rawValue)"
      let maximumText = maximum.text.isEmpty ? "不限" : "\(maximum.text) \(maximum.unit.rawValue)"
      items.append("视频体积 \(minimumText) - \(maximumText)")
    }
    if let season = detail.subscription.season {
      items.append("Season \(season)")
    }
    if let episode = detail.subscription.episode {
      items.append("指定集数 \(episode)")
    }
    if let episodeStart = detail.subscription.episodeStart {
      items.append("起始集数 \(episodeStart)")
    }
    if detail.subscription.episodeOffset != 0 {
      items.append("集数偏移 \(detail.subscription.episodeOffset)（暂未参与匹配）")
    }
    return items.joined(separator: " / ")
  }

  private var siteSummary: String {
    detail.subscription.sites.isEmpty ? "未指定站点" : detail.subscription.sites.joined(separator: ", ")
  }

  private var sourceSummary: String {
    switch detail.subscription.sourceType ?? "keyword" {
    case "rss":
      return "RSS" + (detail.subscription.rssUrls.isEmpty ? "" : " · \(detail.subscription.rssUrls.count) 个地址")
    case "mikan_bangumi":
      return "Mikan 番组" + ((detail.subscription.mikanBangumiUrl ?? detail.subscription.sourceUrl) == nil ? "" : " · 已填写地址")
    default:
      return "关键词搜索"
    }
  }

  private var sourceAddressSummary: String {
    switch detail.subscription.sourceType ?? "keyword" {
    case "rss":
      return detail.subscription.rssUrls.isEmpty ? "未填写 RSS 地址" : detail.subscription.rssUrls.prefix(2).joined(separator: " / ")
    case "mikan_bangumi":
      return detail.subscription.mikanBangumiUrl ?? detail.subscription.sourceUrl ?? "未填写 Mikan 番组地址"
    default:
      return detail.subscription.sourceUrl ?? "使用关键词搜索"
    }
  }

  private var seasonSummary: String {
    if let season = detail.subscription.season {
      return "Season \(String(format: "%02d", season))"
    }
    return "未指定"
  }

  private var episodeStartSummary: String {
    if let episodeStart = detail.subscription.episodeStart {
      return "\(episodeStart)"
    }
    if let episode = detail.subscription.episode {
      return "指定集数 \(episode)"
    }
    return "自动识别"
  }

  private var downloadSummary: String {
    var items: [String] = []
    if let savePath = detail.subscription.savePath, !savePath.isEmpty {
      items.append("保存路径 \(savePath)")
    }
    if let category = detail.subscription.category, !category.isEmpty {
      items.append("分类 \(category)")
    }
    if !detail.subscription.tags.isEmpty {
      items.append("标签 \(detail.subscription.tags.joined(separator: ","))")
    }
    return items.isEmpty ? "使用订阅下载器默认设置" : items.joined(separator: " / ")
  }
}

private struct SubscriptionDetailHero: View {
  var detail: SubscriptionDetail

  private var primaryShow: SubscriptionMetadataHierarchy? {
    detail.metadataHierarchy.first
  }

  private var posterURL: String? {
    primaryShow?.posterLocalUrl ?? primaryShow?.posterUrl ?? detail.subscription.posterLocalUrl ?? detail.subscription.posterUrl
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      PosterAmbientBackground(palette: primaryShow?.posterPalette ?? detail.subscription.posterPalette, isEmphasized: true)

      HStack(alignment: .bottom, spacing: 20) {
        PosterView(urlString: posterURL, width: 112, height: 158)
          .appleTVPosterHover(.hero)

        VStack(alignment: .leading, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            Text(primaryShow?.title ?? detail.subscription.name)
              .font(.title2.weight(.semibold))
              .lineLimit(2)
            if let originalTitle, !originalTitle.isEmpty {
              Text(originalTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(heroSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          HStack(spacing: 8) {
            DetailHeroPill(title: "匹配", value: "\(detail.matchedCount)", color: KisetsuStyle.animeTint)
            DetailHeroPill(title: "已提交", value: "\(detail.queuedCount)", color: .green)
            DetailHeroPill(title: "跳过", value: "\(detail.skippedCount)", color: .secondary)
            DetailHeroPill(title: "整理", value: detail.autoOrganizeStatus, color: .teal)
          }
          .lineLimit(1)
        }
        Spacer(minLength: 12)
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, minHeight: 218, alignment: .bottomLeading)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(KisetsuStyle.subtleBorder)
    }
  }

  private var originalTitle: String? {
    guard let show = primaryShow,
          let original = show.originalTitle,
          original != show.title else {
      return nil
    }
    return original
  }

  private var heroSubtitle: String {
    var items: [String] = []
    items.append(detail.subscription.sourceType == "rss" ? "RSS 订阅" : "自动订阅")
    if let show = primaryShow {
      items.append(show.sourceLabel)
      if let total = show.totalEpisodes {
        items.append("\(total) 集")
      }
      if let airDate = show.airDate, !airDate.isEmpty {
        items.append(airDate)
      }
    }
    if let season = detail.subscription.season {
      items.append("Season \(String(format: "%02d", season))")
    }
    if let batchStatus = detail.coverage?.batchStatusLabel {
      items.append(batchStatus)
    }
    return items.joined(separator: " · ")
  }
}

private struct DetailHeroPill: View {
  var title: String
  var value: String
  var color: Color

  var body: some View {
    HStack(spacing: 5) {
      Text(title)
        .font(.caption)
      Text(value)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay {
      Capsule()
        .stroke(color.opacity(0.22))
    }
  }
}

private struct SubscriptionOverviewView: View {
  var detail: SubscriptionDetail

  private var primaryShow: SubscriptionMetadataHierarchy? {
    detail.metadataHierarchy.first
  }

  private let columns = [
    GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      OverviewMediaInfoSection(detail: detail, show: primaryShow, metadataLine: metadataLine)

      LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
        SubscriptionOverviewSection(title: "订阅设置", symbol: "slider.horizontal.3") {
          DetailSummarySection(detail: detail)
        }

        OrganizeInfoSection(detail: detail)
      }

      HStack(alignment: .top, spacing: 24) {
        RefreshHistoryList(history: detail.refreshHistory)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        SubscriptionHistoryList(history: detail.history)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private var metadataLine: String {
    guard let show = primaryShow else {
      return "未绑定番剧信息"
    }
    var items = [show.sourceLabel]
    if let airDate = show.airDate, !airDate.isEmpty {
      items.append(airDate)
    }
    if let total = show.totalEpisodes {
      items.append("\(total) 集")
    }
    if let rating = show.rating {
      items.append(String(format: "评分 %.1f", rating))
    }
    return items.joined(separator: " / ")
  }
}

private struct OverviewMediaInfoSection: View {
  var detail: SubscriptionDetail
  var show: SubscriptionMetadataHierarchy?
  var metadataLine: String

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SubscriptionOverviewSection(title: "番剧信息", symbol: "sparkles.tv") {
        VStack(alignment: .leading, spacing: 7) {
          Text(show?.title ?? detail.subscription.name)
            .font(.title3.weight(.semibold))
          if let original = show?.originalTitle, original != show?.title {
            Text(original)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Text(metadataLine)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      SubscriptionOverviewSection(title: "简介", symbol: "text.alignleft") {
        if let summary = show?.summary, !summary.isEmpty {
          Text(summary)
            .font(.callout)
            .lineSpacing(3)
            .lineLimit(10)
            .frame(maxWidth: 760, alignment: .leading)
            .textSelection(.enabled)
        } else {
          Text("暂无简介。重新识别并选择 Bangumi 或 TMDB 候选后，这里会显示简介。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 760, alignment: .leading)
        }
      }

      if let tags = show?.tags, !tags.isEmpty {
        SubscriptionOverviewSection(title: "标签", symbol: "tag") {
          TagCloud(tags: tags)
        }
      }
    }
  }
}

private struct OrganizeInfoSection: View {
  var detail: SubscriptionDetail

  var body: some View {
    SubscriptionOverviewSection(title: "整理信息", symbol: "folder.badge.gearshape") {
      VStack(alignment: .leading, spacing: 10) {
        OrganizeTargetPreviewBlock(detail: detail)
        DetailInfoRow(title: "自动整理", value: detail.autoOrganizeStatus)
        DetailInfoRow(title: "Plex 命名", value: plexMappingSummary)
        DetailInfoRow(title: "后续动作", value: postOrganizeSummary)
      }
    }
  }

  private var plexMappingSummary: String {
    if detail.plexMappings.isEmpty {
      return "自动规则未生成"
    }
    return detail.plexMappings.prefix(3).map { record in
      let mapping = record.mapping
      var value = "\(mapping.showName) / Season \(String(format: "%02d", mapping.seasonNumber))"
      if mapping.episodeOffset != 0 {
        value += " / 偏移 \(mapping.episodeOffset)"
      }
      return value
    }
    .joined(separator: " / ")
  }

  private var postOrganizeSummary: String {
    if detail.subscription.keepSeeding == true || detail.subscription.postOrganizeAction == "keep_seeding" {
      if detail.subscription.seedingPolicyMode == "custom" {
        return "整理后继续做种（当前订阅自定义规则）"
      }
      return "整理后继续做种（使用全局规则）"
    }
    if detail.subscription.deleteTaskAfterOrganize == true {
      return "整理后移除 qB 任务"
    }
    if detail.subscription.deleteFilesAfterOrganize == true {
      return "整理后删除源文件"
    }
    if let action = detail.subscription.postOrganizeAction, !action.isEmpty {
      return action
    }
    return "保持默认"
  }
}

private struct OrganizeTargetPreviewBlock: View {
  var detail: SubscriptionDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("整理目标")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if let target = detail.organizeTarget {
          Text(target.name)
            .font(.caption.weight(.medium))
          if target.isDefault {
            Text("默认")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.secondary.opacity(0.12), in: Capsule())
          }
          if !target.enabled {
            Text("已停用")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.orange)
          }
        }
      }

      if let preview = detail.organizeTargetPreview, preview.rootPath != nil || preview.seasonPath != nil {
        if let rootPath = preview.rootPath {
          PathPreviewLine(title: "根目录", value: rootPath)
        }
        if let showPath = preview.showPath {
          PathPreviewLine(title: "番剧目录", value: showPath)
        }
        if let seasonPath = preview.seasonPath {
          PathPreviewLine(title: "季度目录", value: seasonPath, emphasized: true)
        }
        if let message = preview.message, !message.isEmpty {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      } else {
        Text(detail.organizeTargetPreview?.message ?? fallbackMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private var fallbackMessage: String {
    if detail.subscription.organizeTargetId != nil {
      return "目标不可用，请在设置中检查整理目标"
    }
    return "未设置整理目标，无法生成番剧目录预览。"
  }
}

private struct PathPreviewLine: View {
  var title: String
  var value: String
  var emphasized: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(emphasized ? .primary : .secondary)
        .lineLimit(2)
        .textSelection(.enabled)
        .help(value)
    }
  }
}

private struct SubscriptionOverviewSection<Content: View>: View {
  var title: String
  var symbol: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: symbol)
        .font(.headline)
      content
    }
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

private struct OverviewMetric: Identifiable {
  var id: String { title }
  var title: String
  var value: String
  var symbol: String
}

private struct SubscriptionOverviewGrid: View {
  var left: [OverviewMetric]
  var right: [OverviewMetric]
  var footer: OverviewMetric?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        OverviewMetricColumn(metrics: left)
        OverviewMetricColumn(metrics: right)
      }
      if let footer {
        Divider()
        OverviewMetricRow(metric: footer)
      }
    }
  }
}

private struct OverviewMetricColumn: View {
  var metrics: [OverviewMetric]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(metrics) { metric in
        OverviewMetricRow(metric: metric)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

private struct OverviewMetricRow: View {
  var metric: OverviewMetric

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: metric.symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
      DetailInfoRow(title: metric.title, value: metric.value)
    }
  }
}

struct PosterView: View {
  @EnvironmentObject private var store: AppStore
  var urlString: String?
  var width: CGFloat = 128
  var height: CGFloat = 182
  var isActive = true

  var body: some View {
    PlaylistPosterView(
      url: store.backendResourceURL(urlString),
      width: width,
      height: height,
      isActive: isActive
    )
  }
}

struct CompactStatusBadge: View {
  var text: String
  var color: Color
  var systemImage: String? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
    }
      .font(.caption2.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.10), in: Capsule())
  }
}

private struct TagCloud: View {
  var tags: [String]

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(tags.prefix(18), id: \.self) { tag in
        Text(tag)
          .font(.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quaternary, in: Capsule())
      }
    }
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: width, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

private struct DetailInfoRow: View {
  var title: String
  var value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value.isEmpty ? "未设置" : value)
        .font(.caption)
        .lineLimit(3)
        .textSelection(.enabled)
    }
  }
}

private struct RefreshHistoryList: View {
  var history: [SubscriptionRefreshHistory]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("刷新历史")
        .font(.caption.weight(.semibold))
      if history.isEmpty {
        Text("暂无刷新历史")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(history.prefix(5)) { item in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(AppRelativeTime.concise(item.createdAt))
                .lineLimit(1)
              Spacer()
              Text("匹配 \(item.matchedCount)")
              Text("提交 \(item.addedCount)")
              Text("跳过 \(item.skippedCount)")
              if item.errorCount > 0 {
                Text("错误 \(item.errorCount)")
                  .foregroundStyle(.red)
              }
            }
            if !item.warnings.isEmpty {
              Text(item.warnings.prefix(2).joined(separator: "；"))
                .lineLimit(2)
                .foregroundStyle(.orange)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct MetadataHierarchyView: View {
  var detail: SubscriptionDetail
  var download: (SubscriptionEpisodeResource, Bool) -> Void
  var preview: (SubscriptionEpisodeResource) -> Void
  var deleteRecord: (SubscriptionEpisodeResource) -> Void
  var deleteTask: (SubscriptionEpisodeResource) -> Void
  var deleteOrganizeRecord: (SubscriptionEpisodeResource) -> Void
  var resetEpisode: (SubscriptionEpisodeResource) -> Void
  var organizeSelected: ([Int]) -> Void
  @State private var selectedEpisodes: Set<Int> = []
  @State private var confirmOrganizeSelected = false

  private var seasons: [(number: Int, episodes: [SubscriptionLogicalEpisodeStatus])] {
    Dictionary(grouping: detail.episodeStatuses, by: \.seasonNumber)
      .map { (number: $0.key, episodes: $0.value.sorted { $0.episodeNumber < $1.episodeNumber }) }
      .sorted { $0.number < $1.number }
  }

  private var selectableEpisodeNumbers: Set<Int> {
    Set(
      detail.episodeStatuses
        .filter(SubscriptionEpisodeScopePresentation.isSelectable)
        .map(\.episodeNumber)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("剧集状态")
          .font(.caption.weight(.semibold))
        Spacer()
        Button {
          confirmOrganizeSelected = true
        } label: {
          Label("整理选中", systemImage: "checklist")
        }
        .disabled(selectedEpisodes.isEmpty)
      }
      Text(statusSummary)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if seasons.isEmpty {
        ContentUnavailableView(
          "暂无剧集状态",
          systemImage: "rectangle.stack",
          description: Text("刷新订阅后会在这里显示每一集，以及每集匹配到的资源。")
        )
        .frame(maxWidth: .infinity, minHeight: 160)
      } else {
        ForEach(seasons.indices, id: \.self) { index in
          let season = seasons[index]
          MetadataSeasonGroup(
            seasonNumber: season.number,
            episodes: season.episodes,
            download: download,
            preview: preview,
            deleteRecord: deleteRecord,
            deleteTask: deleteTask,
            deleteOrganizeRecord: deleteOrganizeRecord,
            resetEpisode: resetEpisode,
            selectedEpisodes: $selectedEpisodes
          )
        }
      }

      if !detail.unmatchedResources.isEmpty {
        BatchResourcesGroup(
          resources: detail.unmatchedResources,
          download: download,
          preview: preview,
          deleteRecord: deleteRecord,
          deleteTask: deleteTask,
          deleteOrganizeRecord: deleteOrganizeRecord,
          resetEpisode: resetEpisode
        )
      }
    }
    .alert("整理选中剧集？", isPresented: $confirmOrganizeSelected) {
      Button("取消", role: .cancel) {}
      Button("整理选中") {
        organizeSelected(Array(selectedEpisodes.intersection(selectableEpisodeNumbers)).sorted())
        selectedEpisodes.removeAll()
      }
    } message: {
      Text("将整理选中的 \(selectedEpisodes.count) 集到订阅的整理目标，并按订阅策略处理原下载器任务。")
    }
    .onChange(of: selectableEpisodeNumbers) { _, validEpisodes in
      selectedEpisodes.formIntersection(validEpisodes)
    }
  }

  private var statusSummary: String {
    SubscriptionEpisodeScopePresentation.summary(
      coverage: detail.coverage,
      episodes: detail.episodeStatuses
    )
  }
}

private struct MetadataSeasonGroup: View {
  var seasonNumber: Int
  var episodes: [SubscriptionLogicalEpisodeStatus]
  var download: (SubscriptionEpisodeResource, Bool) -> Void
  var preview: (SubscriptionEpisodeResource) -> Void
  var deleteRecord: (SubscriptionEpisodeResource) -> Void
  var deleteTask: (SubscriptionEpisodeResource) -> Void
  var deleteOrganizeRecord: (SubscriptionEpisodeResource) -> Void
  var resetEpisode: (SubscriptionEpisodeResource) -> Void
  @Binding var selectedEpisodes: Set<Int>
  @State private var expanded = true

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        if episodes.isEmpty {
          Text("暂无集数")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(episodes) { episode in
            MetadataEpisodeRow(
              episode: episode,
              download: download,
              preview: preview,
              deleteRecord: deleteRecord,
              deleteTask: deleteTask,
              deleteOrganizeRecord: deleteOrganizeRecord,
              resetEpisode: resetEpisode,
              isSelected: Binding {
                SubscriptionEpisodeScopePresentation.isSelectable(episode)
                  && selectedEpisodes.contains(episode.episodeNumber)
              } set: { isSelected in
                if isSelected, SubscriptionEpisodeScopePresentation.isSelectable(episode) {
                  selectedEpisodes.insert(episode.episodeNumber)
                } else {
                  selectedEpisodes.remove(episode.episodeNumber)
                }
              }
            )
          }
        }
      }
      .padding(.top, 5)
      .padding(.leading, 22)
    } label: {
      HStack {
        Image(systemName: "rectangle.stack")
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(String(format: "Season %02d", seasonNumber))
          .font(.caption.weight(.medium))
        Spacer()
        Text("\(episodes.count) 集")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 18)
  }
}

private enum SubscriptionProgressText {
  static func compact(_ progress: QbittorrentTaskProgress, fallback: String) -> String {
    var parts: [String] = []
    if let percent = progress.progressPercent {
      parts.append("\(percentText(percent))")
    }
    if let speed = progress.downloadSpeed, speed > 0 {
      parts.append(byteSpeed(speed))
    } else if let upload = progress.uploadSpeed, upload > 0 {
      parts.append("上传 \(byteSpeed(upload))")
    }
    if let ratio = progress.ratio, (progress.progress ?? 0) >= 0.999 {
      parts.append("分享率 \(String(format: "%.2f", ratio))")
    }
    if parts.isEmpty {
      return progress.stateLabel ?? fallback
    }
    return parts.joined(separator: " · ")
  }

  static func primary(_ progress: QbittorrentTaskProgress) -> String {
    var parts: [String] = []
    if let label = progress.stateLabel {
      parts.append(label)
    }
    if let percent = progress.progressPercent {
      parts.append(percentText(percent))
    }
    if let downloaded = progress.downloaded, let total = progress.totalSize, total > 0 {
      parts.append("\(byteString(downloaded)) / \(byteString(total))")
    }
    if let down = progress.downloadSpeed, down > 0 {
      parts.append("下载 \(byteSpeed(down))")
    }
    if let up = progress.uploadSpeed, up > 0 {
      parts.append("上传 \(byteSpeed(up))")
    }
    if let eta = progress.eta, eta >= 0, (progress.progress ?? 0) < 0.999,
       progress.seedingTime == nil || progress.seedingTime == 0 {
      parts.append("剩余 \(duration(eta))")
    }
    return parts.isEmpty ? StatusLabels.message(progress.message) : parts.joined(separator: " · ")
  }

  static func secondary(_ progress: QbittorrentTaskProgress) -> String? {
    var parts: [String] = []
    if let target = progress.seedingTargetRatio {
      if let ratio = progress.ratio {
        parts.append("分享率 \(String(format: "%.0f%%", ratio * 100)) / \(String(format: "%.0f%%", target * 100))")
      } else {
        parts.append("分享率暂时无法确认 / 目标 \(String(format: "%.0f%%", target * 100))")
      }
    } else if let ratio = progress.ratio {
      parts.append("分享率 \(String(format: "%.2f", ratio))")
    }
    if let target = progress.seedingTargetSeconds {
      if let seeding = progress.seedingTime {
        parts.append("已做种 \(duration(seeding)) / \(duration(target))")
        if let remaining = progress.seedingRemainingSeconds, remaining > 0 {
          parts.append("还需 \(duration(remaining))")
        }
      } else {
        parts.append("做种时间暂时无法确认 / 目标 \(duration(target))")
      }
    } else if let seeding = progress.seedingTime, seeding > 0 {
      parts.append("做种 \(duration(seeding))")
    }
    if let seeds = progress.numSeeds {
      parts.append("种子 \(seeds)")
    } else if let complete = progress.numComplete {
      parts.append("种子 \(complete)")
    }
    if let leechs = progress.numLeechs {
      parts.append("连接 \(leechs)")
    } else if let incomplete = progress.numIncomplete {
      parts.append("连接 \(incomplete)")
    }
    if let refreshed = progress.lastSeenAt {
      parts.append("刷新 \(shortTime(refreshed))")
    }
    if let condition = progress.seedingStopCondition, !condition.isEmpty {
      parts.append("停止条件 \(condition)")
    }
    if let action = progress.postSeedingAction, !action.isEmpty {
      parts.append("达标后 \(action)")
    }
    if progress.seedingTargetReached == true {
      parts.append("已达标，等待处理")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func percentText(_ value: Double) -> String {
    if value >= 99.95 {
      return "100%"
    }
    return "\(String(format: "%.1f", value))%"
  }

  private static func byteString(_ value: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
  }

  private static func byteSpeed(_ value: Int) -> String {
    "\(byteString(value))/s"
  }

  private static func duration(_ seconds: Int) -> String {
    if seconds < 0 {
      return "未知"
    }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 {
      return "\(days)天\(hours)小时"
    }
    if hours > 0 {
      return "\(hours)小时\(minutes)分钟"
    }
    if minutes > 0 {
      return "\(minutes)分钟"
    }
    return "\(seconds)秒"
  }

  private static func shortTime(_ raw: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    guard let date else {
      return raw
    }
    let output = DateFormatter()
    output.dateFormat = "HH:mm:ss"
    return output.string(from: date)
  }
}

private struct MetadataEpisodeRow: View {
  @EnvironmentObject private var store: AppStore
  var episode: SubscriptionLogicalEpisodeStatus
  var download: (SubscriptionEpisodeResource, Bool) -> Void
  var preview: (SubscriptionEpisodeResource) -> Void
  var deleteRecord: (SubscriptionEpisodeResource) -> Void
  var deleteTask: (SubscriptionEpisodeResource) -> Void
  var deleteOrganizeRecord: (SubscriptionEpisodeResource) -> Void
  var resetEpisode: (SubscriptionEpisodeResource) -> Void
  @Binding var isSelected: Bool
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 6) {
        if isExcludedByEpisodeStart {
          Text("此集早于订阅起始集数，无需下载")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, 30)
        } else if episode.matchedResources.isEmpty {
          Text("暂无匹配资源")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
        } else {
          ForEach(episode.matchedResources) { resource in
            EpisodeResourceRow(
              resource: resource,
              download: download,
              preview: preview,
              deleteRecord: deleteRecord,
              deleteTask: deleteTask,
              deleteOrganizeRecord: deleteOrganizeRecord,
              resetEpisode: resetEpisode
            )
          }
        }
      }
      .padding(.top, 6)
      .padding(.leading, 28)
    } label: {
      HStack(spacing: 10) {
        if isExcludedByEpisodeStart {
          Image(systemName: "forward.end")
            .foregroundStyle(.tertiary)
            .frame(width: 18)
            .accessibilityHidden(true)
        } else {
          Toggle("", isOn: $isSelected)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!SubscriptionEpisodeScopePresentation.isSelectable(episode))
            .frame(width: 18)
        }

        Text(String(format: "E%02d", episode.episodeNumber))
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(isExcludedByEpisodeStart ? .tertiary : .primary)
          .frame(width: 42, alignment: .leading)

        VStack(alignment: .leading, spacing: 1) {
          Text(episode.displayTitle)
            .font(.caption.weight(.medium))
            .foregroundStyle(isExcludedByEpisodeStart ? .secondary : .primary)
            .lineLimit(1)
          Text(resourceSummary)
            .font(.caption2)
            .foregroundStyle(
              isExcludedByEpisodeStart
                ? Color.secondary
                : episode.matchedResources.isEmpty ? Color.secondary : Color.blue
            )
            .lineLimit(1)
        }

        Spacer()

        StatusBadge(
          title: episodeStatusTitle,
          detail: episodeStatusDetail,
          systemImage: episodeStatusIcon,
          color: episodeStatusColor
        )
      }
      .padding(.vertical, 3)
      .modifier(SubscriptionEpisodeAccessibilityModifier(episode: episode))
    }
    .font(.caption)
  }

  private var resourceSummary: String {
    if isExcludedByEpisodeStart {
      return "起始集数前"
    }
    let count = episode.matchedResources.count
    if count == 0 {
      return "等待匹配资源"
    }
    let sites = Set(episode.matchedResources.map { store.siteLabel(for: $0.site) })
      .sorted()
      .joined(separator: " / ")
    return "匹配 \(count) 条资源\(sites.isEmpty ? "" : " · \(sites)")"
  }

  private var primaryResource: SubscriptionEpisodeResource? {
    episode.matchedResources.first { $0.qbittorrent?.matched == true }
      ?? episode.matchedResources.first { $0.downloadRecordId != nil }
      ?? episode.matchedResources.first { $0.isBatch != true && $0.resourceType != "batch" && $0.resourceType != "episode_range" }
      ?? episode.matchedResources.first
  }

  private var isExcludedByEpisodeStart: Bool {
    SubscriptionEpisodeScopePresentation.isExcluded(episode)
  }

  private var episodeStatusTitle: String {
    if let status = episode.derivedStatus, !status.isEmpty {
      return status
    }
    if episode.organizeStatus == "已整理" {
      return "已整理"
    }
    guard let resource = primaryResource else {
      return episode.downloadStatus
    }
    if let qb = resource.qbittorrent, qb.matched {
      if let progress = qb.progress, progress >= 0.999 {
        if qb.stateLabel?.contains("做种") == true || (qb.uploadSpeed ?? 0) > 0 {
          return "做种中"
        }
        return "已完成"
      }
      return "下载中"
    }
    return resource.downloadStatus
  }

  private var episodeStatusDetail: String {
    if let detail = episode.derivedStatusDetail, !detail.isEmpty {
      return detail
    }
    if episode.organizeStatus == "已整理" {
      return "归档完成 · \(episode.matchedResources.count) 条资源"
    }
    if let resource = primaryResource, let qb = resource.qbittorrent, qb.matched {
      return SubscriptionProgressText.compact(qb, fallback: resource.downloadStatus)
    }
    if episode.downloadStatus == "已完成" {
      return "等待整理 · \(episode.matchedResources.count) 条资源"
    }
    return resourceSummary
  }

  private var episodeStatusIcon: String {
    switch episodeStatusTitle {
    case "已跳过":
      return "forward.end"
    case "已整理", "已整理并移除任务", "已停止做种":
      return "folder.badge.gearshape"
    case "已完成", "下载完成，待整理":
      return "checkmark.circle.fill"
    case "下载中":
      return "arrow.down.circle.fill"
    case "做种中":
      return "arrow.up.arrow.down.circle.fill"
    case "已提交下载":
      return "clock"
    case "未匹配资源", "等待订阅刷新":
      return "circle"
    default:
      return "arrow.down.circle"
    }
  }

  private var episodeStatusColor: Color {
    switch episodeStatusTitle {
    case "已跳过":
      return .secondary
    case "已整理", "已整理并移除任务", "已停止做种":
      return .green
    case "已完成", "下载完成，待整理":
      return .green
    case "下载中":
      return .blue
    case "做种中":
      return .teal
    case "已提交下载":
      return .orange
    case "未匹配资源", "等待订阅刷新":
      return .secondary
    default:
      return .secondary
    }
  }
}

private struct SubscriptionEpisodeAccessibilityModifier: ViewModifier {
  var episode: SubscriptionLogicalEpisodeStatus

  @ViewBuilder
  func body(content: Content) -> some View {
    if SubscriptionEpisodeScopePresentation.isExcluded(episode) {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SubscriptionEpisodeScopePresentation.accessibilityLabel(for: episode))
    } else {
      content
    }
  }
}

private struct EpisodeResourceRow: View {
  @EnvironmentObject private var store: AppStore
  var resource: SubscriptionEpisodeResource
  var download: (SubscriptionEpisodeResource, Bool) -> Void
  var preview: (SubscriptionEpisodeResource) -> Void
  var deleteRecord: (SubscriptionEpisodeResource) -> Void
  var deleteTask: (SubscriptionEpisodeResource) -> Void
  var deleteOrganizeRecord: (SubscriptionEpisodeResource) -> Void
  var resetEpisode: (SubscriptionEpisodeResource) -> Void
  @State private var confirmDownload = false
  @State private var confirmOrganize = false

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(resource.rawTitle)
          .font(.caption)
          .lineLimit(2)
        Text(metadataLine)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let mapping = resource.episodeMappingLabel, !mapping.isEmpty {
          EpisodeMappingPill(text: mapping)
        }
        if let progressLine {
          Text(progressLine)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(progressColor)
            .lineLimit(1)
        }
        if let detailLine {
          Text(detailLine)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()

      StatusBadge(
        title: resourceStatusTitle,
        detail: resourceStatusDetail,
        systemImage: resourceDownloadIcon,
        color: resourceDownloadColor
      )

      HStack(spacing: 4) {
        Menu {
          Button {
            confirmDownload = true
          } label: {
            Label("提交下载", systemImage: "arrow.down.circle")
          }
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28, height: 24)
        .help("下载这个资源")

        Button {
          confirmOrganize = true
        } label: {
          Image(systemName: "wand.and.stars")
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 24)
        .help("整理这个资源")

        Menu {
          Button(role: .destructive) {
            deleteTask(resource)
          } label: {
            Label("删除下载任务", systemImage: "trash")
          }
          .disabled(resource.downloadRecordId == nil)

          Button(role: .destructive) {
            deleteRecord(resource)
          } label: {
            Label("删除下载记录", systemImage: "xmark.bin")
          }
          .disabled(resource.downloadRecordId == nil)

          Divider()

          Button(role: .destructive) {
            deleteOrganizeRecord(resource)
          } label: {
            Label("删除整理记录", systemImage: "folder.badge.minus")
          }
          Button(role: .destructive) {
            resetEpisode(resource)
          } label: {
            Label("重置本资源状态", systemImage: "arrow.counterclockwise")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28, height: 24)
        .help("更多资源操作")
      }
    }
    .padding(.vertical, 3)
    .alert("提交这个资源下载？", isPresented: $confirmDownload) {
      Button("取消", role: .cancel) {}
      Button("提交下载") {
        download(resource, false)
      }
    } message: {
      Text("将把“\(resource.rawTitle)”提交到订阅下载器。")
    }
    .alert("整理这个资源？", isPresented: $confirmOrganize) {
      Button("取消", role: .cancel) {}
      Button("整理") {
        store.appendLog("organize confirm clicked resource match_id=\(resource.matchId) download_record_id=\(resource.downloadRecordId.map(String.init) ?? "nil")")
        preview(resource)
      }
    } message: {
      Text(organizeConfirmMessage)
    }
  }

  private var organizeConfirmMessage: String {
    if resource.isBatch == true || resource.resourceType == "batch" {
      return "这是合集资源。若下载内容是文件夹，会尝试逐个识别视频文件；若是单个大文件，不会强行拆成多集，会作为合集文件等待你确认。"
    }
    return "将整理“\(resource.rawTitle)”到订阅的整理目标，并按订阅策略处理原下载器任务。"
  }

  private var metadataLine: String {
    var parts: [String] = [store.siteLabel(for: resource.site)]
    if let fansub = resource.fansubGroup {
      parts.append(fansub)
    }
    if let resolution = resource.resolution {
      parts.append(resolution)
    }
    if let label = resource.displayEpisodeLabel, !label.isEmpty {
      parts.append(label)
    } else if let start = resource.absoluteEpisodeStart, let end = resource.absoluteEpisodeEnd {
      parts.append("合集 \(start)–\(end)")
    } else if resource.isBatch == true, let start = resource.episodeStart, let end = resource.episodeEnd {
      parts.append("合集 \(start)–\(max(start, end))")
    }
    if let start = resource.seasonEpisodeStart, let end = resource.seasonEpisodeEnd {
      parts.append("季内 \(String(format: "%02d", start))–\(String(format: "%02d", end))")
    }
    if let size = resource.size {
      parts.append(size)
    }
    if let publishTime = resource.publishTime {
      parts.append(publishTime)
    }
    return parts.joined(separator: " · ")
  }

  private var resourceStatusTitle: String {
    if let status = resource.derivedStatus, !status.isEmpty {
      return status
    }
    if resource.organizeStatus == "已整理" {
      return "已整理"
    }
    guard let qb = resource.qbittorrent, qb.matched else {
      return resource.downloadStatus
    }
    if let progress = qb.progress, progress >= 0.999 {
      if qb.stateLabel?.contains("做种") == true || (qb.uploadSpeed ?? 0) > 0 {
        return "做种中"
      }
      return "已完成"
    }
    return "下载中"
  }

  private var resourceStatusDetail: String {
    if let detail = resource.derivedStatusDetail, !detail.isEmpty {
      return detail
    }
    if resource.isBatch == true && resource.downloadRecordId == nil {
      return "默认不自动下载，避免重复下载整季"
    }
    if resource.isBatch == true && resourceStatusTitle == "合集待整理" {
      return "这是合集资源，整理前请确认单文件或多文件结构"
    }
    if resource.organizeStatus == "已整理" {
      return "已归档"
    }
    guard let qb = resource.qbittorrent, qb.matched else {
      return resource.qbittorrent.map { StatusLabels.message($0.message) } ?? resource.status
    }
    if let progress = qb.progress, progress >= 0.999, resource.organizeStatus != "已整理" {
      return "等待整理"
    }
    return SubscriptionProgressText.compact(qb, fallback: resource.downloadStatus)
  }

  private var progressLine: String? {
    guard let qb = resource.qbittorrent, qb.matched else { return nil }
    return SubscriptionProgressText.primary(qb)
  }

  private var detailLine: String? {
    guard let qb = resource.qbittorrent, qb.matched else { return nil }
    return SubscriptionProgressText.secondary(qb)
  }

  private var progressColor: Color {
    switch resourceStatusTitle {
    case "已完成", "已整理", "下载完成，待整理", "已整理并移除任务", "已停止做种":
      return .green
    case "做种中":
      return .teal
    case "下载中":
      return .blue
    default:
      return .secondary
    }
  }

  private var resourceDownloadIcon: String {
    switch resourceStatusTitle {
    case "已整理", "已整理并移除任务", "已停止做种":
      return "folder.badge.gearshape"
    case "做种中":
      return "arrow.up.arrow.down.circle.fill"
    case "已完成", "下载完成，待整理":
      return "checkmark.circle.fill"
    case "下载中":
      return "arrow.down.circle.fill"
    case "已提交下载":
      return "clock"
    default:
      return "circle"
    }
  }

  private var resourceDownloadColor: Color {
    switch resourceStatusTitle {
    case "已整理", "已整理并移除任务", "已停止做种", "已完成", "下载完成，待整理":
      return .green
    case "做种中":
      return .teal
    case "下载中":
      return .blue
    case "已提交下载":
      return .orange
    default:
      return .secondary
    }
  }
}

private struct BatchResourcesGroup: View {
  var resources: [SubscriptionEpisodeResource]
  var download: (SubscriptionEpisodeResource, Bool) -> Void
  var preview: (SubscriptionEpisodeResource) -> Void
  var deleteRecord: (SubscriptionEpisodeResource) -> Void
  var deleteTask: (SubscriptionEpisodeResource) -> Void
  var deleteOrganizeRecord: (SubscriptionEpisodeResource) -> Void
  var resetEpisode: (SubscriptionEpisodeResource) -> Void
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(resources) { resource in
          EpisodeResourceRow(
            resource: resource,
            download: download,
            preview: preview,
            deleteRecord: deleteRecord,
            deleteTask: deleteTask,
            deleteOrganizeRecord: deleteOrganizeRecord,
            resetEpisode: resetEpisode
          )
        }
      }
      .padding(.top, 6)
      .padding(.leading, 28)
    } label: {
      HStack {
        Image(systemName: "rectangle.stack.badge.plus")
          .foregroundStyle(.orange)
          .frame(width: 18)
        Text(title)
          .font(.caption.weight(.medium))
        Spacer()
        Text(summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption)
  }

  private var title: String {
    resources.contains { $0.isBatch == true || $0.resourceType == "batch" || $0.resourceType == "episode_range" }
      ? "合集 / 多集资源"
      : "未识别集数的资源"
  }

  private var summary: String {
    let batchCount = resources.filter { $0.isBatch == true || $0.resourceType == "batch" }.count
    if batchCount > 0 {
      return "\(resources.count) 条 · 合集 \(batchCount) 条"
    }
    return "\(resources.count) 条"
  }
}

private struct StatusBadge: View {
  var title: String
  var detail: String
  var systemImage: String
  var color: Color

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.caption2.weight(.semibold))
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(color)
    }
    .labelStyle(.titleAndIcon)
    .frame(width: 150, alignment: .leading)
  }
}

private struct EpisodeMappingPill: View {
  var text: String

  var body: some View {
    Label(text, systemImage: "arrow.triangle.branch")
      .font(.caption2.monospacedDigit().weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.thinMaterial, in: Capsule())
      .overlay {
        Capsule()
          .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
      }
      .lineLimit(1)
  }
}

private struct SubscriptionHistoryList: View {
  var history: [DownloadHistory]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("下载历史")
        .font(.caption.weight(.semibold))
      if history.isEmpty {
        Text("暂无下载历史")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(history.prefix(5)) { item in
          HStack {
            Text(item.title)
              .lineLimit(1)
            Spacer()
            Text(StatusLabels.download(item.status))
            Text(AppRelativeTime.concise(item.createdAt))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct RefreshLogSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          Text("最近刷新日志")
            .font(.title3.weight(.semibold))
          Text("只展示最近一次手动刷新结果，完整历史仍在订阅详情中。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .font(.title3)
        }
        .buttonStyle(.plain)
        .help("关闭")
      }
      .padding(20)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if store.showingRefreshAllSummary, let response = store.lastRefreshAllResponse {
            RefreshAllSummary(response: response)
          } else if let response = store.lastRefreshResponse {
            RefreshSummary(response: response)
          } else {
            ContentUnavailableView("暂无刷新日志", systemImage: "clock", description: Text("刷新订阅后会在这里显示最近一次结果。"))
              .frame(maxWidth: .infinity, minHeight: 220)
          }
        }
        .padding(20)
      }
    }
    .frame(width: 720, height: 520)
  }
}

private struct RefreshSummary: View {
  var response: RefreshResponse

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
        RefreshLogMetric(title: "匹配", value: "\(response.matched.count)", systemImage: "checkmark.circle", color: .blue)
        RefreshLogMetric(title: "提交", value: "\(response.added.count)", systemImage: "arrow.down.circle", color: .green)
        RefreshLogMetric(title: "跳过", value: "\(response.skipped.count)", systemImage: "forward.end", color: .secondary)
        RefreshLogMetric(title: "错误", value: "\(errorCount)", systemImage: "exclamationmark.triangle", color: errorCount > 0 ? .red : .secondary)
      }
      if let diagnostics = response.diagnostics {
        RefreshLogSection(title: "搜索诊断") {
          Text("搜索 \(diagnostics.pagesFetched ?? 0) 页 · 抓取 \(diagnostics.totalFetched) · 去重后 \(diagnostics.totalUnique ?? diagnostics.totalFetched) · 匹配 \(diagnostics.matchedCount)")
          Text("字幕组过滤 \(diagnostics.excludedByFansub) · 包含词过滤 \(diagnostics.excludedByInclude) · 排除词过滤 \(diagnostics.excludedByExclude) · 分辨率过滤 \(diagnostics.excludedByResolution) · 正则过滤 \(diagnostics.excludedByRegex) · 集数过滤 \(diagnostics.excludedByEpisodeFilter) · 重复 \(diagnostics.duplicateCount)")
          if (diagnostics.matchedBySubtitle ?? 0) > 0 || (diagnostics.episodeParsedFromSubtitle ?? 0) > 0 {
            Text("副标题番名命中 \(diagnostics.matchedBySubtitle ?? 0) · 副标题解析集数 \(diagnostics.episodeParsedFromSubtitle ?? 0)")
          }
          if (diagnostics.excludedByBatchPolicy ?? 0) > 0 || (diagnostics.excludedByEpisodeCoverage ?? 0) > 0 {
            Text("合集策略排除 \(diagnostics.excludedByBatchPolicy ?? 0) · 范围未覆盖 \(diagnostics.excludedByEpisodeCoverage ?? 0)")
          }
        }
        if let reason = diagnostics.stopReasons?.first {
          RefreshLogNote(text: "停止原因：\(reason)", color: .secondary, systemImage: "flag")
        }
        if diagnostics.reachedInternalSafetyLimit == true || diagnostics.hasMore == true {
          RefreshLogNote(text: "结果较多，已在安全上限停止。建议缩小关键词、添加字幕组或包含词过滤。", color: .orange, systemImage: "exclamationmark.triangle")
        }
        if diagnostics.matchedCount == 0 {
          RefreshLogNote(text: zeroMatchHint(diagnostics), color: .orange, systemImage: "lightbulb")
        }
      }
      if !response.added.isEmpty {
        RefreshLogNote(text: "已提交：\(titles(response.added))", color: .green, systemImage: "arrow.down.circle")
      }
      if !response.skipped.isEmpty {
        RefreshLogNote(text: "已跳过：\(titles(response.skipped))", color: .secondary, systemImage: "forward.end")
      }
      ForEach(response.warnings, id: \.self) { warning in
        RefreshLogNote(text: warning, color: .orange, systemImage: "exclamationmark.triangle")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var errorCount: Int {
    response.matchRecords.filter { $0.status == "error" }.count
  }

  private func zeroMatchHint(_ diagnostics: MatchDiagnostics) -> String {
    if diagnostics.totalFetched == 0 { return "多页搜索后仍没有抓取到候选资源，请检查站点、Mikan URL 或网络状态。" }
    if diagnostics.excludedByFansub > 0 { return "资源存在，但被字幕组过滤排除 \(diagnostics.excludedByFansub) 条。" }
    if diagnostics.excludedByInclude > 0 { return "资源存在，但没有命中包含词。" }
    if diagnostics.excludedByExclude > 0 { return "资源存在，但命中了排除词。" }
    if diagnostics.excludedByResolution > 0 { return "资源存在，但分辨率不匹配。" }
    if (diagnostics.excludedBySize ?? 0) > 0 { return "资源存在，但未通过视频体积过滤。" }
    if diagnostics.excludedByRegex > 0 { return "资源存在，但正则表达式没有匹配。" }
    if (diagnostics.excludedByBatchPolicy ?? 0) > 0 { return "资源存在，但合集被当前合集策略排除。" }
    if (diagnostics.excludedByEpisodeCoverage ?? 0) > 0 { return "资源存在，但合集或单集没有覆盖当前需要下载的集数。" }
    if diagnostics.excludedByEpisodeFilter > 0 { return "资源存在，但不在指定集数范围内。" }
    if diagnostics.excludedByTitle > 0 { return "资源存在，但番名或别名没有命中。" }
    return "未抓取到候选资源，请检查站点、Mikan URL 或网络状态。"
  }

  private func titles(_ results: [SearchResult]) -> String {
    let prefix = results.prefix(3).map(\.title).joined(separator: "；")
    if results.count > 3 {
      return "\(prefix) 等 \(results.count) 条"
    }
    return prefix
  }
}

private struct RefreshAllSummary: View {
  var response: RefreshAllResponse

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
        RefreshLogMetric(title: "已刷新", value: "\(response.refreshed)", systemImage: "arrow.clockwise", color: .blue)
        RefreshLogMetric(title: "匹配", value: "\(matchedCount)", systemImage: "checkmark.circle", color: .blue)
        RefreshLogMetric(title: "提交", value: "\(addedCount)", systemImage: "arrow.down.circle", color: .green)
        RefreshLogMetric(title: "错误", value: "\(errorCount)", systemImage: "exclamationmark.triangle", color: errorCount > 0 ? .red : .secondary)
      }
      RefreshLogSection(title: "刷新概览") {
        Text("跳过订阅 \(response.skipped ?? 0) · 跳过资源 \(skippedCount)")
      }
      if addedCount > 0 {
        RefreshLogNote(text: "已提交下载：\(addedCount) 条", color: .green, systemImage: "arrow.down.circle")
      }
      if skippedCount > 0 {
        RefreshLogNote(text: "已跳过：\(skippedCount) 条", color: .secondary, systemImage: "forward.end")
      }
      ForEach(warnings.prefix(4), id: \.self) { warning in
        RefreshLogNote(text: warning, color: .orange, systemImage: "exclamationmark.triangle")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var matchedCount: Int {
    response.responses.reduce(0) { $0 + $1.matched.count }
  }

  private var addedCount: Int {
    response.responses.reduce(0) { $0 + $1.added.count }
  }

  private var skippedCount: Int {
    response.responses.reduce(0) { $0 + $1.skipped.count }
  }

  private var errorCount: Int {
    response.responses.reduce(0) { $0 + $1.matchRecords.filter { $0.status == "error" }.count }
  }

  private var warnings: [String] {
    response.warnings + response.responses.flatMap(\.warnings)
  }
}

private struct RefreshLogMetric: View {
  var title: String
  var value: String
  var systemImage: String
  var color: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.title3.monospacedDigit().weight(.semibold))
      }
      Spacer()
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct RefreshLogSection<Content: View>: View {
  var title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        content
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
    }
  }
}

private struct RefreshLogNote: View {
  var text: String
  var color: Color
  var systemImage: String

  var body: some View {
    Label(StatusLabels.message(text), systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(color)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
