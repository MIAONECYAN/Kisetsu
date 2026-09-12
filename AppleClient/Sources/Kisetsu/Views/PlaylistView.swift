import Foundation
import CoreGraphics
import ImageIO
import SwiftUI

enum PlaylistPageMode: String, CaseIterable, Identifiable {
  case existing
  case generate

  var id: String { rawValue }
  var title: String { self == .existing ? "现有播放列表" : "番组信息" }
}

enum PlaylistMatchFilter: String, CaseIterable, Identifiable {
  case all
  case matched
  case unmatched

  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "全部"
    case .matched: "已配对"
    case .unmatched: "未配对"
    }
  }
}

@MainActor
final class PlaylistViewModel: ObservableObject {
  @Published var mode: PlaylistPageMode = .existing
  @Published var quarters: [PlaylistQuarterOption] = []
  @Published var selectedYear = 0
  @Published var selectedMonth = 1
  @Published var quarter: PlaylistQuarterResponse?
  @Published var matchFilter: PlaylistMatchFilter = .all
  @Published var search = SubscriptionSearchPresentationState()
  @Published var selectedItemKeys: Set<String> = []
  @Published var hierarchies: [String: PlexShowHierarchy] = [:]
  @Published var hierarchyLoadingKeys: Set<String> = []
  @Published var hierarchyErrors: [String: String] = [:]
  @Published var selectedSeasons: [String: Int] = [:]
  @Published var selectedEpisodes: [String: String] = [:]
  @Published var playlists: [PlexPlaylistSummary] = []
  @Published var playlistDetail: PlexPlaylistDetail?
  @Published var loadingDetailRatingKey: String?
  @Published var playlistArtworkItems: [String: [PlexPlaylistItem]] = [:]
  @Published var playlistArtworkLoadingKeys: Set<String> = []
  @Published var pairingTarget: PlaylistQuarterItem?
  @Published var preview: PlaylistCreatePreviewResponse?
  @Published var playlistTitle = ""
  @Published var isLoading = false
  @Published var errorText: String?
  @Published var resultMessage: String?
  private var loadSequence = LatestOperationSequence()
  private var quarterSequence = LatestOperationSequence()
  private var activeRequestCount = 0
  private var loadTask: Task<Void, Never>?
  private var quarterLoadTask: Task<Void, Never>?
  private var loadTaskGeneration = 0
  private var quarterLoadTaskGeneration = 0

  var selectedQuarter: PlaylistQuarterOption? {
    quarters.first { $0.year == selectedYear && $0.month == selectedMonth }
  }

  var availableYears: [Int] {
    Array(Set(quarters.map(\.year))).sorted(by: >)
  }

  var availableMonths: [PlaylistQuarterOption] {
    quarters.filter { $0.year == selectedYear }.sorted { $0.month > $1.month }
  }

  var searchText: String {
    get { search.query }
    set { search.query = newValue }
  }

