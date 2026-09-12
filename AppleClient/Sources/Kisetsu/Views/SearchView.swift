import SwiftUI

struct SearchView: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingSubscriptionEditor = false
  @State private var showingSearchSettings = false
  @State private var showingSearchSites = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          TextField("番剧关键词", text: $store.searchKeyword)
            .textFieldStyle(.roundedBorder)
            .layoutPriority(1)
            .onSubmit {
              Task { await store.performSearch() }
            }

          SearchCommandControl(
            showingSitePicker: $showingSearchSites,
            search: { Task { await store.performSearch() } }
          )

          Button {
            store.clearSearch()
          } label: {
            Image(systemName: "xmark.circle")
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.borderless)
          .help("清空搜索")
          .accessibilityLabel("清空搜索")

          Button {
            showingSearchSettings.toggle()
          } label: {
            Image(systemName: "gearshape")
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.borderless)
          .help("搜索设置")
          .accessibilityLabel("搜索设置")
          .popover(isPresented: $showingSearchSettings, arrowEdge: .top) {
            SearchSettingsPopover()
              .environmentObject(store)
          }
        }

        searchSiteAvailability

        if !searchIssueMessages.isEmpty {
          SearchIssueStrip(messages: searchIssueMessages)
        }
      }
      .appToolbarSurface()

      if store.searchResults.isEmpty {
        ContentUnavailableView("暂无搜索结果", systemImage: "magnifyingglass", description: Text(emptySearchDescription))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: 0) {
          SearchFilterStrip(
            fansubCounts: store.searchFansubCounts,
            selectedFansubs: $store.selectedSearchFansubs,
            episodeFilter: $store.searchEpisodeFilter,
            showUnrecognized: $store.searchShowUnrecognizedEpisodes,
            showBatchOnly: $store.searchShowBatchOnly,
            resolutionCounts: store.searchResolutionCounts,
            selectedResolutions: $store.selectedSearchResolutions,
            shownCount: store.visibleSearchResults.count,
            totalCount: store.searchResults.count,
            isFiltering: store.searchFiltering,
            hasActiveFilters: store.searchHasActiveFilters
          )
          .padding(.horizontal, KisetsuStyle.pagePadding)
          .padding(.vertical, 10)

          if store.visibleSearchResults.isEmpty {
            ContentUnavailableView("没有符合筛选的结果", systemImage: "line.3.horizontal.decrease.circle", description: Text("调整字幕组、分辨率或集数筛选后会立即恢复显示。"))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
          List(store.visibleSearchResults) { result in
            SearchResultRow(result: result) {
              suggestSubscription(from: result)
            }
          }
          }
        }
      }

      if store.searchPaginationEnabled, store.searchDiagnostics != nil {
        Divider()
        SearchPaginationBar(
          summary: store.searchPaginationSummaryText,
          canGoPrevious: store.searchCanGoToPreviousPage,
          canGoNext: store.searchCanGoToNextPage,
          isLoading: store.isLoading,
          previous: {
            Task { await store.performPreviousSearchPage() }
          },
          next: {
            Task { await store.performNextSearchPage() }
          }
        )
      }
    }
    .sheet(isPresented: $showingSubscriptionEditor) {
      SubscriptionEditorSheet {
        showingSubscriptionEditor = false
      }
    }
    .onChange(of: showingSubscriptionEditor) { _, isShowing in
      guard !isShowing else { return }
      Task { await store.runPendingMetadataRecognitionIfNeeded() }
    }
    .onChange(of: store.searchKeyword) { _, _ in
      store.resetSearchPagination()
    }
    .onChange(of: store.selectedSearchSiteIDs) { _, _ in
      store.resetSearchPagination()
    }
    .onChange(of: store.searchPaginationEnabled) { _, _ in
      store.resetSearchPagination()
    }
  }

  private var emptySearchDescription: String {
    if searchIssueMessages.isEmpty {
      return "当前没有可展示的资源。"
    }
    return "搜索没有返回可展示的资源，请查看上方提示。"
  }

  @ViewBuilder
  private var searchSiteAvailability: some View {
    if store.sites.isEmpty {
      Label("站点列表未加载", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
      Button {
        Task { await store.loadSites() }
      } label: {
        Label("重试加载站点", systemImage: "arrow.clockwise")
      }
      .controlSize(.small)
    } else if store.searchSites.isEmpty {
      Label("没有可用于普通搜索的站点", systemImage: "powerplug")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if store.validSelectedSearchSiteIDs.isEmpty {
      Label("请至少选择一个站点", systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  private var searchIssueMessages: [String] {
    var messages = store.searchWarnings.map(StatusLabels.message)
    if let diagnostics = store.searchDiagnostics {
      for diagnostic in diagnostics.siteDiagnostics {
        if let error = diagnostic.error {
          messages.append("\(store.siteLabel(for: diagnostic.site))：\(StatusLabels.message(error))")
        }
        messages.append(contentsOf: diagnostic.warnings.map {
          "\(store.siteLabel(for: diagnostic.site))：\(StatusLabels.message($0))"
        })
      }
      if diagnostics.reachedInternalSafetyLimit {
        messages.append("结果较多，搜索已在安全上限停止。")
      }
    }

    var seen: Set<String> = []
    return messages.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private func suggestSubscription(from result: SearchResult) {
    Task {
      if let response = await store.suggestSubscription(
        from: result,
        sitesOverride: Array(store.validSelectedSearchSiteIDs).sorted()
      ),
         let suggestion = response.suggestion {
        store.prepareSubscriptionForm(
          from: response,
          suggestion: suggestion,
          result: result,
          availableFansubs: store.smartSubscriptionFansubs(for: result, among: store.searchResults)
        )
        showingSubscriptionEditor = true
      }
    }
  }
}

private struct SearchCommandControl: View {
  @EnvironmentObject private var store: AppStore
  @Binding var showingSitePicker: Bool
  var search: () -> Void

  private var canSearch: Bool {
    !store.isLoading
      && !store.searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !store.validSelectedSearchSiteIDs.isEmpty
  }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: search) {
        HStack(spacing: 7) {
          if store.isLoading {
            ProgressView()
              .controlSize(.small)
              .tint(.secondary)
          } else {
            Image(systemName: "magnifyingglass")
          }
          Text(store.isLoading ? "搜索中..." : "搜索资源")
            .lineLimit(1)
        }
        .frame(width: 112, height: 32)
        .contentShape(Rectangle())
        .foregroundStyle(canSearch ? Color.primary : Color.secondary)
      }
      .buttonStyle(.plain)
      .disabled(!canSearch)
      .help("搜索资源")
      .accessibilityLabel("搜索资源")

      Rectangle()
        .fill(Color.primary.opacity(0.10))
        .frame(width: 1, height: 18)

      Button {
        showingSitePicker.toggle()
      } label: {
        HStack(spacing: 5) {
          Text(store.searchSiteSelectionSummary)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
        }
        .frame(width: 110, height: 32)
        .contentShape(Rectangle())
        .foregroundStyle(store.searchSites.isEmpty ? Color.secondary : Color.primary)
      }
      .buttonStyle(.plain)
      .disabled(store.searchSites.isEmpty)
      .help("选择搜索站点")
      .accessibilityLabel("选择搜索站点，已选择 \(store.validSelectedSearchSiteIDs.count) 个站点")
      .popover(isPresented: $showingSitePicker, arrowEdge: .top) {
        SearchSitePickerPopover()
          .environmentObject(store)
      }
    }
    .font(.callout.weight(.semibold))
    .background(
      Color.primary.opacity(0.055),
      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
    }
    .fixedSize()
  }
}

private struct SearchSettingsPopover: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("搜索设置", systemImage: "gearshape")
        .font(.headline)

      Toggle("搜索结果去重", isOn: $store.searchDeduplicate)
        .help("合并相同磁链或相同资源。")

      Toggle("分页搜索", isOn: $store.searchPaginationEnabled)
        .help("每次仅搜索当前页，并显示上一页与下一页。")

      Text(store.searchPaginationEnabled ? "每个站点每次请求一页" : "自动搜索全部可访问结果")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 270, alignment: .leading)
    .foregroundStyle(Color.primary)
    .accessibilityElement(children: .contain)
  }
}

