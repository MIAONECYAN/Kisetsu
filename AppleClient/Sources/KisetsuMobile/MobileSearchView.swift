import SwiftUI

struct MobileSearchView: View {
  @EnvironmentObject private var store: AppStore
  var isActive: Bool
  @State private var showingSites = false
  @State private var showingFilters = false
  @State private var showingSettings = false
  @State private var selectedResult: SearchResult?
  @State private var downloadQueue = MobileSearchDownloadQueue()
  @State private var downloadDraft: MobileSearchDownloadDraft?
  @State private var preparingDownloadResultID: String?
  @State private var showingSubscriptionEditor = false

  var body: some View {
    List {
      if store.searchHasActiveFilters || !store.searchResults.isEmpty {
        Section {
          HStack(spacing: 8) {
            Button {
              showingFilters = true
            } label: {
              Label(filterTitle, systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(.glass)

            if store.searchHasActiveFilters {
              Button("重置", systemImage: "arrow.uturn.backward") {
                resetFilters()
              }
              .buttonStyle(.glass)
            }

            Spacer()
            Text("\(store.visibleSearchResults.count) 个结果")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .listRowBackground(Color.clear)
        }
      }

      if store.visibleSearchResults.isEmpty {
        if isSearching {
          ProgressView("正在搜索")
            .frame(maxWidth: .infinity, minHeight: 320)
            .listRowBackground(Color.clear)
        } else {
          ContentUnavailableView(
            store.searchResults.isEmpty ? "搜索资源" : "没有符合筛选的资源",
            systemImage: store.searchResults.isEmpty ? "magnifyingglass" : "line.3.horizontal.decrease.circle",
            description: Text(store.searchResults.isEmpty ? "输入关键词并选择站点后开始搜索。" : "调整或重置当前筛选条件。")
          )
          .frame(maxWidth: .infinity, minHeight: 320)
          .listRowBackground(Color.clear)
        }
      } else {
        ForEach(store.visibleSearchResults) { result in
          Button {
            selectedResult = result
          } label: {
            MobileSearchResultRow(result: result)
          }
          .buttonStyle(.plain)
          .contextMenu {
            resultActions(result)
          }
        }
      }

      if MobileSearchPaginationPresentation.isVisible(
        paginationEnabled: store.searchPaginationEnabled,
        canGoPrevious: store.searchCanGoToPreviousPage,
        canGoNext: store.searchCanGoToNextPage
      ) {
        Section {
          HStack {
            Spacer()
            GlassEffectContainer(spacing: 8) {
              HStack(spacing: 8) {
                Button("上一页", systemImage: "chevron.left") {
                  Task { await store.performPreviousSearchPage() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .frame(width: 44, height: 44)
                .disabled(!store.searchCanGoToPreviousPage)

                Text("第 \(store.searchCurrentPage) 页")
                  .font(.subheadline.monospacedDigit())
                  .foregroundStyle(.secondary)
                  .frame(minWidth: 62)

                Button("下一页", systemImage: "chevron.right") {
                  Task { await store.performNextSearchPage() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .frame(width: 44, height: 44)
                .disabled(!store.searchCanGoToNextPage)
              }
            }
            Spacer()
          }
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      }
    }
    .listStyle(.plain)
    .mobileNavigationTitle("搜索")
    .searchable(text: $store.searchKeyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索动漫或资源")
    .onSubmit(of: .search) {
      Task { await store.performSearch() }
    }
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Button("搜索站点", systemImage: "network") {
            showingSites = true
          }
          Button("搜索设置", systemImage: "gearshape") {
            showingSettings = true
          }
        } label: {
          Label("搜索选项", systemImage: "slider.horizontal.3")
        }
        Button {
          Task { await store.performSearch() }
        } label: {
          Group {
            if isSearching {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "magnifyingglass")
            }
          }
          .frame(width: 18, height: 18)
        }
        .accessibilityLabel(isSearching ? "正在搜索" : "搜索")
        .disabled(store.isLoading || store.searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .task(id: isActive) {
      guard isActive, MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      if !store.sitesLoaded {
        await store.loadSites()
      }
      if !store.organizeTargetsLoaded {
        _ = await store.ensureOrganizeTargetsLoaded()
      }
    }
    .sheet(isPresented: $showingSites) {
      MobileSearchSiteSheet()
        .environmentObject(store)
    }
    .sheet(isPresented: $showingFilters) {
      MobileSearchFilterSheet()
        .environmentObject(store)
    }
    .sheet(isPresented: $showingSettings) {
      MobileSearchSettingsSheet()
        .environmentObject(store)
    }
    .sheet(item: $selectedResult, onDismiss: presentQueuedDownload) { result in
      MobileSearchResultDetail(
        result: result,
        identify: { identify(result) },
        subscribe: { smartSubscribe(result) },
        download: { queueDownloadAfterDetail(result) }
      )
    }
    .sheet(item: $downloadDraft) { draft in
      MobileSearchDownloadSheet(
        draft: draft,
        organizeTargets: store.organizeTargets,
        cancel: { downloadDraft = nil },
        submit: submitDownload
      )
      .environmentObject(store)
    }
    .sheet(isPresented: $store.showingMetadataReview) {
      MobileMetadataReviewSheet()
        .environmentObject(store)
    }
    .sheet(isPresented: $showingSubscriptionEditor, onDismiss: {
      Task { await store.runPendingMetadataRecognitionIfNeeded() }
    }) {
      MobileSubscriptionEditorView()
        .environmentObject(store)
    }
  }

  private var isSearching: Bool {
    store.isLoading && store.activeOperationLabel == "搜索资源"
  }

  @ViewBuilder
  private func resultActions(_ result: SearchResult) -> some View {
    Button("查看详情", systemImage: "info.circle") { selectedResult = result }
    Button("识别番剧", systemImage: "sparkles") { identify(result) }
    Button("智能订阅", systemImage: "dot.radiowaves.left.and.right") { smartSubscribe(result) }
    if MobileSearchDownloadPresentation.isDownloadable(result) {
      Button("添加到下载", systemImage: "arrow.down.circle") { presentDownload(result) }
    } else {
      Button("缺少下载链接", systemImage: "exclamationmark.triangle") {}
        .disabled(true)
    }
  }

  private var filterTitle: String {
    guard store.searchHasActiveFilters else { return "筛选" }
    var count = store.selectedSearchFansubs.count + store.selectedSearchResolutions.count
    if !store.searchEpisodeFilter.isEmpty || store.searchShowUnrecognizedEpisodes { count += 1 }
    if store.searchShowBatchOnly { count += 1 }
    return "筛选 \(count)"
  }

  private func resetFilters() {
    store.selectedSearchFansubs = []
    store.selectedSearchResolutions = []
    store.searchEpisodeFilter = ""
    store.searchShowUnrecognizedEpisodes = false
    store.searchShowBatchOnly = false
  }

  private func identify(_ result: SearchResult) {
    selectedResult = nil
    Task { await store.matchMetadata(for: result) }
  }

  private func smartSubscribe(_ result: SearchResult) {
    selectedResult = nil
    Task {
      guard let response = await store.suggestSubscription(from: result),
            let suggestion = response.suggestion else { return }
      let fansubs = store.smartSubscriptionFansubs(for: result, among: store.searchResults)
      store.prepareSubscriptionForm(from: response, suggestion: suggestion, result: result, availableFansubs: fansubs)
      showingSubscriptionEditor = true
    }
  }

  private func queueDownloadAfterDetail(_ result: SearchResult) {
    guard downloadQueue.enqueue(result) else {
      store.operationStatus = OperationStatus(
        phase: .empty,
        title: "无法下载",
        detail: MobileSearchDownloadPresentation.unavailableMessage,
        updatedAt: Date()
      )
      return
    }
    selectedResult = nil
  }

  private func presentQueuedDownload() {
    guard let queued = downloadQueue.consume(defaultTargetID: nil) else { return }
    Task { await prepareDownload(queued.result) }
  }

  private func presentDownload(_ result: SearchResult) {
    guard MobileSearchDownloadPresentation.isDownloadable(result) else {
      store.operationStatus = OperationStatus(
        phase: .empty,
        title: "无法下载",
        detail: MobileSearchDownloadPresentation.unavailableMessage,
        updatedAt: Date()
      )
      return
    }
    Task { await prepareDownload(result) }
  }

  @MainActor
  private func prepareDownload(_ result: SearchResult) async {
    guard preparingDownloadResultID == nil else { return }
    preparingDownloadResultID = result.id
    defer { preparingDownloadResultID = nil }

    guard await store.ensureOrganizeTargetsLoaded() else { return }
    downloadDraft = MobileSearchDownloadDraft(
      result: result,
      defaultTargetID: store.defaultOrganizeTarget?.id
    )
  }

  private func submitDownload(_ draft: MobileSearchDownloadDraft) async -> Bool {
    #if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      try? await Task.sleep(for: .milliseconds(220))
      let outcome = MobileDebugConfiguration.fixtureSearchDownloadOutcome(
        environment: ProcessInfo.processInfo.environment
      )
      if outcome == .success {
        store.operationStatus = OperationStatus(
          phase: .success,
          title: "模拟下载已提交",
          detail: "脱敏 Fixture 已记录请求，没有创建真实下载任务。",
          updatedAt: Date()
        )
        return true
      }
      store.operationStatus = OperationStatus(
        phase: .failed,
        title: outcome == .timeout ? "模拟下载超时" : "模拟下载提交失败",
        detail: "脱敏 Fixture 保留确认界面，未创建真实下载任务。",
        updatedAt: Date()
      )
      return false
    }
    #endif
    return await store.addDownload(draft.result, organizeTargetID: draft.organizeTargetID)
  }
}

private struct MobileSearchResultRow: View {
  @EnvironmentObject private var store: AppStore
  var result: SearchResult

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(result.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(3)
      if let subtitle = result.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      MobileTagFlowLayout {
        MobileSearchPromotionBadge(result: result)
        MobileTag(text: store.siteLabel(for: result.source))
        if let size = result.size { MobileTag(text: size, systemImage: "externaldrive") }
        if let episode = result.parsedDisplayEpisodeLabel { MobileTag(text: episode) }
        if let resolution = result.parsedResolution { MobileTag(text: resolution) }
        if result.isCollectionResource { MobileTag(text: "合集", systemImage: "square.stack.3d.up") }
        if let fansub = result.mikanGroupName ?? result.parsedFansub { MobileTag(text: fansub) }
        MobileSearchTorrentStats(result: result)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    var parts = [result.title]
    if let subtitle = result.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
    if let promotion = MobileSearchPromotionPresentation.label(for: result) { parts.append("优惠 \(promotion)") }
    parts.append("站点 \(store.siteLabel(for: result.source))")
    if let size = result.size { parts.append("体积 \(size)") }
    if let episode = result.parsedDisplayEpisodeLabel { parts.append(episode) }
    if let resolution = result.parsedResolution { parts.append(resolution) }
    if let seeders = result.seeders { parts.append("做种 \(seeders)") }
    if let leechers = result.leechers { parts.append("下载 \(leechers)") }
    if let downloads = result.downloads { parts.append("完成 \(downloads)") }
    return parts.joined(separator: "，")
  }
}

private struct MobileSearchSiteSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(store.searchSites) { site in
          Toggle(site.label, isOn: Binding(
            get: { store.validSelectedSearchSiteIDs.contains(site.id) },
            set: { store.setSearchSite(site.id, selected: $0) }
          ))
        }
      }
      .mobileStatusNavigationTitle("搜索站点")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu("批量选择", systemImage: "checklist") {
            Button("全选") { store.selectAllSearchSites() }
            Button("清空") { store.clearSearchSites() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
            .disabled(store.validSelectedSearchSiteIDs.isEmpty)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct MobileSearchSettingsSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Toggle("搜索结果去重", isOn: $store.searchDeduplicate)
        Toggle("分页搜索", isOn: $store.searchPaginationEnabled)
        if store.searchPaginationEnabled {
          Stepper("每页 \(store.searchPageSize) 条", value: $store.searchPageSize, in: 10...100, step: 10)
        }
      }
      .mobileStatusNavigationTitle("搜索设置")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }
    .presentationDetents([.medium])
  }
}

private struct MobileSearchFilterSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var episodeDraft = ""
  @State private var episodeError: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("字幕组") {
          if store.searchFansubCounts.isEmpty {
            Text("当前结果没有可筛选的字幕组").foregroundStyle(.secondary)
          } else {
            ForEach(store.searchFansubCounts.keys.sorted(), id: \.self) { fansub in
              Toggle(isOn: selectionBinding(fansub)) {
                HStack { Text(fansub); Spacer(); Text("\(store.searchFansubCounts[fansub] ?? 0)").foregroundStyle(.secondary) }
              }
            }
          }
        }
        Section("分辨率") {
          ForEach(SearchResolutionFilter.allCases) { resolution in
            let count = store.searchResolutionCounts[resolution] ?? 0
            if count > 0 {
              Toggle(isOn: resolutionBinding(resolution)) {
                HStack { Text(resolution.title); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
              }
            }
          }
        }
        Section("集数") {
          TextField("例如 12、:12 或 1-12", text: $episodeDraft)
            .keyboardType(.numbersAndPunctuation)
          Toggle("包含未识别集数", isOn: $store.searchShowUnrecognizedEpisodes)
          if let episodeError {
            Text(episodeError).font(.caption).foregroundStyle(.red)
          }
        }
        Section("资源类型") {
          Toggle("仅显示合集", isOn: $store.searchShowBatchOnly)
        }
      }
      .mobileStatusNavigationTitle("筛选")
      .onAppear { episodeDraft = store.searchEpisodeFilter }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("应用") {
            if let normalized = SearchEpisodeFilterParser.normalizedValue(from: episodeDraft) {
              store.searchEpisodeFilter = normalized
              dismiss()
            } else {
              episodeError = "请输入单集或有效范围。"
            }
          }
        }
      }
    }
  }