  var visibleItems: [PlaylistQuarterItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current
    )
    return (quarter?.items ?? []).filter { item in
      let matchesState: Bool
      switch matchFilter {
      case .all: matchesState = true
      case .matched: matchesState = item.pairing != nil && item.matchState == "matched"
      case .unmatched: matchesState = item.pairing == nil || item.matchState != "matched"
      }
      guard matchesState else { return false }
      guard !query.isEmpty else { return true }
      let values = [item.title, item.originalTitle] + item.aliases
      return values.contains { value in
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
          .contains(query)
      }
    }
  }

  var selectedItems: [PlaylistQuarterItem] {
    (quarter?.items ?? []).filter {
      selectedItemKeys.contains($0.key) && isSelectable($0)
    }
  }

  var selectableVisibleItems: [PlaylistQuarterItem] {
    visibleItems.filter(isSelectable)
  }

  var selectedItemCount: Int {
    selectedItems.count
  }

  var canOpenSelectionEditor: Bool {
    !selectedItems.isEmpty
  }

  var canPreview: Bool {
    !selectedItems.isEmpty && selectedItems.allSatisfy { selectedEpisodes[$0.key]?.isEmpty == false }
  }

  var canRequestPreview: Bool {
    canPreview && !playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func load(client: APIClient, refresh: Bool = false) async {
    loadTask?.cancel()
    quarterLoadTask?.cancel()
    loadTaskGeneration += 1
    let generation = loadTaskGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await performLoad(client: client, refresh: refresh)
    }
    loadTask = task
    await task.value
    if generation == loadTaskGeneration {
      loadTask = nil
    }
  }

  private func performLoad(client: APIClient, refresh: Bool) async {
    let requestID = loadSequence.begin()
    let requestedMode = mode
    beginLoading()
    defer { endLoading() }
    errorText = nil
    switch requestedMode {
    case .existing:
#if DEBUG
      if DesktopDebugConfiguration.usesPlaylistFixtures {
        playlists = PlaylistDebugFixtures.playlists
        if let requestedDetail = DesktopDebugConfiguration.initialPlaylistDetail {
          playlistDetail = PlaylistDebugFixtures.detail(for: requestedDetail)
        }
        return
      }
#endif
      do {
        let loadedPlaylists = try await client.plexPlaylists()
        guard loadSequence.accepts(requestID), mode == requestedMode else { return }
        if refresh { playlistArtworkItems.removeAll() }
        playlists = loadedPlaylists
        let validKeys = Set(loadedPlaylists.map(\.ratingKey))
        playlistArtworkItems = playlistArtworkItems.filter { validKeys.contains($0.key) }
      } catch is CancellationError {
        return
      } catch {
        guard loadSequence.accepts(requestID), mode == requestedMode else { return }
        errorText = error.localizedDescription
      }
    case .generate:
      do {
        let loadedQuarters = try await client.playlistQuarters(refresh: refresh)
        guard loadSequence.accepts(requestID), mode == requestedMode else { return }
        quarters = loadedQuarters
        if selectedYear == 0, let first = quarters.first {
          selectedYear = first.year
          selectedMonth = first.month
          playlistTitle = "\(first.year) 年 \(first.month) 月番组"
        } else if selectedQuarter == nil, let first = quarters.first {
          selectedYear = first.year
          selectedMonth = first.month
          playlistTitle = "\(first.year) 年 \(first.month) 月番组"
        }
      } catch is CancellationError {
        return
      } catch {
        guard loadSequence.accepts(requestID), mode == requestedMode else { return }
        errorText = error.localizedDescription
        return
      }
      if let selectedQuarter,
         loadSequence.accepts(requestID),
         mode == requestedMode {
        await performLoadQuarter(selectedQuarter, client: client, refresh: refresh)
      }
    }
  }

  func loadQuarter(_ option: PlaylistQuarterOption, client: APIClient, refresh: Bool = false) async {
    loadTask?.cancel()
    quarterLoadTask?.cancel()
    quarterLoadTaskGeneration += 1
    let generation = quarterLoadTaskGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await performLoadQuarter(option, client: client, refresh: refresh)
    }
    quarterLoadTask = task
    await task.value
    if generation == quarterLoadTaskGeneration {
      quarterLoadTask = nil
    }
  }

  private func performLoadQuarter(
    _ option: PlaylistQuarterOption,
    client: APIClient,
    refresh: Bool
  ) async {
    selectedYear = option.year
    selectedMonth = option.month
    playlistTitle = "\(option.year) 年 \(option.month) 月番组"
    let requestID = quarterSequence.begin()
    beginLoading()
    defer { endLoading() }
    errorText = nil
    do {
      let response = try await client.playlistQuarter(year: option.year, month: option.month, refresh: refresh)
      guard quarterSequence.accepts(requestID), selectedYear == option.year, selectedMonth == option.month else { return }
      quarter = response
      let validKeys = Set(response.items.map(\.key))
      let selectableKeys = Set(response.items.filter(isSelectable).map(\.key))
      selectedItemKeys.formIntersection(selectableKeys)
      hierarchies = hierarchies.filter { validKeys.contains($0.key) }
      hierarchyLoadingKeys.formIntersection(validKeys)
      hierarchyErrors = hierarchyErrors.filter { validKeys.contains($0.key) }
      selectedSeasons = selectedSeasons.filter { validKeys.contains($0.key) }
      selectedEpisodes = selectedEpisodes.filter { validKeys.contains($0.key) }
    } catch is CancellationError {
      return
    } catch {
      guard quarterSequence.accepts(requestID) else { return }
      errorText = error.localizedDescription
    }
  }

  func cancelPendingLoads() {
    loadTaskGeneration += 1
    quarterLoadTaskGeneration += 1
    loadTask?.cancel()
    quarterLoadTask?.cancel()
    loadTask = nil
    quarterLoadTask = nil
    _ = loadSequence.begin()
    _ = quarterSequence.begin()
  }

  private func beginLoading() {
    activeRequestCount += 1
    isLoading = true
  }

  private func endLoading() {
    activeRequestCount = max(0, activeRequestCount - 1)
    isLoading = activeRequestCount > 0
  }

  func toggle(_ item: PlaylistQuarterItem) {
    guard isSelectable(item) else {
      pairingTarget = item
      return
    }
    if selectedItemKeys.remove(item.key) != nil {
      selectedSeasons[item.key] = nil
      selectedEpisodes[item.key] = nil
      return
    }
    selectedItemKeys.insert(item.key)
  }

  func selectAllVisible() {
    let selectable = selectableVisibleItems
    let keys = Set(selectable.map(\.key))
    if !keys.isEmpty, keys.isSubset(of: selectedItemKeys) {
      selectedItemKeys.subtract(keys)
      for key in keys {
        selectedSeasons[key] = nil
        selectedEpisodes[key] = nil
      }
      return
    }
    selectedItemKeys.formUnion(keys)
  }

  func ensureSelectedHierarchies(client: APIClient) async {
    let pendingItems = selectedItems.filter {
      hierarchies[$0.key] == nil && !hierarchyLoadingKeys.contains($0.key)
    }
    guard !pendingItems.isEmpty else { return }

    await withTaskGroup(of: Void.self) { group in
      var iterator = pendingItems.makeIterator()
      for _ in 0..<4 {
        guard let item = iterator.next() else { break }
        group.addTask { [weak self] in
          await self?.ensureHierarchy(for: item, client: client)
        }
      }
      while await group.next() != nil {
        guard !Task.isCancelled, let item = iterator.next() else { continue }
        group.addTask { [weak self] in
          await self?.ensureHierarchy(for: item, client: client)
        }
      }
    }
  }

  func ensureHierarchy(for item: PlaylistQuarterItem, client: APIClient, force: Bool = false) async {
    guard let pairing = item.pairing else { return }
    if let hierarchy = hierarchies[item.key], !force {
      applyDefaultSelectionIfEligible(hierarchy, itemKey: item.key)
      return
    }
    guard !hierarchyLoadingKeys.contains(item.key) else { return }
    hierarchyLoadingKeys.insert(item.key)
    hierarchyErrors[item.key] = nil
    defer { hierarchyLoadingKeys.remove(item.key) }
    do {
      let hierarchy = try await client.plexShowHierarchy(ratingKey: pairing.plexRatingKey)
      hierarchies[item.key] = hierarchy
      applyDefaultSelectionIfEligible(hierarchy, itemKey: item.key)
    } catch is CancellationError {
      return
    } catch {
      hierarchyErrors[item.key] = error.localizedDescription
    }
  }

  func updateSeason(itemKey: String, season: Int) {
    selectedSeasons[itemKey] = season >= 0 ? season : nil
    selectedEpisodes[itemKey] = nil
  }

  func updateEpisode(itemKey: String, ratingKey: String) {
    selectedEpisodes[itemKey] = ratingKey.isEmpty ? nil : ratingKey
  }

  func availableEpisodes(itemKey: String) -> [PlexEpisode] {
    guard let seasonNumber = selectedSeasons[itemKey] else { return [] }
    return hierarchies[itemKey]?.seasons
      .first(where: { $0.seasonNumber == seasonNumber })?
      .episodes.filter(\.playable) ?? []
  }

  func selectedEpisode(itemKey: String) -> PlexEpisode? {
    guard let ratingKey = selectedEpisodes[itemKey] else { return nil }
    for season in hierarchies[itemKey]?.seasons ?? [] {
      if let episode = season.episodes.first(where: { $0.ratingKey == ratingKey }) {
        return episode
      }
    }
    return nil
  }

  func episodeSelectionLabel(itemKey: String) -> String {
    if hierarchyLoadingKeys.contains(itemKey), hierarchies[itemKey] == nil {
      return "正在读取季集"
    }
    if hierarchyErrors[itemKey] != nil, hierarchies[itemKey] == nil {
      return "重新读取季集"
    }
    guard let episode = selectedEpisode(itemKey: itemKey) else {
      return hierarchies[itemKey] == nil ? "读取季集" : "选择季集"
    }
    let season = episode.seasonNumber == 0 ? "特别篇" : "第 \(episode.seasonNumber) 季"
    return "\(season) · 第 \(episode.episodeNumber) 集"
  }

  private func applyDefaultSelectionIfEligible(_ hierarchy: PlexShowHierarchy, itemKey: String) {
    guard selectedEpisodes[itemKey] == nil,
          hierarchy.seasons.count == 1,
          let season = hierarchy.seasons.first,
          season.seasonNumber == 1,
          let episode = season.episodes.first(where: { $0.episodeNumber == 1 && $0.playable }) else { return }
    selectedSeasons[itemKey] = 1
    selectedEpisodes[itemKey] = episode.ratingKey
  }

  func pair(item: PlaylistQuarterItem, show: PlexShow, client: APIClient) async -> Bool {
    do {
      _ = try await client.pairPlaylistItem(PairingRequest(itemKey: item.key, plexRatingKey: show.ratingKey))
      if let selectedQuarter { await loadQuarter(selectedQuarter, client: client) }
      pairingTarget = nil
      return true
    } catch {
      errorText = error.localizedDescription
      return false
    }
  }

  func unpair(_ item: PlaylistQuarterItem, client: APIClient) async {
    do {
      _ = try await client.unpairPlaylistItem(itemKey: item.key)
      selectedItemKeys.remove(item.key)
      selectedSeasons[item.key] = nil
      selectedEpisodes[item.key] = nil
      hierarchies[item.key] = nil
      hierarchyLoadingKeys.remove(item.key)
      hierarchyErrors[item.key] = nil
      if let selectedQuarter { await loadQuarter(selectedQuarter, client: client) }
    } catch {
      errorText = error.localizedDescription
    }
  }

  func rematch(_ item: PlaylistQuarterItem, client: APIClient) async {
    do {
      _ = try await client.rematchPlaylistItem(itemKey: item.key)
      if let selectedQuarter { await loadQuarter(selectedQuarter, client: client) }
    } catch {
      errorText = error.localizedDescription
    }
  }

  func loadPlaylistDetail(_ playlist: PlexPlaylistSummary, client: APIClient) async {
    guard loadingDetailRatingKey == nil else { return }
    loadingDetailRatingKey = playlist.ratingKey
    defer { loadingDetailRatingKey = nil }
#if DEBUG
    if DesktopDebugConfiguration.usesPlaylistFixtures {
      try? await Task.sleep(for: .milliseconds(250))
      playlistDetail = PlaylistDebugFixtures.detail(for: playlist.ratingKey)
      return
    }
#endif
    if let cachedItems = playlistArtworkItems[playlist.ratingKey] {
      playlistDetail = PlexPlaylistDetail(playlist: playlist, items: cachedItems)
      return
    }
    do {
      let detail = try await client.plexPlaylistDetail(ratingKey: playlist.ratingKey)
      playlistArtworkItems[playlist.ratingKey] = detail.items
      playlistDetail = detail
    } catch {
      errorText = error.localizedDescription
    }
  }

  func loadPlaylistArtwork(_ playlist: PlexPlaylistSummary, client: APIClient) async {
    guard playlistArtworkItems[playlist.ratingKey] == nil,
          playlistArtworkLoadingKeys.insert(playlist.ratingKey).inserted else { return }
    defer { playlistArtworkLoadingKeys.remove(playlist.ratingKey) }
#if DEBUG
    if DesktopDebugConfiguration.usesPlaylistFixtures {
      playlistArtworkItems[playlist.ratingKey] = PlaylistDebugFixtures.detail(for: playlist.ratingKey).items
      return
    }
#endif
    do {
      playlistArtworkItems[playlist.ratingKey] = try await client
        .plexPlaylistDetail(ratingKey: playlist.ratingKey).items
    } catch is CancellationError {
      return
    } catch {
      return
    }
  }

  func makePreview(client: APIClient) async {
    guard canRequestPreview, let selectedQuarter else { return }
    let selections = selectedItems.compactMap { item -> PlaylistSelection? in
      guard let episode = selectedEpisodes[item.key] else { return nil }
      return PlaylistSelection(itemKey: item.key, episodeRatingKey: episode)
    }
    do {
      preview = try await client.previewPlaylistCreation(
        PlaylistCreatePreviewRequest(
          title: playlistTitle,
          year: selectedQuarter.year,
          month: selectedQuarter.month,
          selections: selections
        )
      )
    } catch {
      errorText = error.localizedDescription
    }
  }

  func create(client: APIClient) async {
    guard let preview else { return }
    do {
      let response = try await client.createPlexPlaylist(
        PlaylistCreateRequest(confirmationToken: preview.confirmationToken, confirm: true)
      )
      self.preview = nil
      resultMessage = response.message
      playlists = try await client.plexPlaylists()
      mode = .existing
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func isSelectable(_ item: PlaylistQuarterItem) -> Bool {
    item.pairing?.valid == true && item.matchState == "matched"
  }
}

struct PlaylistView: View {
  @EnvironmentObject private var store: AppStore
  @StateObject private var model = PlaylistViewModel()
  @State private var posterHoverCoordinator = AppleTVPosterHoverCoordinator()
  @State private var playlistSearchFocusID: Int?
  @State private var showingSelectionEditor = false

  var body: some View {
    VStack(spacing: 0) {
      pageToolbar
      Group {
        if model.mode == .existing {
          existingPlaylists
        } else {
          generator
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlayPreferenceValue(CompactListSearchAnchorKey.self) { anchor in
      if let anchor,
         let presentationID = model.search.presentationID {
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
                requestPlaylistSearchDismissal()
              }
              .accessibilityHidden(true)

            CompactListSearchOverlay(
              query: $model.search.query,
              presentationID: presentationID,
              focusID: playlistSearchFocusID,
              resultCount: model.visibleItems.count,
              prompt: "搜索番组",
              itemName: "番组",
              attachedToWindow: { id, windowIsVisible in
                playlistSearchAttached(
                  presentationID: id,
                  windowIsVisible: windowIsVisible
                )
              },
              escape: handlePlaylistSearchEscape
            )
            .padding(.leading, panelLeading)
            .padding(.top, anchorRect.maxY + 6)
          }
        }
        .zIndex(100)
      }
    }
    .onKeyPress(phases: .down) { keyPress in
      if keyPress.key == .escape,
         handlePlaylistSearchEscape() {
        return .handled
      }
      return .ignored
    }
    .task(id: store.backendURL) {
      await model.load(client: store.client)
    }
    .onChange(of: model.mode) { _, _ in
      Task { await model.load(client: store.client) }
    }
    .onDisappear {
      model.cancelPendingLoads()
      playlistSearchFocusID = nil
      model.search.forceDismiss()
    }
    .sheet(item: $model.playlistDetail) { detail in
      PlaylistDetailSheet(detail: detail) {
        model.playlistDetail = nil
      }
    }
    .sheet(item: $model.pairingTarget) { item in
      ManualPlaylistPairingSheet(item: item, client: store.client) { show in
        await model.pair(item: item, show: show, client: store.client)
      }
    }
    .sheet(isPresented: $showingSelectionEditor) {
      PlaylistSelectionEditorSheet(model: model, client: store.client) {
        showingSelectionEditor = false
      }
    }
    .alert("播放列表", isPresented: Binding(
      get: { model.resultMessage != nil },
      set: { if !$0 { model.resultMessage = nil } }
    )) {
      Button("好") { model.resultMessage = nil }
    } message: {
      Text(model.resultMessage ?? "")
    }
  }

  private func requestPlaylistSearchPresentation() {
    _ = model.search.requestPresentation()
  }

  private func togglePlaylistSearch() {
    if model.search.isPresented {
      requestPlaylistSearchDismissal()
    } else {
      requestPlaylistSearchPresentation()
    }
  }

  private func requestPlaylistSearchDismissal() {
    guard let id = model.search.requestDismissal() else { return }
    playlistSearchFocusID = nil
    completePlaylistSearchDismissal(id)
  }

  private func completePlaylistSearchDismissal(_ id: Int) {
    Task { @MainActor in
      await Task.yield()
      _ = model.search.completeDismissal(id)
    }
  }

  private func playlistSearchAttached(
    presentationID: Int,
    windowIsVisible: Bool
  ) {
    guard windowIsVisible,
          model.search.confirmPresentation(presentationID)
    else { return }
    playlistSearchFocusID = presentationID
  }

  private func handlePlaylistSearchEscape() -> Bool {
    let action = model.search.handleEscape()
    switch action {
    case .clearedQuery:
      return true
    case .dismissedPopover:
      playlistSearchFocusID = nil
      if let id = model.search.closingRequestID {
        completePlaylistSearchDismissal(id)
      }
      return true
    case .ignored:
      return false
    }
  }

  private var pageToolbar: some View {
    ZStack {
      Picker("播放列表视图", selection: $model.mode) {
        ForEach(PlaylistPageMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 300)

      HStack(spacing: 10) {
        Spacer()
        if model.isLoading {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          Task { await model.load(client: store.client, refresh: true) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("刷新播放列表与当前季度数据")
      }
    }
    .playlistToolbarSurface()
  }

  @ViewBuilder
  private var existingPlaylists: some View {
    if model.playlists.isEmpty {
      ContentUnavailableView(
        "没有可显示的播放列表",
        systemImage: "rectangle.stack.badge.play",
        description: Text(model.errorText ?? "连接 Plex 后，可以在这里查看现有视频播放列表。")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(model.playlists) { playlist in
            let isLoadingDetail = model.loadingDetailRatingKey == playlist.ratingKey
            Button {
              Task { await model.loadPlaylistDetail(playlist, client: store.client) }
            } label: {
              DesktopPlaylistBanner(
                playlist: playlist,
                posterURLs: bannerPosterURLs(for: playlist),
                isLoading: isLoadingDetail
              )
            }
            .buttonStyle(.plain)
            .disabled(model.loadingDetailRatingKey != nil)
            .accessibilityLabel(playlist.title)
            .accessibilityValue("\(playlist.itemCount) 项\(isLoadingDetail ? "，正在加载详情" : "")")
            .task(id: playlist.ratingKey) {
              await model.loadPlaylistArtwork(playlist, client: store.client)
            }
          }
        }
        .playlistPageContent()
      }
    }
  }

  private func bannerPosterURLs(for playlist: PlexPlaylistSummary) -> [URL?] {
    let itemURLs = (model.playlistArtworkItems[playlist.ratingKey] ?? [])
      .compactMap(\.posterUrl)
      .prefix(5)
      .map(store.backendResourceURL)
    if !itemURLs.isEmpty { return Array(itemURLs) }
    return [store.backendResourceURL(playlist.posterUrl)]
  }

  private var generator: some View {
    VStack(spacing: 0) {
      generatorToolbar
      if let error = model.errorText, model.quarter == nil {
        ContentUnavailableView("无法加载季度数据", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        List {
          if let warning = model.quarter?.warning {
            Label(warning, systemImage: "externaldrive.badge.exclamationmark")
              .font(.caption)
              .foregroundStyle(.orange)
              .playlistGeneratorListRow()
          }

          if model.visibleItems.isEmpty {
            ContentUnavailableView(
              model.quarter?.items.isEmpty == true ? "本季度没有番组数据" : "没有符合筛选的番组",
              systemImage: model.searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass",
              description: Text(model.searchText.isEmpty ? "请切换配对状态或选择其他季度。" : "请调整搜索词或配对状态。")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
            .playlistGeneratorListRow(showsSeparator: false)
          } else {
            animeList
          }

          Text(model.quarter?.attribution ?? "番组数据来源：bangumi-data（CC BY 4.0）")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .playlistGeneratorListRow(showsSeparator: false)
        }
        .listStyle(.plain)
        .background {
          PlaylistScrollActivityReader { scrolling in
            posterHoverCoordinator.setScrolling(scrolling)
          }
        }
      }
    }
  }

  private var generatorToolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        quarterMenu
        Spacer(minLength: 14)
        matchFilterPicker
        Spacer(minLength: 14)
        batchActionGroup
      }

      VStack(spacing: 8) {
        HStack(spacing: 10) {
          quarterMenu
          Spacer(minLength: 10)
          matchFilterPicker
        }
        HStack {
          Spacer(minLength: 0)
          batchActionGroup
        }
      }
    }
    .playlistToolbarSurface(verticalPadding: 10)
  }

  private var quarterMenu: some View {
    Menu {
      ForEach(model.availableYears, id: \.self) { year in
        Menu {
          ForEach(model.quarters.filter { $0.year == year }.sorted { $0.month > $1.month }) { option in
            Button {
              Task { await model.loadQuarter(option, client: store.client) }
            } label: {
              if model.selectedYear == option.year && model.selectedMonth == option.month {
                Label {
                  Text(verbatim: "\(option.month) 月 · \(option.count)")
                } icon: {
                  Image(systemName: "checkmark")
                }
              } else {
                Text(verbatim: "\(option.month) 月 · \(option.count)")
              }
            }
          }
        } label: {
          Text(verbatim: "\(year) 年")
        }
      }
    } label: {
      Label {
        Text(verbatim: model.selectedQuarter.map { "\($0.year) 年 \($0.month) 月 · \($0.count)" } ?? "选择季度")
      } icon: {
        Image(systemName: "calendar")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("先选择年份，再选择季度月份")
  }

  private var matchFilterPicker: some View {
    Picker("配对状态", selection: $model.matchFilter) {
      ForEach(PlaylistMatchFilter.allCases) { filter in
        Text(filter.title).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 220)
  }

  private var batchActionGroup: some View {
    HStack(spacing: 8) {
      CompactListSearchButton(
        search: model.search,
        label: "搜索番组",
        resultCount: model.visibleItems.count,
        totalCount: model.quarter?.items.count ?? 0,
        itemName: "番组",
        toggle: togglePlaylistSearch
      )

      Divider()
        .frame(height: 18)

      selectAllButton
      createSelectionButton
    }
  }

  private var selectAllButton: some View {
    Button {
      model.selectAllVisible()
    } label: {
      Label("全选当前结果", systemImage: "checkmark.circle")
    }
    .disabled(model.selectableVisibleItems.isEmpty)
    .help("只选择当前筛选中已配对的番组")
  }

  private var createSelectionButton: some View {
    Button {
      showingSelectionEditor = true
    } label: {
      Label {
        Text(model.selectedItemCount == 0 ? "创建清单" : "创建清单 \(model.selectedItemCount)")
      } icon: {
        Image(systemName: "list.bullet.clipboard")
      }
      .frame(minWidth: 106)
    }
    .buttonStyle(.borderedProminent)
    .disabled(!model.canOpenSelectionEditor)
    .help(model.canOpenSelectionEditor ? "编辑已选番组并预览播放列表" : "请先选择已配对番组")
    .accessibilityValue(model.canOpenSelectionEditor ? "已选择 \(model.selectedItemCount) 部番组" : "没有选择番组")
  }

  private var animeList: some View {
    ForEach(model.visibleItems) { item in
      let isSelected = model.selectedItemKeys.contains(item.key)
      PlaylistAnimeRow(
        item: item,
        posterURL: store.backendResourceURL(item.posterUrl),
        isSelected: isSelected,
        hoverCoordinator: posterHoverCoordinator,
        toggle: { model.toggle(item) },
        editPairing: { model.pairingTarget = item },
        removePairing: { Task { await model.unpair(item, client: store.client) } },
        rematch: { Task { await model.rematch(item, client: store.client) } }
      )
      .equatable()
      .playlistGeneratorListRow()
    }
  }

  private static func durationText(_ milliseconds: Int) -> String {
    let minutes = milliseconds / 60_000
    let hours = minutes / 60
    return hours > 0 ? "\(hours) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
  }

  private static func updatedText(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
  }
}

private struct PlaylistPageContentModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(KisetsuStyle.pagePadding)
      .frame(maxWidth: KisetsuStyle.contentMaxWidth, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .top)
  }
}

private struct PlaylistToolbarSurfaceModifier: ViewModifier {
  var verticalPadding: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, KisetsuStyle.pagePadding)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: KisetsuStyle.contentMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
      .overlay(alignment: .bottom) { Divider() }
  }
}

private extension View {
  func playlistPageContent() -> some View {
    modifier(PlaylistPageContentModifier())
  }

  func playlistToolbarSurface(
    verticalPadding: CGFloat = KisetsuStyle.toolbarVerticalPadding
  ) -> some View {
    modifier(PlaylistToolbarSurfaceModifier(verticalPadding: verticalPadding))
  }

  func playlistGeneratorListRow(showsSeparator: Bool = true) -> some View {
    self
      .frame(maxWidth: KisetsuStyle.contentMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .listRowInsets(
        EdgeInsets(
          top: 0,
          leading: KisetsuStyle.pagePadding,
          bottom: 0,
          trailing: KisetsuStyle.pagePadding
        )
      )
      .listRowSeparator(showsSeparator ? .visible : .hidden)
  }
}

struct PlaylistFlowLayoutResult: Equatable {
  var size: CGSize
  var origins: [CGPoint]

  static let empty = PlaylistFlowLayoutResult(size: .zero, origins: [])
}

enum PlaylistFlowLayoutEngine {
  static func layout(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> PlaylistFlowLayoutResult {
    let availableWidth = max(width, 0)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var origins: [CGPoint] = []
    origins.reserveCapacity(sizes.count)

    for size in sizes {
      if x > 0 && x + size.width > availableWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    return PlaylistFlowLayoutResult(
      size: CGSize(width: availableWidth, height: y + rowHeight),
      origins: origins
    )
  }
}

private struct PlaylistFlowLayout: Layout {
  struct Cache {
    var subviewSizes: [CGSize]
    var proposalWidth: CGFloat?
    var result = PlaylistFlowLayoutResult.empty
  }

  var spacing: CGFloat = 8

  func makeCache(subviews: Subviews) -> Cache {
    Cache(subviewSizes: subviews.map { $0.sizeThatFits(.unspecified) })
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache.subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
    cache.proposalWidth = nil
    cache.result = .empty
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let width = max(proposal.width ?? 600, 0)
    updateLayout(width: width, cache: &cache)
    return cache.result.size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    let width = max(bounds.width, 0)
    updateLayout(width: width, cache: &cache)
    for (index, subview) in subviews.enumerated() where index < cache.result.origins.count {
      let origin = cache.result.origins[index]
      let size = cache.subviewSizes[index]
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
    }
  }

  private func updateLayout(width: CGFloat, cache: inout Cache) {
    guard cache.proposalWidth != width else { return }
    cache.proposalWidth = width
    cache.result = PlaylistFlowLayoutEngine.layout(
      sizes: cache.subviewSizes,
      width: width,
      spacing: spacing
    )
  }
}

private struct PlaylistScrollActivityReader: NSViewRepresentable {
  var onScrollingChanged: (Bool) -> Void

  func makeNSView(context: Context) -> PlaylistScrollObserverView {
    let view = PlaylistScrollObserverView()
    view.onScrollingChanged = onScrollingChanged
    return view
  }

  func updateNSView(_ nsView: PlaylistScrollObserverView, context: Context) {
    nsView.onScrollingChanged = onScrollingChanged
    nsView.attachToEnclosingScrollView()
  }

  static func dismantleNSView(_ nsView: PlaylistScrollObserverView, coordinator: ()) {
    nsView.detach()
  }
}

private final class PlaylistScrollObserverView: NSView {
  var onScrollingChanged: (Bool) -> Void = { _ in }
  private weak var observedScrollView: NSScrollView?
  private var observerTokens: [NSObjectProtocol] = []
  private var attachmentScheduled = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attachToEnclosingScrollView()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    attachToEnclosingScrollView()
  }

  func attachToEnclosingScrollView() {
    guard let scrollView = enclosingScrollView else {
      scheduleAttachment()
      return
    }
    attach(to: scrollView)
  }

  private func attach(to scrollView: NSScrollView) {
    guard observedScrollView !== scrollView else { return }
    detach()
    observedScrollView = scrollView
    let center = NotificationCenter.default
    observerTokens = [
      center.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.onScrollingChanged(true) }
      },
      center.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.onScrollingChanged(false) }
      },
    ]
  }

  func detach() {
    observerTokens.forEach(NotificationCenter.default.removeObserver)
    observerTokens.removeAll()
    observedScrollView = nil
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { detach() }
    super.viewWillMove(toWindow: newWindow)
  }

  private func scheduleAttachment() {
    guard !attachmentScheduled else { return }
    attachmentScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      attachmentScheduled = false
      guard let scrollView = enclosingScrollView else { return }
      attach(to: scrollView)
    }
  }
}