private struct SearchSitePickerPopover: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("搜索站点", systemImage: "checklist")
          .font(.headline)
        Spacer()
        Text("\(store.validSelectedSearchSiteIDs.count) / \(store.searchSites.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Button("全选") {
          store.selectAllSearchSites()
        }
        .disabled(store.validSelectedSearchSiteIDs == store.searchSiteIDs)

        Button("清空") {
          store.clearSearchSites()
        }
        .disabled(store.validSelectedSearchSiteIDs.isEmpty)
      }
      .controlSize(.small)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 9) {
          ForEach(store.searchSites) { site in
            Toggle(site.label, isOn: Binding {
              store.validSelectedSearchSiteIDs.contains(site.id)
            } set: { selected in
              store.setSearchSite(site.id, selected: selected)
            })
            .toggleStyle(.checkbox)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)

      if store.validSelectedSearchSiteIDs.isEmpty {
        Label("请至少选择一个站点", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .padding(16)
    .frame(width: 270, alignment: .leading)
    .foregroundStyle(Color.primary)
    .accessibilityElement(children: .contain)
  }
}

private struct SearchPaginationBar: View {
  var summary: String
  var canGoPrevious: Bool
  var canGoNext: Bool
  var isLoading: Bool
  var previous: () -> Void
  var next: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: previous) {
        Image(systemName: "chevron.left")
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .disabled(!canGoPrevious)
      .help("上一页")

      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      if isLoading {
        ProgressView()
          .controlSize(.small)
      }

      Button(action: next) {
        Image(systemName: "chevron.right")
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .disabled(!canGoNext)
      .help("下一页")
    }
    .frame(maxWidth: .infinity)
    .frame(height: 42)
    .padding(.horizontal, KisetsuStyle.pagePadding)
    .background(.bar)
  }
}