  private func selectionBinding(_ value: String) -> Binding<Bool> {
    Binding(
      get: { store.selectedSearchFansubs.contains(value) },
      set: { selected in
        if selected { store.selectedSearchFansubs.insert(value) } else { store.selectedSearchFansubs.remove(value) }
      }
    )
  }

  private func resolutionBinding(_ value: SearchResolutionFilter) -> Binding<Bool> {
    Binding(
      get: { store.selectedSearchResolutions.contains(value) },
      set: { selected in
        if selected { store.selectedSearchResolutions.insert(value) } else { store.selectedSearchResolutions.remove(value) }
      }
    )
  }
}

private struct MobileSearchResultDetail: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  var result: SearchResult
  var identify: () -> Void
  var subscribe: () -> Void
  var download: () -> Void

  private var canDownload: Bool {
    MobileSearchDownloadPresentation.isDownloadable(result)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(result.title).font(.headline)
          if let subtitle = result.subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
        Section("资源信息") {
          LabeledContent("站点", value: store.siteLabel(for: result.source))
          if let promotion = MobileSearchPromotionPresentation.label(for: result) {
            LabeledContent("优惠", value: promotion)
          }
          if let freeUntil = result.freeUntil, !freeUntil.isEmpty {
            LabeledContent("优惠截止", value: MobileFormat.date(freeUntil))
          }
          LabeledContent("体积", value: result.size ?? MobileFormat.bytes(result.sizeBytes))
          LabeledContent("发布时间", value: MobileFormat.date(result.publishedAt))
          LabeledContent("字幕组", value: result.mikanGroupName ?? result.parsedFansub ?? "未识别")
          LabeledContent("分辨率", value: result.parsedResolution ?? "未识别")
          LabeledContent("集数", value: result.parsedDisplayEpisodeLabel ?? "未识别")
          if let seeders = result.seeders { LabeledContent("做种", value: seeders.formatted()) }
          if let leechers = result.leechers { LabeledContent("下载", value: leechers.formatted()) }
          if let downloads = result.downloads { LabeledContent("完成", value: downloads.formatted()) }
          if !canDownload {
            Label(MobileSearchDownloadPresentation.unavailableMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
        }
      }
      .mobileStatusNavigationTitle("资源详情")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        ToolbarItemGroup(placement: .bottomBar) {
          Button("识别", systemImage: "sparkles") { dismiss(); identify() }
          Spacer()
          Button("订阅", systemImage: "dot.radiowaves.left.and.right") { dismiss(); subscribe() }
          Spacer()
          Button("下载", systemImage: "arrow.down.circle") { download() }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .disabled(!canDownload)
        }
      }
    }
  }
}