struct PlaylistPairingPresentation: Equatable {
  var targetTitle: String
  var sourceLabel: String
  var reason: String
  var scoreText: String

  init(pairing: PlexPairing) {
    if let year = pairing.year {
      targetTitle = "\(pairing.title)（\(year)）"
    } else {
      targetTitle = pairing.title
    }
    sourceLabel = switch pairing.source {
    case "external_id": "外部 ID"
    case "title": "标题"
    case "manual": "手动"
    default: "自动"
    }
    let trimmedReason = pairing.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    reason = trimmedReason.isEmpty ? "暂无匹配依据" : trimmedReason
    scoreText = "\(Int((min(max(pairing.score, 0), 1) * 100).rounded()))%"
  }

  var compactTitle: String { "Plex · \(targetTitle)" }
  var helpText: String { "已匹配到 \(targetTitle)\n\(sourceLabel)匹配 · \(scoreText)\n\(reason)" }
  var accessibilityDescription: String {
    "已匹配到 Plex 节目 \(targetTitle)，匹配方式：\(sourceLabel)，匹配依据：\(reason)，置信度：\(scoreText)"
  }
}

final class PlaylistPosterImage: @unchecked Sendable {
  let cgImage: CGImage
  let pixelWidth: Int
  let pixelHeight: Int
  let memoryCost: Int

