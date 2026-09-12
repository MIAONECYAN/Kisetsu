import SwiftUI

private enum MobilePlaylistMode: String, CaseIterable, Identifiable {
  case existing
  case generate
  var id: String { rawValue }
  var title: String { self == .existing ? "现有列表" : "番组信息" }
}

@MainActor
private final class MobilePlaylistModel: ObservableObject {
  @Published var mode = MobilePlaylistMode.existing
  @Published var playlists: [PlexPlaylistSummary] = []
  @Published var detail: PlexPlaylistDetail?
  @Published var artworkItems: [String: [PlexPlaylistItem]] = [:]
  @Published var artworkLoadingKeys: Set<String> = []
  @Published var quarters: [PlaylistQuarterOption] = []
  @Published var selectedQuarter: PlaylistQuarterOption?
  @Published var quarter: PlaylistQuarterResponse?
  @Published var selectedKeys: Set<String> = []
  @Published var pairingTarget: PlaylistQuarterItem?
  @Published var hierarchies: [String: PlexShowHierarchy] = [:]
  @Published var seasonSelections: [String: Int] = [:]
  @Published var episodeSelections: [String: String] = [:]
  @Published var preview: PlaylistCreatePreviewResponse?
  @Published var title = ""
  @Published var isLoading = false
  @Published var loadingDetailRatingKey: String?
  @Published var error: String?
  @Published var message: String?

  var selectedItems: [PlaylistQuarterItem] {
    (quarter?.items ?? []).filter { selectedKeys.contains($0.key) && $0.pairing?.valid == true }
  }

  func load(client: APIClient, refresh: Bool = false) async {
#if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      loadFixtures()
      return
    }
#endif
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      if mode == .existing {
        if refresh { artworkItems.removeAll() }
        playlists = try await client.plexPlaylists()
        let validKeys = Set(playlists.map(\.ratingKey))
        artworkItems = artworkItems.filter { validKeys.contains($0.key) }
      } else {
        quarters = try await client.playlistQuarters(refresh: refresh)
        let option = selectedQuarter ?? quarters.first
        if let option { await load(option, client: client, refresh: refresh) }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  func load(_ option: PlaylistQuarterOption, client: APIClient, refresh: Bool = false) async {
    selectedQuarter = option
    title = "\(option.year) 年 \(option.month) 月番组"
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      quarter = try await client.playlistQuarter(year: option.year, month: option.month, refresh: refresh)
      let valid = Set((quarter?.items ?? []).filter { $0.pairing?.valid == true }.map(\.key))
      selectedKeys.formIntersection(valid)
    } catch {
      self.error = error.localizedDescription
    }
  }

  func toggle(_ item: PlaylistQuarterItem) {
    guard item.pairing?.valid == true, item.matchState == "matched" else {
      pairingTarget = item
      return
    }
    if selectedKeys.remove(item.key) != nil {
      seasonSelections[item.key] = nil
      episodeSelections[item.key] = nil
    } else {
      selectedKeys.insert(item.key)
    }
  }