enum MobileSearchDownloadPresentation {
  static let unavailableMessage = "当前资源缺少可下载链接。"

  static func isDownloadable(_ result: SearchResult) -> Bool {
    hasValue(result.magnetUrl) || hasValue(result.downloadUrl)
  }

  private static func hasValue(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

struct MobileSearchDownloadDraft: Identifiable, Hashable {
  var id: String { result.id }
  let result: SearchResult
  var organizeTargetID: Int?

  init(result: SearchResult, defaultTargetID: Int?) {
    self.result = result
    organizeTargetID = defaultTargetID
  }
}

struct MobileSearchDownloadQueue {
  private(set) var result: SearchResult?

  mutating func enqueue(_ result: SearchResult) -> Bool {
    guard MobileSearchDownloadPresentation.isDownloadable(result) else { return false }
    self.result = result
    return true
  }

  mutating func consume(defaultTargetID: Int?) -> MobileSearchDownloadDraft? {
    guard let result else { return nil }
    self.result = nil
    return MobileSearchDownloadDraft(result: result, defaultTargetID: defaultTargetID)
  }
}

struct MobileSearchDownloadSubmissionState {
  private(set) var resultID: String?
  var isSubmitting: Bool { resultID != nil }

  mutating func begin(resultID: String) -> Bool {
    guard self.resultID == nil else { return false }
    self.resultID = resultID
    return true
  }

  mutating func finish() {
    resultID = nil
  }
}

private struct MobileSearchDownloadSheet: View {
  @EnvironmentObject private var store: AppStore
  @State private var draft: MobileSearchDownloadDraft
  @State private var submission = MobileSearchDownloadSubmissionState()
  var organizeTargets: [OrganizeTarget]
  var cancel: () -> Void
  var submit: (MobileSearchDownloadDraft) async -> Bool

  init(
    draft: MobileSearchDownloadDraft,
    organizeTargets: [OrganizeTarget],
    cancel: @escaping () -> Void,
    submit: @escaping (MobileSearchDownloadDraft) async -> Bool
  ) {
    _draft = State(initialValue: draft)
    self.organizeTargets = organizeTargets
    self.cancel = cancel
    self.submit = submit
  }

  private var enabledTargets: [OrganizeTarget] {
    organizeTargets.filter(\.enabled)
  }

  private var selectedTarget: OrganizeTarget? {
    if let id = draft.organizeTargetID {
      return enabledTargets.first { $0.id == id }
    }
    return enabledTargets.first { $0.isDefault } ?? enabledTargets.first
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("资源") {
          LabeledContent("标题") {
            Text(draft.result.title)
              .lineLimit(3)
              .multilineTextAlignment(.trailing)
          }
          LabeledContent("来源", value: store.siteLabel(for: draft.result.source))
          if let size = draft.result.size {
            LabeledContent("大小", value: size)
          }
        }

        Section("整理目标") {
          if enabledTargets.isEmpty {
            ContentUnavailableView(
              "没有可用整理目标",
              systemImage: "folder.badge.plus",
              description: Text("请先到设置中添加并启用整理目标，再提交下载。")
            )
            .frame(maxWidth: .infinity, minHeight: 150)
          } else {
            Picker("下载完成后整理到", selection: $draft.organizeTargetID) {
              Text("使用默认目标").tag(Optional<Int>.none)
              ForEach(enabledTargets) { target in
                Text(target.isDefault ? "\(target.name)（默认）" : target.name)
                  .tag(Optional<Int>.some(target.id))
              }
            }
            if let selectedTarget {
              LabeledContent("实际路径") {
                Text(selectedTarget.path)
                  .lineLimit(2)
                  .multilineTextAlignment(.trailing)
              }
              LabeledContent("用途", value: selectedTarget.mediaType)
            }
          }
        }
      }
      .mobileStatusNavigationTitle("确认下载")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", role: .cancel, action: cancel)
            .disabled(submission.isSubmitting)
            .accessibilityLabel("取消下载")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            guard submission.begin(resultID: draft.result.id) else { return }
            Task {
              if await submit(draft) {
                cancel()
              } else {
                submission.finish()
              }
            }
          } label: {
            if submission.isSubmitting {
              ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
            } else {
              Label("提交下载", systemImage: "arrow.down.circle")
            }
          }
          .disabled(submission.isSubmitting || enabledTargets.isEmpty)
          .accessibilityLabel(submission.isSubmitting ? "正在提交下载" : "提交下载")
          .accessibilityIdentifier("mobile-search-submit-download")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .interactiveDismissDisabled(submission.isSubmitting)
  }
}