  init(cgImage: CGImage) {
    self.cgImage = cgImage
    pixelWidth = cgImage.width
    pixelHeight = cgImage.height
    memoryCost = cgImage.bytesPerRow * cgImage.height
  }
}

enum PlaylistPosterDownsampler {
  static func decode(data: Data, maxPixelSize: Int) -> PlaylistPosterImage? {
    guard maxPixelSize > 0,
          let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
          ) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return PlaylistPosterImage(cgImage: thumbnail)
  }
}

actor PlaylistPosterDownloadGate {
  private let limit: Int
  private var activeCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
    await acquire()
    let result = await operation()
    release()
    return result
  }

  private func acquire() async {
    if activeCount < limit {
      activeCount += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    if waiters.isEmpty {
      activeCount = max(0, activeCount - 1)
    } else {
      waiters.removeFirst().resume()
    }
  }
}

actor PosterReadSessionPool {
  static let shared = PosterReadSessionPool()
  private var session = makeSession()

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: configuration)
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let activeSession = session
    do {
      return try await activeSession.data(for: request)
    } catch {
      guard LocalNetworkErrorClassifier.containsAddressNotAvailable(error as NSError) else {
        throw error
      }
      if activeSession === session {
        activeSession.invalidateAndCancel()
        session = Self.makeSession()
      }
      let recoverySession = session
      try await Task.sleep(for: .milliseconds(120))
      return try await recoverySession.data(for: request)
    }
  }
}