enum SearchFilterPresentation {
  static func fansubSummary(_ selected: Set<String>) -> String {
    if selected.isEmpty { return "全部字幕组" }
    if selected.count == 1 { return selected.first ?? "全部字幕组" }
    return "\(selected.count) 个字幕组"
  }

  static func resolutionSummary(_ selected: Set<SearchResolutionFilter>) -> String {
    if selected.isEmpty { return "全部分辨率" }
    if selected.count == 1 { return selected.first?.title ?? "全部分辨率" }
    return "\(selected.count) 种分辨率"
  }

  static func episodeSummary(_ value: String, showUnrecognized: Bool) -> String {
    if showUnrecognized { return "未识别集数" }
    guard let range = SearchEpisodeFilterParser.range(from: value) else { return "全部集数" }
    if range.lowerBound == range.upperBound {
      return "第 \(range.lowerBound) 集"
    }
    return "第 \(range.lowerBound)-\(range.upperBound) 集"
  }

  static func resourceSummary(showBatchOnly: Bool) -> String {
    showBatchOnly ? "仅合集" : "全部资源"
  }

  static func resultSummary(shown: Int, total: Int) -> String {
    shown == total ? "\(total) 个结果" : "\(shown) / \(total) 个结果"
  }
}

private enum SearchFilterPopover: Hashable {
  case fansub
  case resolution
  case episode
  case resource
}