enum MobileSearchPromotionPresentation {
  static func label(for result: SearchResult) -> String? {
    label(discountLabel: result.discountLabel, isFree: result.isFree, remaining: result.freeRemaining)
  }

  static func label(discountLabel: String?, isFree: Bool?, remaining: String?) -> String? {
    let discount = discountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeRemaining = remaining?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let discount, !discount.isEmpty {
      if discount.uppercased() == "FREE", let timeRemaining, !timeRemaining.isEmpty {
        return "\(discount) \(timeRemaining)"
      }
      return discount
    }
    guard isFree == true else { return nil }
    if let timeRemaining, !timeRemaining.isEmpty { return "FREE \(timeRemaining)" }
    return "FREE"
  }

  static func isFree(_ label: String) -> Bool {
    label.uppercased().contains("FREE")
  }
}

enum MobileSearchPaginationPresentation {
  static func isVisible(paginationEnabled: Bool, canGoPrevious: Bool, canGoNext: Bool) -> Bool {
    paginationEnabled && (canGoPrevious || canGoNext)
  }
}

private struct MobileSearchPromotionBadge: View {
  var result: SearchResult

  var body: some View {
    if let label = MobileSearchPromotionPresentation.label(for: result) {
      let color: Color = MobileSearchPromotionPresentation.isFree(label) ? .green : .orange
      Text(label)
        .font(.caption.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel("优惠状态 \(label)")
    }
  }
}

private struct MobileSearchTorrentStats: View {
  var result: SearchResult