enum PosterPixelSizeBucket {
  static func value(for requiredPixels: Int) -> Int {
    guard requiredPixels > 0 else { return 0 }
    for bucket in [192, 256, 384, 512, 768, 1_024] where requiredPixels <= bucket {
      return bucket
    }
    return requiredPixels
  }
}

actor PlaylistPosterImagePipeline {
  typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  private struct InFlightRequest {
    let task: Task<PlaylistPosterImage?, Never>
    var waiters: Set<UUID>
  }

  static let shared = PlaylistPosterImagePipeline()
  static let maximumConcurrentDownloads = 2

  private let cache = NSCache<NSString, PlaylistPosterImage>()
  private var inFlight: [String: InFlightRequest] = [:]
  private let downloadGate: PlaylistPosterDownloadGate
  private let loader: DataLoader

  init(
    maxConcurrentDownloads: Int = maximumConcurrentDownloads,
    loader: @escaping DataLoader = { request in
      try await PosterReadSessionPool.shared.data(for: request)
    }
  ) {
    downloadGate = PlaylistPosterDownloadGate(limit: maxConcurrentDownloads)
    self.loader = loader
    cache.countLimit = 160
    cache.totalCostLimit = 64 * 1_024 * 1_024
  }

  func image(for url: URL, maxPixelSize: Int) async -> PlaylistPosterImage? {
    let key = "\(url.absoluteString)#\(maxPixelSize)"
    if let cached = cache.object(forKey: key as NSString) {
      return cached
    }
    let waiterID = UUID()
    let task: Task<PlaylistPosterImage?, Never>
    if var existing = inFlight[key] {
      existing.waiters.insert(waiterID)
      inFlight[key] = existing
      task = existing.task
    } else {
      let downloadGate = downloadGate
      let loader = loader
      task = Task.detached(priority: .utility) { () -> PlaylistPosterImage? in
        await downloadGate.run {
          guard !Task.isCancelled else { return nil }
          do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await loader(request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
              return nil
            }
            return PlaylistPosterDownsampler.decode(data: data, maxPixelSize: maxPixelSize)
          } catch {
            return nil
          }
        }
      }
      inFlight[key] = InFlightRequest(task: task, waiters: [waiterID])
    }

    return await withTaskCancellationHandler {
      let loaded = await task.value
      return finishWaiter(key: key, waiterID: waiterID, loaded: loaded)
    } onCancel: {
      Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
    }
  }

  private func finishWaiter(
    key: String,
    waiterID: UUID,
    loaded: PlaylistPosterImage?
  ) -> PlaylistPosterImage? {
    guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
      return Task.isCancelled ? nil : loaded
    }
    if request.waiters.isEmpty {
      inFlight[key] = nil
      if let loaded {
        cache.setObject(loaded, forKey: key as NSString, cost: loaded.memoryCost)
      }
    } else {
      inFlight[key] = request
    }
    return Task.isCancelled ? nil : loaded
  }

  private func cancelWaiter(key: String, waiterID: UUID) {
    guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else { return }
    if request.waiters.isEmpty {
      request.task.cancel()
      inFlight[key] = nil
    } else {
      inFlight[key] = request
    }
  }
}

struct PlaylistPosterView: View {
  @Environment(\.displayScale) private var displayScale
  @State private var image: PlaylistPosterImage?
  @State private var placeholderStatus = AnimePosterPlaceholderStatus.unavailable

  var url: URL?
  var width: CGFloat
  var height: CGFloat
  var showsShadow = true
  var isActive = true
  var cornerRadius = KisetsuStyle.posterRadius

  private var maxPixelSize: Int {
    PosterPixelSizeBucket.value(
      for: Int(ceil(max(width, height) * max(displayScale, 1)))
    )
  }

