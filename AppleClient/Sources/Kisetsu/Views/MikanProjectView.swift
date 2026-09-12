import SwiftUI

struct MikanProjectView: View {
  @EnvironmentObject private var store: AppStore
  @State private var selectionState = MikanProjectSelectionState()
  @State private var selectedAnime: MikanProjectAnime?
  @State private var showingSubscriptionEditor = false
  @State private var lastAutoRefreshCheck = Date.distantPast
  @FocusState private var detailOverlayFocused: Bool

  private let columns = [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 18, alignment: .top)]
  private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        header
          .appToolbarSurface()

        if let season = store.mikanProjectSeason {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              sectionTabs(season.visibleSections)
              let items = selectedItems(in: season)
              if items.isEmpty {
                emptySectionState
              } else {
                animeGrid(for: items)
              }
            }
            .padding(KisetsuStyle.pagePadding)
          }
        } else if let error = store.mikanProjectSeasonError, !store.mikanProjectSeasonLoading {
          ContentUnavailableView {
            Label("无法加载 Mikan Project", systemImage: "exclamationmark.triangle")
          } description: {
            Text(error)
          } actions: {
            Button("重试") {
              store.startMikanProjectSeasonLoad()
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView("正在加载 Mikan Project", systemImage: "calendar", description: Text(" "))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }

      if let selectedAnime {
        detailOverlay(for: selectedAnime)
          .transition(.opacity.combined(with: .scale(scale: 0.985)))
          .zIndex(10)
      }
    }
    .animation(.easeInOut(duration: 0.16), value: selectedAnime?.id)
    .onExitCommand {
      selectedAnime = nil
    }
    .onAppear {
      if store.mikanProjectSeason == nil {
        store.startMikanProjectSeasonLoad()
      }
    }
    .onChange(of: store.mikanProjectSeason?.sections.map(\.id), initial: true) { _, _ in
      guard let season = store.mikanProjectSeason else { return }
      selectionState.synchronize(with: season)
    }
    .onReceive(timer) { _ in
      guard shouldAutoRefresh else { return }
      lastAutoRefreshCheck = Date()
      store.startMikanProjectSeasonLoad(silent: true)
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
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(store.mikanProjectSeason?.seasonTitle ?? "Mikan Project")
          .font(.title2.weight(.semibold))
        HStack(spacing: 8) {
          if let cachedAt = store.mikanProjectSeason?.cachedAt {
            Label(AppRelativeTime.concise(cachedAt), systemImage: "clock")
          }
          if let warning = store.mikanProjectSeason?.warnings.first {
            Label(StatusLabels.message(warning), systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          } else if let error = store.mikanProjectSeasonError {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer()

      Toggle("隐藏已订阅", isOn: $store.mikanProjectHideSubscribed)
        .toggleStyle(.switch)
        .controlSize(.small)

      Toggle("自动刷新", isOn: Binding {
        store.mikanProjectSettings.autoRefreshEnabled
      } set: { value in
        store.mikanProjectSettings.autoRefreshEnabled = value
        Task { await store.saveMikanProjectSettings() }
      })
      .toggleStyle(.switch)
      .controlSize(.small)

      Stepper(value: Binding {
        store.mikanProjectSettings.refreshIntervalHours
      } set: { value in
        store.mikanProjectSettings.refreshIntervalHours = value
        Task { await store.saveMikanProjectSettings() }
      }, in: 1...168) {
        Text("\(store.mikanProjectSettings.refreshIntervalHours) 小时")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 48, alignment: .trailing)
      }
      .controlSize(.small)

      Button {
        store.startMikanProjectSeasonRefresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("强制刷新")
      .disabled(store.mikanProjectSeasonLoading)
    }
  }

  private func sectionTabs(_ sections: [MikanProjectSection]) -> some View {
    Picker("星期", selection: $selectionState.selectedSection) {
      ForEach(sections) { section in
        Text(section.name).tag(section.id)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("Mikan Project 栏目")
    .frame(maxWidth: 720)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func animeGrid(for items: [MikanProjectAnime]) -> some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
      ForEach(items) { anime in
        MikanProjectAnimeCard(anime: anime) {
          selectedAnime = anime
        }
      }
    }
  }

  private func selectedItems(in season: MikanProjectSeasonResponse) -> [MikanProjectAnime] {
    let items = selectionState.items(in: season)
    guard store.mikanProjectHideSubscribed else { return items }
    return items.filter { !$0.subscribed }
  }

  private var emptySectionState: some View {
    ContentUnavailableView(
      selectionState.selectedSection == .movie ? "暂无剧场版" : "暂无番组",
      systemImage: selectionState.selectedSection == .movie ? "film" : "calendar"
    )
    .frame(maxWidth: .infinity, minHeight: 240)
  }

  private var shouldAutoRefresh: Bool {
    guard store.mikanProjectSettings.autoRefreshEnabled else { return false }
    guard Date().timeIntervalSince(lastAutoRefreshCheck) > Double(store.mikanProjectSettings.refreshIntervalHours * 3600) else { return false }
    return store.mikanProjectSeason != nil
  }

  private func detailOverlay(for anime: MikanProjectAnime) -> some View {
    ZStack {
      Color.black.opacity(0.12)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($detailOverlayFocused)
        .onKeyPress(.escape) {
          selectedAnime = nil
          return .handled
        }
        .onTapGesture {
          selectedAnime = nil
        }

      MikanProjectDetailSheet(
        anime: anime,
        response: store.mikanProjectResources[anime.bangumiId],
        isLoading: store.mikanProjectResourceLoadingIDs.contains(anime.bangumiId),
        close: {
          selectedAnime = nil
        },
        suggestSubscription: { result in
          Task {
            if let response = await store.suggestSubscription(from: result, sitesOverride: ["mikan"]),
               let suggestion = response.suggestion {
              let currentAnime = store.mikanProjectResources[anime.bangumiId]?.anime ?? anime
              store.prepareSubscriptionForm(
                from: response,
                suggestion: suggestion,
                result: result,
                mikanBangumiURL: mikanBangumiURL(for: currentAnime, result: result),
                availableFansubs: store.mikanProjectResources[anime.bangumiId]?.groups.map(\.fansub) ?? []
              )
              showingSubscriptionEditor = true
            }
          }
        }
      )
      .task {
        await store.loadMikanProjectResources(for: anime)
      }
      .padding(34)
    }
    .onAppear {
      DispatchQueue.main.async {
        detailOverlayFocused = true
      }
    }
  }

  private func mikanBangumiURL(for anime: MikanProjectAnime, result: SearchResult) -> String {
    let baseURL: String
    if let detailUrl = anime.detailUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
       detailUrl.contains("/Home/Bangumi/") {
      baseURL = detailUrl
    } else {
      baseURL = "https://mikanani.me/Home/Bangumi/\(anime.bangumiId)"
    }
    guard let groupID = result.mikanGroupId, !groupID.isEmpty else {
      return baseURL
    }
    return "\(baseURL.split(separator: "#", maxSplits: 1).first.map(String.init) ?? baseURL)#\(groupID)"
  }
}

private struct MikanProjectAnimeCard: View {
  var anime: MikanProjectAnime
  var open: () -> Void

  private static let cardWidth: CGFloat = 148
  private static let posterHeight: CGFloat = 210
  private static let titleHeight: CGFloat = 40
  private static let metadataHeight: CGFloat = 16

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .topLeading) {
          PosterView(urlString: anime.posterLocalUrl ?? anime.posterUrl, width: Self.cardWidth, height: Self.posterHeight)
            .saturation(anime.isGrayscale ? 0 : 1)
            .contrast(anime.isGrayscale ? 0.92 : 1)
          if anime.subscribed {
            Text("已订阅")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(.thinMaterial, in: Capsule())
              .padding(6)
          }
        }
        .overlay(alignment: .topTrailing) {
          if let count = anime.resourceCount, count > 0 {
            Text("\(count)")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .frame(width: 22, height: 22)
              .background(Color.red, in: Circle())
              .padding(6)
          }
        }
        .appleTVPosterHover(.grid)
        Text(anime.title)
          .font(.callout.weight(.semibold))
          .lineLimit(2)
          .frame(width: Self.cardWidth, height: Self.titleHeight, alignment: .topLeading)
        Group {
          if let updateDate = anime.statusText ?? anime.updateDate, !updateDate.isEmpty {
            Label(updateDate, systemImage: "calendar")
          } else {
            Color.clear
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: Self.cardWidth, height: Self.metadataHeight, alignment: .leading)
      }
      .frame(width: Self.cardWidth, alignment: .topLeading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct MikanProjectDetailSheet: View {
  var anime: MikanProjectAnime
  var response: MikanProjectResourcesResponse?
  var isLoading: Bool
  var close: () -> Void
  var suggestSubscription: (SearchResult) -> Void
  @State private var selectedFansubID: String?
  @Environment(\.colorScheme) private var colorScheme

  private var displayAnime: MikanProjectAnime {
    response?.anime ?? anime
  }

  private var modalBackground: Color {
    colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      detailHeader

      if groups.count > 1 {
        fansubTabs
      }

      resourceContent
    }
    .padding(16)
    .frame(minWidth: 920, idealWidth: 1040, maxWidth: 1120, minHeight: 560, idealHeight: 660, maxHeight: 780)
    .background(modalBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(KisetsuStyle.subtleBorder)
    }
  }

  private var detailHeader: some View {
    HStack(alignment: .center, spacing: 20) {
      PosterView(urlString: displayAnime.posterLocalUrl ?? displayAnime.posterUrl, width: 112, height: 158)
        .saturation(displayAnime.isGrayscale ? 0 : 1)
        .contrast(displayAnime.isGrayscale ? 0.92 : 1)
        .appleTVPosterHover(.hero)

      VStack(alignment: .leading, spacing: 9) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(displayAnime.title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
          if displayAnime.subscribed {
            Text("已订阅")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.ultraThinMaterial, in: Capsule())
          }
        }

        if let original = displayAnime.originalTitle, original != displayAnime.title {
          Text(original)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        detailPills

        if let synopsis = nonEmpty(displayAnime.synopsis) {
          Text(synopsis)
            .font(.callout)
            .foregroundStyle(.primary.opacity(0.74))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
        }

        linkRow
      }

      Spacer(minLength: 12)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      PosterAmbientBackground(palette: displayAnime.posterPalette, isEmphasized: true)
    }
    .clipShape(RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
        .stroke(KisetsuStyle.subtleBorder)
    }
    .overlay(alignment: .topTrailing) {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .background(.ultraThinMaterial, in: Circle())
      .overlay {
        Circle()
          .stroke(KisetsuStyle.subtleBorder)
      }
      .padding(14)
      .help("关闭")
    }
  }

  private var detailPills: some View {
    HStack(spacing: 8) {
      if let value = nonEmpty(displayAnime.broadcastDay) {
        MikanDetailHeroPill(title: "放送日期", value: value)
      }
      if let value = nonEmpty(displayAnime.broadcastStart ?? displayAnime.airDate) {
        MikanDetailHeroPill(title: "放送开始", value: value)
      }
      if let total = displayAnime.totalEpisodes {
        MikanDetailHeroPill(title: "总集数", value: "\(total)")
      }
      MikanDetailHeroPill(title: "资源", value: "\(resourceCount)")
    }
    .lineLimit(1)
  }

  @ViewBuilder
  private var linkRow: some View {
    let official = url(displayAnime.officialUrl)
    let bangumi = url(displayAnime.bangumiUrl)
    if official != nil || bangumi != nil {
      HStack(spacing: 10) {
        if let official {
          Link(destination: official) {
            Label("官方网站", systemImage: "safari")
          }
        }
        if let bangumi {
          Link(destination: bangumi) {
            Label("Bangumi 番组计划", systemImage: "book")
          }
        }
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(KisetsuStyle.animeTint)
    }
  }

  private var fansubTabs: some View {
    Picker("字幕组", selection: Binding(
      get: { activeFansubID ?? "" },
      set: { selectedFansubID = $0 }
    )) {
      ForEach(groups) { group in
        Text("\(group.fansub) \(group.resources.count)")
          .tag(group.id)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: 520, alignment: .leading)
  }

  private var resourceContent: some View {
    Group {
      if isLoading && response == nil {
        Text("正在获取资源...")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if groups.isEmpty {
        ContentUnavailableView("暂无资源", systemImage: "tray", description: Text(" "))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let group = selectedGroup {
        VStack(alignment: .leading, spacing: 10) {
          resourceHeader(group)

          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(group.resources.enumerated()), id: \.element.id) { index, result in
                VStack(spacing: 0) {
                  SearchResultRow(result: result) {
                    suggestSubscription(result)
                  }
                  .padding(.horizontal, 12)
                  if index != group.resources.count - 1 {
                    Divider()
                      .padding(.leading, 12)
                  }
                }
              }
            }
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(modalBackground)
      } else {
        Color.clear
      }
    }
    .background(modalBackground)
  }

  private func resourceHeader(_ group: MikanProjectResourceGroup) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Text("资源")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      Text("\(group.fansub) \(group.resources.count) 条")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
    }
  }

  private var groups: [MikanProjectResourceGroup] {
    response?.groups ?? []
  }

  private var resourceCount: Int {
    groups.reduce(0) { $0 + $1.resources.count }
  }

  private var activeFansubID: String? {
    if let selectedFansubID, groups.contains(where: { $0.id == selectedFansubID }) {
      return selectedFansubID
    }
    return groups.first?.id
  }

  private var selectedGroup: MikanProjectResourceGroup? {
    guard let activeFansubID else { return nil }
    return groups.first { $0.id == activeFansubID }
  }

  private func nonEmpty(_ value: String?) -> String? {
    let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return cleaned.isEmpty ? nil : cleaned
  }

  private func url(_ value: String?) -> URL? {
    guard let cleaned = nonEmpty(value) else { return nil }
    return URL(string: cleaned)
  }
}

private struct MikanDetailHeroPill: View {
  var title: String
  var value: String

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
  }
}