  private var values: [String] {
    [
      result.seeders.map { "做种 \($0.formatted())" },
      result.leechers.map { "下载 \($0.formatted())" },
      result.downloads.map { "完成 \($0.formatted())" },
    ].compactMap { $0 }
  }

  var body: some View {
    if !values.isEmpty {
      Text(values.joined(separator: " · "))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }
  }
}

struct MobileMetadataReviewSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var candidates: [MetadataCandidate] = []
  @State private var selectedID: String?
  @State private var isSearching = false
  @State private var searchError: String?
  @State private var searchSequence = LatestOperationSequence()
  @State private var searchTask: Task<Void, Never>?
  @State private var submittedQuery = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            TextField("搜索作品名称", text: $query)
              .submitLabel(.search)
              .onSubmit { search() }
              .onChange(of: query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != submittedQuery { cancelSearch() }
              }
            Button("搜索", systemImage: "magnifyingglass", action: search)
              .labelStyle(.iconOnly)
              .frame(width: 44, height: 44)
              .buttonStyle(.borderless)
              .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        if isSearching {
          ProgressView("正在搜索").frame(maxWidth: .infinity)
        } else if let searchError {
          Label(searchError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        } else if candidates.isEmpty {
          ContentUnavailableView("没有候选", systemImage: "magnifyingglass")
        }
        ForEach(candidates) { candidate in
        Button {
          selectedID = candidate.id
        } label: {
          HStack(spacing: 12) {
            MobilePosterImage(url: candidate.posterUrl.flatMap(URL.init(string:)), width: 54, height: 78)
            VStack(alignment: .leading, spacing: 4) {
              Text(candidate.title).font(.headline).foregroundStyle(.primary)
              Text([candidate.airDate.map { String($0.prefix(4)) }, candidate.mediaType == "movie" ? "电影" : "剧集", candidate.source.uppercased()].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.metadataBindingCandidateID == candidate.id { ProgressView() }
            else if selectedID == candidate.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
          }
        }
        .buttonStyle(.plain)
        .disabled(store.metadataBindingCandidateID != nil)
        .accessibilityAddTraits(selectedID == candidate.id ? .isSelected : [])
        }
      }
      .disabled(store.metadataBindingCandidateID != nil)
      .mobileStatusNavigationTitle("确认番剧信息")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { cancelSearch(); store.showingMetadataReview = false; dismiss() }
            .disabled(store.metadataBindingCandidateID != nil)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("确认") {
            guard let candidate = candidates.first(where: { $0.id == selectedID }) else { return }
            Task { await store.bind(candidate) }
          }
          .disabled(selectedID == nil || isSearching || store.metadataBindingCandidateID != nil)
        }
      }
    }
    .interactiveDismissDisabled(store.metadataBindingCandidateID != nil)
    .onAppear {
      query = store.metadataQuery
      candidates = store.metadataCandidates
      if candidates.isEmpty { search() }
    }
    .onDisappear { cancelSearch() }
  }

  private func cancelSearch() {
    _ = searchSequence.begin()
    searchTask?.cancel()
    isSearching = false
  }

  private func search() {
    let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else { return }
    searchTask?.cancel()
    submittedQuery = keyword
    let operationID = searchSequence.begin()
    isSearching = true
    searchError = nil
    searchTask = Task {
      do {
        let response = try await store.client.metadataSearch(query: keyword)
        guard !Task.isCancelled, searchSequence.accepts(operationID) else { return }
        guard !response.candidates.isEmpty else {
          searchError = response.warnings.first ?? "没有找到匹配作品，请换个名称搜索。"
          isSearching = false
          return
        }
        candidates = response.candidates
        if !candidates.contains(where: { $0.id == selectedID }) { selectedID = nil }
        isSearching = false
      } catch {
        guard !Task.isCancelled, searchSequence.accepts(operationID) else { return }
        searchError = error.localizedDescription
        isSearching = false
      }
    }
  }
}