private struct SearchFilterStrip: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var fansubCounts: [String: Int]
  @Binding var selectedFansubs: Set<String>
  @Binding var episodeFilter: String
  @Binding var showUnrecognized: Bool
  @Binding var showBatchOnly: Bool
  var resolutionCounts: [SearchResolutionFilter: Int]
  @Binding var selectedResolutions: Set<SearchResolutionFilter>
  var shownCount: Int
  var totalCount: Int
  var isFiltering: Bool
  var hasActiveFilters: Bool
  @State private var activePopover: SearchFilterPopover?

  private var availableFansubs: [String] {
    fansubCounts.keys.sorted()
  }

  private var availableResolutions: [SearchResolutionFilter] {
    SearchResolutionFilter.allCases.filter { resolutionCounts[$0, default: 0] > 0 }
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        filterButton(.fansub)
        filterButton(.resolution)
        filterButton(.episode)
        filterButton(.resource)
        Spacer(minLength: 8)
        resultStatus
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          filterButton(.fansub)
          filterButton(.resolution)
          Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
          filterButton(.episode)
          filterButton(.resource)
          Spacer(minLength: 8)
          resultStatus
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        filterButton(.fansub)
        filterButton(.resolution)
        filterButton(.episode)
        filterButton(.resource)
        resultStatus
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func filterButton(_ popover: SearchFilterPopover) -> some View {
    let title = title(for: popover)
    SearchFilterButton(
      title: title,
      systemImage: symbol(for: popover),
      width: width(for: popover),
      isActive: isActive(popover),
      reduceMotion: reduceMotion
    ) {
      activePopover = activePopover == popover ? nil : popover
    }
    .help(helpText(for: popover))
    .accessibilityLabel(accessibilityLabel(for: popover))
    .accessibilityValue(title)
    .popover(isPresented: popoverBinding(for: popover), arrowEdge: .bottom) {
      popoverContent(for: popover)
    }
  }

  private var resultStatus: some View {
    HStack(spacing: 7) {
      if isFiltering {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在筛选")
      }
      Text(SearchFilterPresentation.resultSummary(shown: shownCount, total: totalCount))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)

      if hasActiveFilters {
        Button {
          resetFilters()
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help("重置筛选")
        .accessibilityLabel("重置全部筛选")
      }
    }
    .fixedSize()
  }

  @ViewBuilder
  private func popoverContent(for popover: SearchFilterPopover) -> some View {
    switch popover {
    case .fansub:
      SearchFansubFilterPopover(
        fansubs: availableFansubs,
        counts: fansubCounts,
        selection: $selectedFansubs
      )
    case .resolution:
      SearchResolutionFilterPopover(
        resolutions: availableResolutions,
        counts: resolutionCounts,
        selection: $selectedResolutions
      )
    case .episode:
      SearchEpisodeFilterPopover(
        currentValue: episodeFilter,
        currentShowUnrecognized: showUnrecognized,
        clear: {
          episodeFilter = ""
          showUnrecognized = false
          activePopover = nil
        },
        apply: { value, unrecognized in
          episodeFilter = value
          showUnrecognized = unrecognized
          activePopover = nil
        }
      )
    case .resource:
      SearchResourceFilterPopover(
        showBatchOnly: $showBatchOnly,
        dismiss: { activePopover = nil }
      )
    }
  }

  private func title(for popover: SearchFilterPopover) -> String {
    switch popover {
    case .fansub: SearchFilterPresentation.fansubSummary(selectedFansubs)
    case .resolution: SearchFilterPresentation.resolutionSummary(selectedResolutions)
    case .episode: SearchFilterPresentation.episodeSummary(episodeFilter, showUnrecognized: showUnrecognized)
    case .resource: SearchFilterPresentation.resourceSummary(showBatchOnly: showBatchOnly)
    }
  }

  private func symbol(for popover: SearchFilterPopover) -> String {
    switch popover {
    case .fansub: "captions.bubble"
    case .resolution: "display"
    case .episode: "number"
    case .resource: "square.stack.3d.up"
    }
  }

  private func width(for popover: SearchFilterPopover) -> CGFloat {
    switch popover {
    case .fansub: 150
    case .resolution: 144
    case .episode: 126
    case .resource: 116
    }
  }

  private func isActive(_ popover: SearchFilterPopover) -> Bool {
    switch popover {
    case .fansub: !selectedFansubs.isEmpty
    case .resolution: !selectedResolutions.isEmpty
    case .episode: !episodeFilter.isEmpty || showUnrecognized
    case .resource: showBatchOnly
    }
  }

  private func helpText(for popover: SearchFilterPopover) -> String {
    switch popover {
    case .fansub: "筛选字幕组"
    case .resolution: "筛选分辨率"
    case .episode: "筛选集数"
    case .resource: "筛选普通资源或合集"
    }
  }

  private func accessibilityLabel(for popover: SearchFilterPopover) -> String {
    switch popover {
    case .fansub: "字幕组筛选"
    case .resolution: "分辨率筛选"
    case .episode: "集数筛选"
    case .resource: "资源类型筛选"
    }
  }

  private func popoverBinding(for popover: SearchFilterPopover) -> Binding<Bool> {
    Binding {
      activePopover == popover
    } set: { isPresented in
      if isPresented {
        activePopover = popover
      } else if activePopover == popover {
        activePopover = nil
      }
    }
  }

  private func resetFilters() {
    activePopover = nil
    selectedFansubs = []
    episodeFilter = ""
    showUnrecognized = false
    showBatchOnly = false
    selectedResolutions = []
  }
}