  private var requestKey: String {
    "\(url?.absoluteString ?? "none")#\(maxPixelSize)#\(isActive)"
  }

  var body: some View {
    Group {
      if showsShadow {
        posterContent
          .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
      } else {
        posterContent
      }
    }
    .task(id: requestKey) {
      image = nil
      placeholderStatus = url == nil || !isActive ? .unavailable : .loading
      guard isActive, let url else { return }
      let loaded = await PlaylistPosterImagePipeline.shared.image(
        for: url,
        maxPixelSize: maxPixelSize
      )
      guard !Task.isCancelled else { return }
      image = loaded
      placeholderStatus = .unavailable
    }
  }

  private var posterContent: some View {
    Group {
      if let image {
        Image(decorative: image.cgImage, scale: displayScale)
          .resizable()
          .scaledToFill()
      } else {
        AnimePosterPlaceholder(status: placeholderStatus)
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius)
        .stroke(KisetsuStyle.subtleBorder)
    }
  }
}

enum PlaylistAnimeRowLayout {
  static let posterWidth: CGFloat = 150
  static let posterHeight: CGFloat = 214
  static let minimumRowHeight: CGFloat = 242
  static let wideContentMinimumWidth: CGFloat = 420
  static let trailingActionWidth: CGFloat = 176
  static let actionHeight: CGFloat = 32
  static let menuButtonSize: CGFloat = 32
}

struct PlaylistAnimeRowActionPresentation: Equatable {
  var itemTitle: String
  var isPaired: Bool
  var isSelectable: Bool
  var isSelected: Bool

  var addTitle: String {
    isSelected ? "已加入清单" : "加入清单"
  }

  var addSystemImage: String {
    isSelected ? "checkmark.circle.fill" : "plus.circle"
  }

  var addHelp: String {
    guard isSelectable else { return "需要先配对 Plex 节目" }
    return isSelected ? "从创建清单移除" : "加入创建清单"
  }

  var pairingAccessibilityHint: String {
    "\(itemTitle)，\(isPaired ? "已配对" : "未配对")"
  }
}

struct PlaylistAnimeRow: View, Equatable {
  var item: PlaylistQuarterItem
  var posterURL: URL?
  var isSelected: Bool
  var hoverCoordinator: AppleTVPosterHoverCoordinator
  var toggle: () -> Void
  var editPairing: () -> Void
  var removePairing: () -> Void
  var rematch: () -> Void
  @State private var isShowingPairingDetails = false
  @State private var isVisible = false

  private var pairingPresentation: PlaylistPairingPresentation? {
    item.pairing.map(PlaylistPairingPresentation.init)
  }

  private var schedulePresentation: PlaylistSchedulePresentation {
    PlaylistSchedulePresenter.presentation(
      begin: item.begin,
      broadcast: item.broadcast,
      mediaType: item.mediaType
    )
  }

  private var externalLinkGroups: [PlaylistExternalLinkGroup] {
    PlaylistExternalLinkPresenter.groups(for: item.links)
  }

  private var isSelectable: Bool {
    item.pairing?.valid == true && item.matchState == "matched"
  }

  private var actionPresentation: PlaylistAnimeRowActionPresentation {
    PlaylistAnimeRowActionPresentation(
      itemTitle: item.title,
      isPaired: item.pairing != nil,
      isSelectable: isSelectable,
      isSelected: isSelected
    )
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item
      && lhs.posterURL == rhs.posterURL
      && lhs.isSelected == rhs.isSelected
      && lhs.hoverCoordinator === rhs.hoverCoordinator
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      wideRow
      compactRow
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 14)
    .frame(
      maxWidth: .infinity,
      minHeight: PlaylistAnimeRowLayout.minimumRowHeight,
      alignment: .topLeading
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
    .onScrollVisibilityChange(threshold: 0.05) { visible in
      isVisible = visible
    }
  }

  private var wideRow: some View {
    HStack(alignment: .top, spacing: 18) {
      poster
        .accessibilitySortPriority(3)
      contentColumn
        .frame(minWidth: PlaylistAnimeRowLayout.wideContentMinimumWidth, maxWidth: .infinity, alignment: .topLeading)
        .layoutPriority(1)
        .accessibilitySortPriority(2)
      trailingActions
        .accessibilitySortPriority(1)
    }
  }