  func loadHierarchy(for item: PlaylistQuarterItem, client: APIClient) async {
    guard hierarchies[item.key] == nil, let key = item.pairing?.plexRatingKey else { return }
    do {
      let hierarchy = try await client.plexShowHierarchy(ratingKey: key)
      hierarchies[item.key] = hierarchy
      if let firstSeason = hierarchy.seasons.first(where: { !$0.episodes.filter(\.playable).isEmpty }) {
        seasonSelections[item.key] = seasonSelections[item.key] ?? firstSeason.seasonNumber
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  func episodes(for item: PlaylistQuarterItem) -> [PlexEpisode] {
    guard let season = seasonSelections[item.key] else { return [] }
    return hierarchies[item.key]?.seasons.first(where: { $0.seasonNumber == season })?.episodes.filter(\.playable) ?? []
  }

  func pair(_ item: PlaylistQuarterItem, show: PlexShow, client: APIClient) async -> Bool {
    do {
      _ = try await client.pairPlaylistItem(PairingRequest(itemKey: item.key, plexRatingKey: show.ratingKey))
      if let selectedQuarter { await load(selectedQuarter, client: client) }
      pairingTarget = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func unpair(_ item: PlaylistQuarterItem, client: APIClient) async {
    do {
      _ = try await client.unpairPlaylistItem(itemKey: item.key)
      selectedKeys.remove(item.key)
      if let selectedQuarter { await load(selectedQuarter, client: client) }
    } catch {
      self.error = error.localizedDescription
    }
  }

  func loadDetail(_ playlist: PlexPlaylistSummary, client: APIClient) async {
    guard loadingDetailRatingKey == nil else { return }
    loadingDetailRatingKey = playlist.ratingKey
    defer { loadingDetailRatingKey = nil }
#if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      try? await Task.sleep(for: .milliseconds(450))
      detail = PlaylistDebugFixtures.detail(for: playlist.ratingKey)
      return
    }
#endif
    if let cachedItems = artworkItems[playlist.ratingKey] {
      detail = PlexPlaylistDetail(playlist: playlist, items: cachedItems)
      return
    }
    do { detail = try await client.plexPlaylistDetail(ratingKey: playlist.ratingKey) }
    catch { self.error = error.localizedDescription }
  }

  func loadArtwork(for playlist: PlexPlaylistSummary, client: APIClient) async {
    guard artworkItems[playlist.ratingKey] == nil,
          artworkLoadingKeys.insert(playlist.ratingKey).inserted else { return }
    defer { artworkLoadingKeys.remove(playlist.ratingKey) }
#if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      artworkItems[playlist.ratingKey] = PlaylistDebugFixtures.detail(for: playlist.ratingKey).items
      return
    }
#endif
    do {
      artworkItems[playlist.ratingKey] = try await client
        .plexPlaylistDetail(ratingKey: playlist.ratingKey).items
    } catch is CancellationError {
      return
    } catch {
      return
    }
  }

#if DEBUG
  private func loadFixtures() {
    isLoading = false
    error = nil
    if mode == .existing {
      playlists = PlaylistDebugFixtures.playlists
      if let requestedDetail = MobileDebugConfiguration.initialPlaylistDetail(
        environment: ProcessInfo.processInfo.environment
      ) {
        detail = PlaylistDebugFixtures.detail(for: requestedDetail)
      } else {
        detail = nil
      }
      return
    }

    quarters = MobileDebugFixtureData.playlistQuarters
    let option = selectedQuarter ?? quarters[0]
    selectedQuarter = option
    title = "\(option.year) 年 \(option.month) 月番组"
    quarter = MobileDebugFixtureData.playlistQuarter
    hierarchies = ["fixture-playlist-1": MobileDebugFixtureData.playlistHierarchy]
    let valid = Set((quarter?.items ?? []).filter { $0.pairing?.valid == true }.map(\.key))
    selectedKeys.formIntersection(valid)
  }
#endif

  func makePreview(client: APIClient) async {
    guard let quarter = selectedQuarter else { return }
    let selections = selectedItems.compactMap { item -> PlaylistSelection? in
      guard let episode = episodeSelections[item.key] else { return nil }
      return PlaylistSelection(itemKey: item.key, episodeRatingKey: episode)
    }
    guard selections.count == selectedItems.count, !selections.isEmpty else {
      error = "请为每个番组选定季和集数。"
      return
    }
    do {
      preview = try await client.previewPlaylistCreation(
        PlaylistCreatePreviewRequest(title: title, year: quarter.year, month: quarter.month, selections: selections)
      )
    } catch {
      self.error = error.localizedDescription
    }
  }

  func create(client: APIClient) async {
    guard let preview else { return }
    do {
      let response = try await client.createPlexPlaylist(
        PlaylistCreateRequest(confirmationToken: preview.confirmationToken, confirm: true)
      )
      message = response.message
      self.preview = nil
      selectedKeys = []
      mode = .existing
      playlists = try await client.plexPlaylists()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct MobilePlaylistView: View {
  @EnvironmentObject private var store: AppStore
  @StateObject private var model = MobilePlaylistModel()
  @State private var showingSelection = false

  var body: some View {
    VStack(spacing: 0) {
      Picker("播放列表视图", selection: $model.mode) {
        ForEach(MobilePlaylistMode.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(model.isLoading)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      if model.mode == .existing {
        existingRows
      } else {
        List { generatorRows }
          .listStyle(.plain)
      }
    }
    .mobileStatusNavigationTitle("播放列表")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if model.mode == .generate {
          Button("创建清单", systemImage: "rectangle.stack.badge.plus") { showingSelection = true }
            .disabled(model.selectedItems.isEmpty)
        }
        MobileToolbarRefreshButton(target: .playlists, isRefreshing: model.isLoading) {
          await model.load(client: store.client, refresh: true)
        }
      }
    }
    .task(id: model.mode) {
      await model.load(client: store.client)
    }
    .sheet(item: $model.detail) { detail in
      MobilePlaylistDetailView(detail: detail)
    }
    .sheet(item: $model.pairingTarget) { item in
      MobilePlaylistPairingSheet(item: item) { show in
        await model.pair(item, show: show, client: store.client)
      }
    }
    .sheet(isPresented: $showingSelection) {
      MobilePlaylistSelectionSheet(model: model, client: store.client) {
        showingSelection = false
      }
    }
    .alert("播放列表", isPresented: Binding(
      get: { model.message != nil || model.error != nil },
      set: { if !$0 { model.message = nil; model.error = nil } }
    )) {
      Button("好") { model.message = nil; model.error = nil }
    } message: {
      Text(model.error ?? model.message ?? "")
    }
  }

  @ViewBuilder
  private var existingRows: some View {
    if model.playlists.isEmpty && model.isLoading {
      ProgressView("正在读取播放列表")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.playlists.isEmpty {
      ContentUnavailableView("没有播放列表", systemImage: "rectangle.stack.badge.play")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(model.playlists) { playlist in
            let isLoadingDetail = model.loadingDetailRatingKey == playlist.ratingKey
            Button { Task { await model.loadDetail(playlist, client: store.client) } } label: {
              MobilePlaylistBanner(
                playlist: playlist,
                posterURLs: bannerPosterURLs(for: playlist),
                isLoading: isLoadingDetail
              )
            }
            .buttonStyle(MobilePressStyle())
            .disabled(model.loadingDetailRatingKey != nil)
            .accessibilityLabel(playlist.title)
            .accessibilityValue("\(playlist.itemCount) 项\(isLoadingDetail ? "，正在加载详情" : "")")
            .task(id: playlist.ratingKey) {
              await model.loadArtwork(for: playlist, client: store.client)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
      }
    }
  }

  private func bannerPosterURLs(for playlist: PlexPlaylistSummary) -> [URL?] {
    let itemURLs = (model.artworkItems[playlist.ratingKey] ?? [])
      .compactMap(\.posterUrl)
      .prefix(4)
      .map(store.backendResourceURL)
    if !itemURLs.isEmpty { return Array(itemURLs) }
    return [store.backendResourceURL(playlist.posterUrl)]
  }

  @ViewBuilder
  private var generatorRows: some View {
    Section {
      Menu {
        ForEach(Array(Set(model.quarters.map(\.year))).sorted(by: >), id: \.self) { year in
          Menu("\(year) 年") {
            ForEach(model.quarters.filter { $0.year == year }) { option in
              Button("\(option.month) 月 · \(option.count) 部") {
                Task { await model.load(option, client: store.client) }
              }
            }
          }
        }
      } label: {
        LabeledContent("季度", value: model.selectedQuarter?.title ?? "选择季度")
      }
      .disabled(model.isLoading)
      if !model.selectedItems.isEmpty {
        Text("已选择 \(model.selectedItems.count) 部番组")
          .font(.caption).foregroundStyle(.secondary)
      }
    }

    if model.quarter?.items.isEmpty == false {
      ForEach(model.quarter?.items ?? []) { item in
        MobilePlaylistAnimeRow(
          item: item,
          posterURL: store.backendResourceURL(item.posterUrl),
          selected: model.selectedKeys.contains(item.key),
          toggle: { model.toggle(item) },
          unpair: { Task { await model.unpair(item, client: store.client) } },
          pair: { model.pairingTarget = item }
        )
      }
    } else if model.isLoading {
      ProgressView("正在读取番组信息")
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowBackground(Color.clear)
    } else {
      ContentUnavailableView("没有季度番组", systemImage: "calendar")
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowBackground(Color.clear)
    }
  }
}

private struct MobilePlaylistAnimeRow: View {
  var item: PlaylistQuarterItem
  var posterURL: URL?
  var selected: Bool
  var toggle: () -> Void
  var unpair: () -> Void
  var pair: () -> Void

  private var schedule: PlaylistSchedulePresentation {
    PlaylistSchedulePresenter.presentation(begin: item.begin, broadcast: item.broadcast, mediaType: item.mediaType)
  }

  private var linkGroups: [PlaylistExternalLinkGroup] {
    PlaylistExternalLinkPresenter.groups(for: item.links)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack(alignment: .topLeading) {
        MobilePosterImage(
          url: posterURL,
          width: MobilePosterSizing.primaryListWidth,
          height: MobilePosterSizing.primaryListHeight
        )
        if item.pairing?.valid == true && item.matchState == "matched" {
          Button(action: toggle) {
            Image(systemName: MobilePlaylistActionPresentation.selectionSymbol(isSelected: selected))
              .font(.system(size: MobilePlaylistActionPresentation.selectionVisualSize, weight: .regular))
              .symbolRenderingMode(.monochrome)
              .foregroundStyle(.primary)
              .opacity(MobilePlaylistActionPresentation.selectionOpacity(isSelected: selected))
              .padding(3)
              .background(.thinMaterial, in: Circle())
              .overlay {
                Circle().stroke(.primary.opacity(0.10), lineWidth: 0.5)
              }
              .frame(width: 44, height: 44, alignment: .topLeading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(4)
          .accessibilityLabel(selected ? "取消选择 \(item.title)" : "选择 \(item.title)")
          .accessibilityHint("加入或移出播放列表创建清单")
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(item.title).font(.headline).lineLimit(2)
        if !item.originalTitle.isEmpty && item.originalTitle != item.title {
          Text(item.originalTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Text([MobilePlaylistAnimePresentation.mediaType(item.mediaType), item.begin.isEmpty && item.broadcast == nil ? nil : schedule.dateText].compactMap { $0 }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let broadcast = schedule.scheduleText {
          Text(broadcast).font(.caption).foregroundStyle(.secondary)
        }
        if let pairing = item.pairing, pairing.valid {
          Label("Plex · \(pairing.title)", systemImage: "checkmark.circle")
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
          Text(MobilePlaylistAnimePresentation.pairingSummary(pairing))
            .font(.caption2).foregroundStyle(.secondary)
        } else {
          Text(item.pairing == nil ? "未配对" : "配对已失效")
            .font(.caption).foregroundStyle(.secondary)
        }
        MobileTagFlowLayout(
          horizontalSpacing: MobilePlaylistActionPresentation.actionSpacing,
          verticalSpacing: MobilePlaylistActionPresentation.actionSpacing
        ) {
          Button(action: pair) {
            actionSymbol(MobilePlaylistActionPresentation.pairingSymbol(isPaired: item.pairing?.valid == true))
          }
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
          .accessibilityLabel(MobilePlaylistActionPresentation.pairingAccessibilityLabel(isPaired: item.pairing?.valid == true))
          .accessibilityValue(item.pairing?.valid == true ? "已配对到 \(item.pairing?.title ?? "Plex 节目")" : "未配对")
          if item.pairing?.valid == true {
            Menu {
              if let pairing = item.pairing, !pairing.reason.isEmpty {
                Section("匹配依据") { Text(pairing.reason) }
              }
              Button("取消配对", systemImage: "link.badge.minus", role: .destructive, action: unpair)
            } label: {
              actionSymbol("ellipsis")
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("配对操作")
            .accessibilityValue("已配对到 \(item.pairing?.title ?? "Plex 节目")")
          }
          ForEach(linkGroups) { group in
            Menu {
              ForEach(group.links) { link in
                Link(destination: link.url) {
                  Label(link.title, systemImage: "arrow.up.right")
                }
              }
            } label: {
              actionSymbol(group.systemImage)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("\(item.title)，\(group.title)")
            .accessibilityIdentifier("playlist-links-\(item.key)-\(group.kind)")
          }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
  }

  private func actionSymbol(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: MobileTaskActionPresentation.symbolSize, weight: .semibold))
      .frame(width: MobileTaskActionPresentation.visibleSize, height: MobileTaskActionPresentation.visibleSize)
  }
}

private struct MobilePlaylistPairingSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  var item: PlaylistQuarterItem
  var pair: (PlexShow) async -> Bool
  @State private var query = ""
  @State private var shows: [PlexShow] = []
  @State private var isLoading = false

  var body: some View {
    NavigationStack {
      List(shows) { show in
        Button {
          Task { if await pair(show) { dismiss() } }
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(show.title).font(.headline).foregroundStyle(.primary)
            Text([show.originalTitle, show.year.map(String.init), show.libraryTitle].compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .overlay {
        if shows.isEmpty && !isLoading {
          ContentUnavailableView("搜索 Plex 节目", systemImage: "magnifyingglass")
        }
      }
      .mobileStatusNavigationTitle("配对 · \(item.title)")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "搜索 Plex 节目")
      .onSubmit(of: .search) { search() }
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
  }

  private func search() {
    Task {
      isLoading = true
      shows = (try? await store.client.plexShows(query: query)) ?? []
      isLoading = false
    }
  }
}

private struct MobilePlaylistSelectionSheet: View {
  @ObservedObject var model: MobilePlaylistModel
  var client: APIClient
  var close: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section("播放列表") {
          MobileFormTextField(label: "播放列表名称", prompt: "例如：2026 年 1 月番组", text: $model.title)
        }
        ForEach(model.selectedItems) { item in
          Section(item.title) {
            if let hierarchy = model.hierarchies[item.key] {
              Picker("季", selection: Binding(
                get: { model.seasonSelections[item.key] ?? hierarchy.seasons.first?.seasonNumber ?? 1 },
                set: { model.seasonSelections[item.key] = $0; model.episodeSelections[item.key] = nil }
              )) {
                ForEach(hierarchy.seasons) { season in
                  Text(season.seasonNumber == 0 ? "特别篇" : "第 \(season.seasonNumber) 季").tag(season.seasonNumber)
                }
              }
              Picker("集", selection: Binding(
                get: { model.episodeSelections[item.key] ?? "" },
                set: { model.episodeSelections[item.key] = $0 }
              )) {
                Text("请选择").tag("")
                ForEach(model.episodes(for: item)) { episode in
                  Text("第 \(episode.episodeNumber) 集 · \(episode.title)").tag(episode.ratingKey)
                }
              }
            } else {
              ProgressView("正在读取季集")
                .task { await model.loadHierarchy(for: item, client: client) }
            }
          }
        }
      }
      .mobileStatusNavigationTitle("创建清单")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消", action: close) }
        ToolbarItem(placement: .confirmationAction) {
          Button("预览") { Task { await model.makePreview(client: client) } }
            .disabled(model.selectedItems.isEmpty || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .sheet(isPresented: Binding(
        get: { model.preview != nil },
        set: { if !$0 { model.preview = nil } }
      )) {
        if let preview = model.preview {
          MobilePlaylistPreviewSheet(preview: preview) {
            Task { await model.create(client: client); close() }
          } cancel: {
            model.preview = nil
          }
        }
      }
    }
  }
}

private struct MobilePlaylistPreviewSheet: View {
  var preview: PlaylistCreatePreviewResponse
  var create: () -> Void
  var cancel: () -> Void

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("名称", value: preview.title)
          LabeledContent("番组", value: "\(preview.selectedCount)")
          LabeledContent("剧集", value: "\(preview.episodeCount)")
        }
        ForEach(0..<preview.items.count, id: \.self) { index in
          let item = preview.items[index]
          VStack(alignment: .leading, spacing: 4) {
            Text(item.animeTitle).font(.headline)
            Text([item.plexShowTitle, item.seasonNumber.map { "第 \($0) 季" }, item.episodeNumber.map { "第 \($0) 集" }].compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary)
            if let reason = item.reason {
              Text(reason)
                .font(.caption2)
                .foregroundStyle(item.valid ? Color.secondary : Color.red)
            }
          }
        }
      }
      .mobileStatusNavigationTitle("确认播放列表")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("返回", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("创建", action: create)
            .disabled(!preview.canCreate)
        }
      }
    }
  }
}

struct MobilePlaylistDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: AppStore
  var detail: PlexPlaylistDetail

  var body: some View {
    NavigationStack {
      GeometryReader { proxy in
        let spacing: CGFloat = 10
        let horizontalPadding: CGFloat = 16
        let width = floor(
          (proxy.size.width - horizontalPadding * 2 - spacing * CGFloat(PlaylistLibraryPresentation.mobileColumnCount - 1))
            / CGFloat(PlaylistLibraryPresentation.mobileColumnCount)
        )

        if detail.items.isEmpty {
          ContentUnavailableView("播放列表为空", systemImage: "rectangle.stack.badge.play")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVGrid(
              columns: Array(
                repeating: GridItem(.fixed(width), spacing: spacing, alignment: .top),
                count: PlaylistLibraryPresentation.mobileColumnCount
              ),
              alignment: .leading,
              spacing: 18
            ) {
              ForEach(detail.items) { item in
                MobilePlaylistPosterCell(
                  item: item,
                  posterURL: store.backendResourceURL(item.posterUrl ?? detail.playlist.posterUrl),
                  width: width
                )
              }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
          }
        }
      }
      .mobileStatusNavigationTitle(detail.playlist.title)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
  }

}

private struct MobilePlaylistBanner: View {
  var playlist: PlexPlaylistSummary
  var posterURLs: [URL?]
  var isLoading: Bool

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        MobilePlaylistBannerArtwork(
          posterURLs: posterURLs,
          width: proxy.size.width,
          height: proxy.size.height
        )
        Color.black.opacity(0.24)
        LinearGradient(
          colors: [.black.opacity(0.16), .clear, .black.opacity(0.30)],
          startPoint: .leading,
          endPoint: .trailing
        )

        VStack(spacing: 5) {
          Text(playlist.title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
          Text("\(playlist.itemCount) 项")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 20)

        if isLoading {
          ProgressView()
            .tint(.white)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(10)
        }
      }
    }
    .aspectRatio(2.72, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.white.opacity(0.16), lineWidth: 0.5)
    }
  }
}

private struct MobilePlaylistBannerArtwork: View {
  var posterURLs: [URL?]
  var width: CGFloat
  var height: CGFloat

  private var resolvedURLs: [URL?] {
    let values = Array(posterURLs.prefix(4))
    return values.isEmpty ? [nil] : values
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(resolvedURLs.enumerated()), id: \.offset) { _, url in
        MobilePosterImage(
          url: url,
          width: width / CGFloat(resolvedURLs.count),
          height: height,
          cornerRadius: 0,
          showsPlaceholderSymbol: false
        )
      }
    }
    .frame(width: width, height: height)
    .clipped()
  }
}

private struct MobilePlaylistPosterCell: View {
  var item: PlexPlaylistItem
  var posterURL: URL?
  var width: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      MobilePosterImage(
        url: posterURL,
        width: width,
        height: width / PlaylistLibraryPresentation.posterAspectRatio
      )
      Text(PlaylistLibraryPresentation.title(for: item))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(2, reservesSpace: true)
      if let episode = PlaylistLibraryPresentation.seasonEpisodeText(for: item) {
        Text(episode)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