private struct SearchFilterButton: View {
  var title: String
  var systemImage: String
  var width: CGFloat
  var isActive: Bool
  var reduceMotion: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .frame(width: 15)
        Text(title)
          .lineLimit(1)
          .truncationMode(.tail)
          .contentTransition(.opacity)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: title)
        Spacer(minLength: 2)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .frame(width: width, height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(SearchFilterButtonStyle(isActive: isActive, reduceMotion: reduceMotion))
  }
}

private struct SearchFilterButtonStyle: ButtonStyle {
  var isActive: Bool
  var reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption.weight(.medium))
      .foregroundStyle(isActive ? Color.accentColor : Color.primary)
      .padding(.horizontal, 9)
      .background(
        isActive ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.045),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(
            isActive ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.09),
            lineWidth: 0.6
          )
      }
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

private struct SearchFansubFilterPopover: View {
  var fansubs: [String]
  var counts: [String: Int]
  @Binding var selection: Set<String>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("字幕组", systemImage: "captions.bubble")
          .font(.headline)
        Spacer()
        Text("\(selection.count) / \(fansubs.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Button("全选") { selection = Set(fansubs) }
          .disabled(selection == Set(fansubs))
        Button("清除") { selection = [] }
          .disabled(selection.isEmpty)
      }
      .controlSize(.small)

      Divider()

      if fansubs.isEmpty {
        Text("当前结果未识别到字幕组")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 9) {
            ForEach(fansubs, id: \.self) { fansub in
              Toggle(isOn: selectionBinding(for: fansub)) {
                HStack(spacing: 10) {
                  Text(fansub)
                    .lineLimit(1)
                  Spacer()
                  Text("\(counts[fansub, default: 0])")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              .toggleStyle(.checkbox)
            }
          }
        }
        .frame(maxHeight: 280)
      }
    }
    .padding(16)
    .frame(width: 280, alignment: .leading)
    .foregroundStyle(Color.primary)
    .accessibilityElement(children: .contain)
  }

  private func selectionBinding(for fansub: String) -> Binding<Bool> {
    Binding {
      selection.contains(fansub)
    } set: { selected in
      if selected {
        selection.insert(fansub)
      } else {
        selection.remove(fansub)
      }
    }
  }
}

private struct SearchResolutionFilterPopover: View {
  var resolutions: [SearchResolutionFilter]
  var counts: [SearchResolutionFilter: Int]
  @Binding var selection: Set<SearchResolutionFilter>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("分辨率", systemImage: "display")
          .font(.headline)
        Spacer()
        Text("\(selection.count) / \(resolutions.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Button("全选") { selection = Set(resolutions) }
          .disabled(selection == Set(resolutions))
        Button("清除") { selection = [] }
          .disabled(selection.isEmpty)
      }
      .controlSize(.small)

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        ForEach(resolutions) { resolution in
          Toggle(isOn: selectionBinding(for: resolution)) {
            HStack(spacing: 10) {
              Text(resolution.title)
              Spacer()
              Text("\(counts[resolution, default: 0])")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
        }
      }
    }
    .padding(16)
    .frame(width: 250, alignment: .leading)
    .foregroundStyle(Color.primary)
    .accessibilityElement(children: .contain)
  }

  private func selectionBinding(for resolution: SearchResolutionFilter) -> Binding<Bool> {
    Binding {
      selection.contains(resolution)
    } set: { selected in
      if selected {
        selection.insert(resolution)
      } else {
        selection.remove(resolution)
      }
    }
  }
}