  private var compactRow: some View {
    HStack(alignment: .top, spacing: 18) {
      poster
        .accessibilitySortPriority(3)
      VStack(alignment: .leading, spacing: 12) {
        contentColumn
          .accessibilitySortPriority(2)
        trailingActions
          .frame(maxWidth: .infinity, alignment: .trailing)
          .accessibilitySortPriority(1)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .layoutPriority(1)
    }
  }

  private var contentColumn: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(item.title)
        .font(.title3.weight(.semibold))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      if !item.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(item.originalTitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .help(item.originalTitle)
      }

      PlaylistFlowLayout(spacing: 8) {
        CompactStatusBadge(
          text: mediaTypeText,
          color: .secondary,
          systemImage: mediaTypeSystemImage
        )
        CompactStatusBadge(
          text: schedulePresentation.dateText,
          color: .secondary,
          systemImage: "calendar"
        )
        if let scheduleText = schedulePresentation.scheduleText {
          CompactStatusBadge(
            text: scheduleText,
            color: KisetsuStyle.animeTint,
            systemImage: "clock"
          )
        }
        if let presentation = pairingPresentation {
          CompactStatusBadge(
            text: "\(presentation.sourceLabel)匹配 · \(presentation.scoreText)",
            color: .green,
            systemImage: "link"
          )
        } else {
          CompactStatusBadge(
            text: "未配对",
            color: .secondary,
            systemImage: "questionmark.circle"
          )
        }
      }

      pairingSummary

      if !externalLinkGroups.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(externalLinkGroups) { group in
            PlaylistExternalLinkGroupRow(group: group)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var poster: some View {
    ZStack(alignment: .top) {
      Button(action: toggle) {
        PlaylistPosterView(
          url: posterURL,
          width: PlaylistAnimeRowLayout.posterWidth,
          height: PlaylistAnimeRowLayout.posterHeight,
          showsShadow: false,
          isActive: isVisible
        )
        .appleTVPosterHover(
          .grid,
          interactionSize: CGSize(
            width: PlaylistAnimeRowLayout.posterWidth,
            height: PlaylistAnimeRowLayout.posterHeight
          ),
          coordinator: hoverCoordinator
        )
      }
      .buttonStyle(.plain)
      .disabled(!isSelectable)
      .accessibilityLabel(isSelected ? "取消选择 \(item.title)" : "选择 \(item.title)")
      .accessibilityHint(isSelectable ? "加入或移出播放列表创建清单" : "需要先配对 Plex 节目")

      HStack(alignment: .top) {
        Button(action: toggle) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .help(isSelectable ? (isSelected ? "从创建清单移除" : "加入创建清单") : "先配对 Plex 节目")
        .disabled(!isSelectable)
        .accessibilityHidden(true)
        Spacer()
        Label(item.pairing == nil ? "未配对" : "已入库", systemImage: item.pairing == nil ? "questionmark" : "checkmark")
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(Color(nsColor: .windowBackgroundColor).opacity(0.88), in: Capsule())
          .overlay {
            Capsule()
              .stroke(KisetsuStyle.subtleBorder, lineWidth: 0.6)
          }
          .accessibilityHidden(true)
      }
      .padding(7)
    }
    .frame(
      width: PlaylistAnimeRowLayout.posterWidth,
      height: PlaylistAnimeRowLayout.posterHeight
    )
    .fixedSize(horizontal: true, vertical: true)
  }

  @ViewBuilder
  private var pairingSummary: some View {
    if let presentation = pairingPresentation {
      VStack(alignment: .leading, spacing: 4) {
        Button {
          isShowingPairingDetails = true
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "link")
            Text(presentation.targetTitle)
              .font(.callout.weight(.medium))
              .lineLimit(2)
            Image(systemName: "info.circle")
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(presentation.helpText)
        .accessibilityLabel("查看 Plex 匹配详情")
        .accessibilityValue(presentation.accessibilityDescription)
        .popover(isPresented: $isShowingPairingDetails, arrowEdge: .trailing) {
          PlaylistPairingDetailsPopover(itemTitle: item.title, presentation: presentation) {
            isShowingPairingDetails = false
            editPairing()
          }
        }

        Text("\(presentation.sourceLabel)匹配 · \(presentation.scoreText) · \(presentation.reason)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text("尚未匹配到 Plex 节目")
          .font(.callout.weight(.medium))
        Text(item.matchReason ?? "可以搜索 Plex 媒体库进行手动配对。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private var trailingActions: some View {
    HStack(alignment: .center, spacing: 8) {
      Button(action: toggle) {
        Label(actionPresentation.addTitle, systemImage: actionPresentation.addSystemImage)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(isSelected ? KisetsuStyle.animeTint : .secondary)
      .frame(height: PlaylistAnimeRowLayout.actionHeight)
      .disabled(!actionPresentation.isSelectable)
      .focusable()
      .help(actionPresentation.addHelp)
      .accessibilityLabel("\(actionPresentation.addTitle) \(item.title)")
      .accessibilityHint(actionPresentation.addHelp)
      .accessibilitySortPriority(2)

      Menu {
        if actionPresentation.isPaired {
          Button("查看匹配详情", systemImage: "info.circle") {
            isShowingPairingDetails = true
          }
          Button("搜索并重新配对", systemImage: "magnifyingglass", action: editPairing)
        } else {
          Button("搜索并配对", systemImage: "magnifyingglass", action: editPairing)
        }
        Button("重新自动匹配", systemImage: "arrow.clockwise", action: rematch)
        if actionPresentation.isPaired {
          Divider()
          Button("取消配对", systemImage: "link.badge.minus", role: .destructive, action: removePairing)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.body)
          .frame(
            width: PlaylistAnimeRowLayout.menuButtonSize,
            height: PlaylistAnimeRowLayout.menuButtonSize
          )
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(
        width: PlaylistAnimeRowLayout.menuButtonSize,
        height: PlaylistAnimeRowLayout.actionHeight
      )
      .focusable()
      .help("配对操作")
      .accessibilityLabel("配对操作")
      .accessibilityHint(actionPresentation.pairingAccessibilityHint)
      .accessibilitySortPriority(1)
    }
    .frame(
      width: PlaylistAnimeRowLayout.trailingActionWidth,
      height: PlaylistAnimeRowLayout.actionHeight,
      alignment: .trailing
    )
    .accessibilityElement(children: .contain)
  }

  private var mediaTypeText: String {
    switch item.mediaType.lowercased() {
    case "tv": return "TV"
    case "movie": return "剧场版"
    case "ova": return "OVA"
    case "web": return "WEB"
    default: return item.mediaType.uppercased()
    }
  }

  private var mediaTypeSystemImage: String {
    switch item.mediaType.lowercased() {
    case "movie": return "film"
    case "ova": return "opticaldisc"
    case "web": return "network"
    default: return "tv"
    }
  }

}

private struct PlaylistExternalLinkGroupRow: View {
  var group: PlaylistExternalLinkGroup

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Label(group.title, systemImage: group.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 52, height: 24, alignment: .leading)

      PlaylistFlowLayout(spacing: 6) {
        ForEach(group.links) { link in
          PlaylistExternalLinkPill(
            categoryTitle: group.title,
            link: link
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct PlaylistExternalLinkPill: View {
  var categoryTitle: String
  var link: PlaylistExternalLinkPresentation

  var body: some View {
    Link(destination: link.url) {
      HStack(spacing: 5) {
        Text(link.title)
          .fixedSize(horizontal: false, vertical: true)
        Image(systemName: "arrow.up.right")
          .font(.caption2.weight(.semibold))
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(KisetsuStyle.animeTint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .frame(maxWidth: 260, alignment: .leading)
      .background(
        KisetsuStyle.animeTint.opacity(0.08),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(KisetsuStyle.animeTint.opacity(0.14), lineWidth: 0.6)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("\(categoryTitle) · \(link.title)\n\(link.url.absoluteString)")
    .accessibilityLabel("\(categoryTitle)，\(link.title)")
    .accessibilityHint("在默认浏览器中打开")
  }
}

private struct PlaylistPairingDetailsPopover: View {
  var itemTitle: String
  var presentation: PlaylistPairingPresentation
  var editPairing: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Plex 匹配详情", systemImage: "checkmark.circle.fill")
        .font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        Text("番组")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(itemTitle)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Plex 节目")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(presentation.targetTitle)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
        GridRow {
          Text("匹配方式")
            .foregroundStyle(.secondary)
          Text(presentation.sourceLabel)
        }
        GridRow {
          Text("匹配依据")
            .foregroundStyle(.secondary)
          Text(presentation.reason)
            .fixedSize(horizontal: false, vertical: true)
        }
        GridRow {
          Text("置信度")
            .foregroundStyle(.secondary)
          Text(presentation.scoreText)
            .monospacedDigit()
        }
      }
      .font(.caption)

      HStack {
        Spacer()
        Button("搜索并修正配对", systemImage: "magnifyingglass", action: editPairing)
      }
    }
    .padding(16)
    .frame(width: 320)
    .accessibilityElement(children: .contain)
  }
}

private struct PlaylistSelectionEditorSheet: View {
  @ObservedObject var model: PlaylistViewModel
  var client: APIClient
  var close: () -> Void

  private var titleIsValid: Bool {
    !model.playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text("创建清单")
            .font(.title3.weight(.semibold))
          Text("已选择 \(model.selectedItemCount) 部番组")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: close)
          .keyboardShortcut(.cancelAction)
      }
      .padding()

      Divider()

      if model.selectedItems.isEmpty {
        ContentUnavailableView(
          "没有可创建的番组",
          systemImage: "list.bullet.clipboard",
          description: Text("返回番组列表，选择至少一个已配对番组。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(model.selectedItems) { item in
          PlaylistEpisodeSelectionRow(
            item: item,
            model: model,
            retryHierarchy: {
              Task { await model.ensureHierarchy(for: item, client: client, force: true) }
            }
          )
          .padding(.vertical, 5)
        }
        .listStyle(.inset)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        if let errorText = model.errorText {
          Label(errorText, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
        }

        HStack(spacing: 10) {
          TextField("播放列表名称", text: $model.playlistTitle)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("播放列表名称")
          Button {
            Task { await model.makePreview(client: client) }
          } label: {
            Label("预览播放列表", systemImage: "list.bullet.clipboard")
          }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canRequestPreview)
          .help(previewHelp)
        }
      }
      .padding()
    }
    .frame(minWidth: 760, minHeight: 540)
    .task(id: model.selectedItemKeys) {
      await model.ensureSelectedHierarchies(client: client)
    }
    .sheet(isPresented: Binding(
      get: { model.preview != nil },
      set: { if !$0 { model.preview = nil } }
    )) {
      if let preview = model.preview {
        PlaylistCreationPreviewSheet(preview: preview) {
          model.preview = nil
        } create: {
          await model.create(client: client)
          guard model.preview == nil else { return }
          await Task.yield()
          close()
        }
      }
    }
    .onDisappear {
      model.preview = nil
    }
  }

  private var previewHelp: String {
    if !titleIsValid { return "请输入播放列表名称" }
    if model.hierarchyLoadingKeys.contains(where: model.selectedItemKeys.contains) {
      return "正在读取已选番组的季集"
    }
    if !model.hierarchyErrors.keys.filter(model.selectedItemKeys.contains).isEmpty {
      return "请重新读取失败番组的季集"
    }
    if !model.canPreview { return "请为每部番组选择有效的季和集" }
    return "检查播放列表内容后再确认创建"
  }
}

private struct PlaylistEpisodeSelectionRow: View {
  var item: PlaylistQuarterItem
  @ObservedObject var model: PlaylistViewModel
  var retryHierarchy: () -> Void

  private var hierarchy: PlexShowHierarchy? { model.hierarchies[item.key] }
  private var seasonSelection: Binding<Int> {
    Binding(
      get: { model.selectedSeasons[item.key] ?? -1 },
      set: { model.updateSeason(itemKey: item.key, season: $0) }
    )
  }
  private var episodeSelection: Binding<String> {
    Binding(
      get: { model.selectedEpisodes[item.key] ?? "" },
      set: { model.updateEpisode(itemKey: item.key, ratingKey: $0) }
    )
  }
  private var episodes: [PlexEpisode] {
    model.availableEpisodes(itemKey: item.key)
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title)
          .font(.body.weight(.medium))
        Text(item.pairing?.title ?? "等待配对")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(model.episodeSelectionLabel(itemKey: item.key))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(
            model.hierarchyErrors[item.key] == nil
              ? Color.secondary.opacity(0.72)
              : Color.orange
          )
      }
      Spacer(minLength: 12)
      if let hierarchy {
        Picker("季", selection: seasonSelection) {
          Text("选择季").tag(-1)
          ForEach(hierarchy.seasons) { season in
            Text(season.seasonNumber == 0 ? "特别篇" : "第 \(season.seasonNumber) 季").tag(season.seasonNumber)
          }
        }
        .labelsHidden()
        .frame(width: 120)
        Picker("集", selection: episodeSelection) {
          Text("选择集").tag("")
          ForEach(episodes) { episode in
            Text("第 \(episode.episodeNumber) 集 · \(episode.title)").tag(episode.ratingKey)
          }
        }
        .labelsHidden()
        .frame(width: 230)
        .disabled(model.selectedSeasons[item.key] == nil)
      } else if let error = model.hierarchyErrors[item.key] {
        Button("重新读取季集", systemImage: "arrow.clockwise", action: retryHierarchy)
          .help(error)
      } else {
        ProgressView()
          .controlSize(.small)
          .help("正在读取 Plex 季集")
      }
    }
    .padding(.vertical, 3)
  }
}

private struct ManualPlaylistPairingSheet: View {
  var item: PlaylistQuarterItem
  var client: APIClient
  var pair: (PlexShow) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var results: [PlexShow] = []
  @State private var isLoading = false
  @State private var errorText: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("配对 Plex 节目")
            .font(.title3.weight(.semibold))
          Text(item.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: dismiss.callAsFunction)
      }
      .padding()
      Divider()
      HStack(spacing: 8) {
        TextField("搜索 Plex 标题", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit { Task { await search() } }
        Button {
          Task { await search() }
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .help("搜索")
      }
      .padding()
      if let errorText {
        Label(errorText, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .padding(.horizontal)
      }
      List(results) { show in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(show.title)
            HStack(spacing: 8) {
              if let original = show.originalTitle { Text(original) }
              if let year = show.year { Text(String(year)) }
              Text(show.libraryTitle ?? "媒体库 \(show.libraryId)")
              if let seasons = show.seasonCount { Text("\(seasons) 季") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("配对") {
            Task {
              if await pair(show) { dismiss() }
            }
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
      }
      .overlay {
        if isLoading { ProgressView("正在搜索…") }
      }
    }
    .frame(minWidth: 620, minHeight: 480)
    .task { await search(initial: true) }
  }

  private func search(initial: Bool = false) async {
    isLoading = true
    defer { isLoading = false }
    errorText = nil
    do {
      results = try await client.plexShows(query: initial ? item.title : query)
      if initial { query = item.title }
    } catch is CancellationError {
      return
    } catch {
      errorText = error.localizedDescription
    }
  }
}

private struct PlaylistCreationPreviewSheet: View {
  var preview: PlaylistCreatePreviewResponse
  var close: () -> Void
  var create: () async -> Void
  @State private var confirmingCreate = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(preview.title)
            .font(.title3.weight(.semibold))
          Text("\(preview.selectedCount) 部番组 · \(preview.episodeCount) 个有效剧集")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: close)
      }
      .padding()
      Divider()
      List(preview.items) { item in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(item.animeTitle)
            if let showTitle = item.plexShowTitle,
               let seasonNumber = item.seasonNumber,
               let episodeNumber = item.episodeNumber,
               let episodeTitle = item.episodeTitle {
              Text("\(showTitle) · S\(String(format: "%02d", seasonNumber))E\(String(format: "%02d", episodeNumber)) · \(episodeTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let reason = item.reason {
              Text(reason)
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
          Spacer()
          if item.duplicate {
            Label("重复", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
              .font(.caption)
              .foregroundStyle(.orange)
          } else if !item.valid {
            Label("无效", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      if !preview.warnings.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(preview.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
          }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      Divider()
      HStack {
        Button("取消", role: .cancel, action: close)
        Spacer()
        Button {
          confirmingCreate = true
        } label: {
          Label("在 Plex 中创建", systemImage: "plus.rectangle.on.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!preview.canCreate)
      }
      .padding()
    }
    .frame(minWidth: 680, minHeight: 520)
    .confirmationDialog("确认在 Plex 中创建“\(preview.title)”？", isPresented: $confirmingCreate, titleVisibility: .visible) {
      Button("创建播放列表") {
        Task { await create() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将按预览顺序创建一个普通视频播放列表，不会修改现有播放列表或媒体文件。")
    }
  }
}

struct PlaylistDetailSheet: View {
  @EnvironmentObject private var store: AppStore

  var detail: PlexPlaylistDetail
  var close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(detail.playlist.title).font(.title3.weight(.semibold))
          Text("\(detail.items.count) 项").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: close)
      }
      .padding()
      Divider()
      if detail.items.isEmpty {
        ContentUnavailableView("播放列表为空", systemImage: "rectangle.stack.badge.play")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 138, maximum: 182), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 22
          ) {
            ForEach(detail.items) { item in
              DesktopPlaylistPosterCell(
                item: item,
                posterURL: store.backendResourceURL(item.posterUrl)
              )
            }
          }
          .padding(20)
        }
      }
    }
    .frame(minWidth: 760, minHeight: 600)
  }
}

private struct DesktopPlaylistBanner: View {
  var playlist: PlexPlaylistSummary
  var posterURLs: [URL?]
  var isLoading: Bool

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        DesktopPlaylistBannerArtwork(
          posterURLs: posterURLs,
          width: proxy.size.width,
          height: proxy.size.height
        )
        Color.black.opacity(0.23)
        LinearGradient(
          colors: [.black.opacity(0.18), .clear, .black.opacity(0.28)],
          startPoint: .leading,
          endPoint: .trailing
        )
        VStack(spacing: 5) {
          Text(playlist.title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
          Text("\(playlist.itemCount) 项")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 28)
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(12)
        }
      }
    }
    .aspectRatio(5.6, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

private struct DesktopPlaylistBannerArtwork: View {
  var posterURLs: [URL?]
  var width: CGFloat
  var height: CGFloat

  private var resolvedURLs: [URL?] {
    let values = Array(posterURLs.prefix(5))
    return values.isEmpty ? [nil] : values
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(resolvedURLs.enumerated()), id: \.offset) { _, url in
        PlaylistPosterView(
          url: url,
          width: width / CGFloat(resolvedURLs.count),
          height: height,
          showsShadow: false,
          cornerRadius: 0
        )
      }
    }
    .frame(width: width, height: height)
    .clipped()
  }
}

private struct DesktopPlaylistPosterCell: View {
  var item: PlexPlaylistItem
  var posterURL: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { proxy in
        PlaylistPosterView(
          url: posterURL,
          width: proxy.size.width,
          height: proxy.size.height
        )
        .appleTVPosterHover(.grid)
      }
      .aspectRatio(PlaylistLibraryPresentation.posterAspectRatio, contentMode: .fit)

      Text(PlaylistLibraryPresentation.title(for: item))
        .font(.callout.weight(.semibold))
        .lineLimit(2, reservesSpace: true)
      if let episode = PlaylistLibraryPresentation.seasonEpisodeText(for: item) {
        Text(episode)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