private struct SearchEpisodeFilterPopover: View {
  private let currentValue: String
  var clear: () -> Void
  var apply: (String, Bool) -> Void
  @State private var draft: String
  @State private var showUnrecognized: Bool

  init(
    currentValue: String,
    currentShowUnrecognized: Bool,
    clear: @escaping () -> Void,
    apply: @escaping (String, Bool) -> Void
  ) {
    self.currentValue = currentValue
    self.clear = clear
    self.apply = apply
    _draft = State(initialValue: currentValue)
    _showUnrecognized = State(initialValue: currentShowUnrecognized)
  }

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedDraft: String? {
    SearchEpisodeFilterParser.normalizedValue(from: trimmedDraft)
  }

  private var validationMessage: String? {
    guard !showUnrecognized, !trimmedDraft.isEmpty, normalizedDraft == nil else { return nil }
    return "请输入单集或有效范围，例如 12、:12 或 1-12。"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("集数", systemImage: "number")
        .font(.headline)

      TextField("12 或 1-12", text: $draft)
        .textFieldStyle(.roundedBorder)
        .disabled(showUnrecognized)
        .onSubmit(applyDraft)

      Toggle("未识别集数", isOn: $showUnrecognized)
        .toggleStyle(.checkbox)

      if let validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("清除", action: clear)
        Spacer()
        Button("应用", action: applyDraft)
          .keyboardShortcut(.defaultAction)
          .disabled(!showUnrecognized && normalizedDraft == nil)
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: 280, alignment: .leading)
    .foregroundStyle(Color.primary)
    .accessibilityElement(children: .contain)
  }

  private func applyDraft() {
    if showUnrecognized {
      apply(currentValue, true)
      return
    }
    guard let normalizedDraft else { return }
    apply(normalizedDraft, false)
  }
}

private struct SearchResourceFilterPopover: View {
  @Binding var showBatchOnly: Bool
  var dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("资源类型", systemImage: "square.stack.3d.up")
        .font(.headline)
        .padding(.bottom, 4)

      choiceRow(title: "全部资源", selected: !showBatchOnly) {
        showBatchOnly = false
        dismiss()
      }
      choiceRow(title: "仅合集", selected: showBatchOnly) {
        showBatchOnly = true
        dismiss()
      }
    }
    .padding(12)
    .frame(width: 210, alignment: .leading)
    .foregroundStyle(Color.primary)
    .accessibilityElement(children: .contain)
  }

  private func choiceRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        Image(systemName: "checkmark")
          .opacity(selected ? 1 : 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 7)
    .frame(height: 30)
    .background(selected ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
  }
}

private extension SearchResult {
  var episodeLabel: String? {
    if let label = parsedDisplayEpisodeLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
      return label
    }
    if parsedIsBatch == true, let start = parsedEpisodeStart, let end = parsedEpisodeEnd {
      return "合集 \(start)–\(max(start, end))"
    }
    if let episode = parsedEpisode {
      return String(format: "第 %02d 集", episode)
    }
    if let start = parsedEpisodeStart, let end = parsedEpisodeEnd {
      return String(format: "第 %02d-%02d 集", start, max(start, end))
    }
    if let start = parsedEpisodeStart {
      return String(format: "第 %02d 集起", start)
    }
    return nil
  }

  func matchesEpisode(_ range: ClosedRange<Int>) -> Bool {
    if let start = parsedEpisodeStart, let end = parsedEpisodeEnd {
      return range.overlaps(start...max(start, end))
    }
    if let episode = parsedEpisode {
      return range.contains(episode)
    }
    if let start = parsedEpisodeStart {
      return range.contains(start)
    }
    return false
  }
}

private struct SearchIssueStrip: View {
  var messages: [String]
  @State private var showingDetails = false

  var body: some View {
    Button {
      showingDetails.toggle()
    } label: {
      Label("\(messages.count) 项搜索提示", systemImage: "exclamationmark.triangle")
        .font(.caption.weight(.medium))
        .foregroundStyle(.orange)
    }
    .buttonStyle(.borderless)
    .help("查看搜索提示")
    .accessibilityLabel("查看 \(messages.count) 项搜索提示")
    .popover(isPresented: $showingDetails, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 10) {
        Label("搜索提示", systemImage: "exclamationmark.triangle")
          .font(.headline)
          .foregroundStyle(.orange)
        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
          Text(message)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
      .frame(width: 360, alignment: .leading)
      .foregroundStyle(Color.primary)
      .accessibilityElement(children: .contain)
    }
  }
}

struct SearchResultRow: View {
  @EnvironmentObject private var store: AppStore
  @State private var downloadDraft: SearchDownloadDraft?
  var result: SearchResult
  var suggestSubscription: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(result.title)
            .font(.headline)
            .lineLimit(2)
          SearchFreeBadge(result: result)
        }
        if let subtitle = result.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty, subtitle != result.title {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack {
          SearchSourceBadge(label: store.siteLabel(for: result.source))
          if let size = result.size {
            Text(size)
          }
          if let publishedAt = result.publishedAt {
            Text(publishedAt)
          }
          SearchTorrentStats(result: result)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if !parsedBadges.isEmpty {
          HStack(spacing: 6) {
            ForEach(parsedBadges, id: \.self) { badge in
              Text(badge)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
          }
          .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Button {
        Task { await store.matchMetadata(for: result) }
      } label: {
        Label("识别番剧", systemImage: "film.stack")
      }
      .disabled(store.isLoading)
      .help("用 Bangumi/TMDB 匹配这条资源")

      Button {
        suggestSubscription()
      } label: {
        HStack(spacing: 6) {
          if store.smartSubscriptionPreparingResultID == result.id {
            ProgressView()
              .controlSize(.small)
            Text("检查中")
          } else {
            Label("智能订阅", systemImage: "sparkles")
          }
        }
        .frame(minWidth: 82)
      }
      .disabled(store.isLoading)
      .help("从这条资源智能提取订阅规则")

      Button {
        downloadDraft = SearchDownloadDraft(result: result, defaultTargetID: store.defaultOrganizeTarget?.id)
      } label: {
        Label("添加到下载", systemImage: "arrow.down.circle")
      }
      .disabled(store.isLoading)
      .help("选择整理目标后提交 magnet/torrent 到手动下载器")

      if let detailURL = result.detailUrl, let url = URL(string: detailURL) {
        Link(destination: url) {
          Label("查看详情", systemImage: "safari")
        }
      }
    }
    .padding(.vertical, 6)
    .controlSize(.small)
    .sheet(item: $downloadDraft) { draft in
      SearchDownloadSheet(
        draft: draft,
        organizeTargets: store.organizeTargets,
        isLoading: store.isLoading,
        cancel: {
          downloadDraft = nil
        },
        submit: { payload in
          Task {
            if await store.addDownload(payload.result, organizeTargetID: payload.organizeTargetID) {
              downloadDraft = nil
            }
          }
        }
      )
    }
  }

  private var parsedBadges: [String] {
    var badges: [String] = []
    if let fansub = result.parsedFansub?.trimmingCharacters(in: .whitespacesAndNewlines), !fansub.isEmpty {
      badges.append("字幕组 \(fansub)")
    }
    if let episodeLabel = result.episodeLabel {
      badges.append(episodeLabel)
    } else if result.isCollectionResource {
      badges.append("合集")
    }
    if let season = result.parsedSeasonNumber {
      badges.append("第 \(season) 季")
    }
    if let part = result.parsedPartNumber {
      badges.append("第 \(part) 部分")
    }
    if let resolution = result.parsedResolution?.trimmingCharacters(in: .whitespacesAndNewlines), !resolution.isEmpty {
      badges.append(resolution)
    }
    if let category = result.category?.trimmingCharacters(in: .whitespacesAndNewlines), isReadableMetadataBadge(category) {
      badges.append(category)
    }
    if let language = result.language?.trimmingCharacters(in: .whitespacesAndNewlines), isReadableMetadataBadge(language) {
      badges.append(language)
    }
    return badges
  }

  private func isReadableMetadataBadge(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.range(of: #"^\d+$"#, options: .regularExpression) == nil
  }
}

private struct SearchSourceBadge: View {
  var label: String

  var body: some View {
    Text(label)
      .font(.caption.weight(.medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.10), in: Capsule())
  }
}

private struct SearchTorrentStats: View {
  var result: SearchResult

  private var items: [SearchTorrentStatItem] {
    [
      result.seeders.map { SearchTorrentStatItem(label: "做种", value: $0, color: .green.opacity(0.65)) },
      result.leechers.map { SearchTorrentStatItem(label: "下载", value: $0, color: .blue.opacity(0.50)) },
      result.downloads.map { SearchTorrentStatItem(label: "完成", value: $0, color: .secondary.opacity(0.55)) }
    ].compactMap { $0 }
  }

  var body: some View {
    if !items.isEmpty {
      HStack(spacing: 7) {
        ForEach(items) { item in
          HStack(spacing: 4) {
            Circle()
              .fill(item.color)
              .frame(width: 4, height: 4)
            Text(item.label)
            Text(item.formattedValue)
          }
          .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(Color.secondary.opacity(0.10), in: Capsule())
    }
  }
}

private struct SearchTorrentStatItem: Identifiable {
  let label: String
  let value: Int
  let color: Color

  var id: String { label }
  var formattedValue: String { value.formatted() }
}

private struct SearchFreeBadge: View {
  var result: SearchResult

  private var label: String? {
    if let discount = result.discountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !discount.isEmpty {
      if let remaining = result.freeRemaining?.trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty, discount.uppercased() == "FREE" {
        return "\(discount) \(remaining)"
      }
      return discount
    }
    if result.isFree == true {
      if let remaining = result.freeRemaining?.trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty {
        return "FREE \(remaining)"
      }
      return "FREE"
    }
    return nil
  }

  private var color: Color {
    label?.uppercased().contains("FREE") == true ? .green : .orange
  }

  var body: some View {
    if let label {
      Text(label)
        .font(.caption.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
  }
}

private struct SearchDownloadDraft: Identifiable {
  let id = UUID()
  let result: SearchResult
  var organizeTargetID: Int?

  init(result: SearchResult, defaultTargetID: Int?) {
    self.result = result
    organizeTargetID = defaultTargetID
  }
}

private struct SearchDownloadSheet: View {
  @EnvironmentObject private var store: AppStore
  @State private var draft: SearchDownloadDraft
  var organizeTargets: [OrganizeTarget]
  var isLoading: Bool
  var cancel: () -> Void
  var submit: (SearchDownloadDraft) -> Void

  init(
    draft: SearchDownloadDraft,
    organizeTargets: [OrganizeTarget],
    isLoading: Bool,
    cancel: @escaping () -> Void,
    submit: @escaping (SearchDownloadDraft) -> Void
  ) {
    _draft = State(initialValue: draft)
    self.organizeTargets = organizeTargets
    self.isLoading = isLoading
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
    VStack(spacing: 0) {
      Form {
        Section("资源") {
          LabeledContent("标题") {
            Text(draft.result.title)
              .lineLimit(3)
              .multilineTextAlignment(.trailing)
          }
          LabeledContent("来源") {
            Text(store.siteLabel(for: draft.result.source))
          }
          if let size = draft.result.size {
            LabeledContent("大小") {
              Text(size)
            }
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
            if let target = selectedTarget {
              LabeledContent("实际路径") {
                Text(target.path)
                  .lineLimit(2)
                  .multilineTextAlignment(.trailing)
                  .textSelection(.enabled)
              }
              LabeledContent("用途") {
                Text(target.mediaType)
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Button("取消", role: .cancel) {
          cancel()
        }
        Spacer()
        Button {
          submit(draft)
        } label: {
          Label("提交下载", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading || enabledTargets.isEmpty)
      }
      .padding()
    }
    .frame(minWidth: 560, idealWidth: 600, minHeight: 430)
  }
}
