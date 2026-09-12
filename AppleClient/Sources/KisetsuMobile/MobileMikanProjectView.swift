import SwiftUI

struct MobileMikanProjectView: View {
  @EnvironmentObject private var store: AppStore
  @State private var selection = MikanProjectSectionKind.monday

  private var selectedSection: MikanProjectSection? {
    store.mikanProjectSeason?.visibleSections.first(where: { $0.id == selection })
  }

  var body: some View {
    List {
      if let season = store.mikanProjectSeason {
        Section {
          Picker("播出日期", selection: $selection) {
            ForEach(season.visibleSections) { section in
              Text(section.shortName).tag(section.id)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        .listRowBackground(Color.clear)

        ForEach(selectedSection?.items ?? []) { anime in
          NavigationLink {
            MobileMikanAnimeDetailView(anime: anime)
          } label: {
            HStack(alignment: .top, spacing: 14) {
              MobileMikanPoster(
                anime: anime,
                width: MobilePosterSizing.primaryListWidth,
                height: MobilePosterSizing.primaryListHeight,
                store: store
              )
              VStack(alignment: .leading, spacing: 5) {
                Text(anime.title).font(.headline).lineLimit(2)
                if let original = anime.originalTitle, !original.isEmpty {
                  Text(original).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                MobileTagFlowLayout {
                  if let time = anime.broadcastStart { MobileTag(text: time, systemImage: "clock") }
                  if let count = anime.resourceCount { MobileTag(text: "\(count) 个资源") }
                }
              }
            }
            .padding(.vertical, 3)
          }
        }
      } else if store.mikanProjectSeasonLoading {
        ProgressView("正在读取 Mikan Project")
          .frame(maxWidth: .infinity, minHeight: 360)
          .listRowBackground(Color.clear)
      } else {
        MobileErrorView(
          title: "无法加载 Mikan Project",
          message: store.mikanProjectSeasonError ?? "尚未缓存当季番组。"
        ) {
          Task { await store.refreshMikanProjectSeason() }
        }
        .frame(minHeight: 360)
        .listRowBackground(Color.clear)
      }
    }
    .listStyle(.plain)
    .mobileStatusNavigationTitle("Mikan Project")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        MobileToolbarRefreshButton(target: .mikan, isRefreshing: store.mikanProjectSeasonLoading) {
          guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
          await store.refreshMikanProjectSeason()
        }
      }
    }
    .refreshable {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.refreshMikanProjectSeason()
    }
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadMikanProjectSeason(silent: true)
      synchronizeSelection()
    }
    .onChange(of: store.mikanProjectSeason) { _, _ in synchronizeSelection() }
  }

  private func synchronizeSelection() {
    guard let season = store.mikanProjectSeason else { return }
    var state = MikanProjectSelectionState(selectedSection: selection)
    state.synchronize(with: season)
    selection = state.selectedSection
  }
}

private struct MobileMikanAnimeDetailView: View {
  @EnvironmentObject private var store: AppStore
  var anime: MikanProjectAnime
  @State private var pendingDownload: SearchResult?
  @State private var showingSubscriptionEditor = false
  @State private var selectedFansubID: String?

  private var resources: MikanProjectResourcesResponse? {
    store.mikanProjectResources[anime.bangumiId]
  }

  var body: some View {
    List {
      Section {
        HStack(alignment: .top, spacing: 16) {
          MobileMikanPoster(anime: anime, width: 96, height: 138, store: store)
          VStack(alignment: .leading, spacing: 7) {
            Text(anime.title).font(.title3.weight(.semibold))
            if let original = anime.originalTitle { Text(original).font(.subheadline).foregroundStyle(.secondary) }
            if let date = anime.airDate { Label(date, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
          }
        }
        if let synopsis = anime.synopsis, !synopsis.isEmpty {
          Text(synopsis).font(.subheadline).foregroundStyle(.secondary)
        }
      }

      if let resources {
        if resources.groups.count > 1 {
          Section {
            Picker("字幕组", selection: $selectedFansubID) {
              Text("全部字幕组").tag(nil as String?)
              ForEach(resources.groups) { group in
                Text("\(group.fansub) · \(group.resources.count)").tag(Optional(group.id))
              }
            }
            .pickerStyle(.menu)
          }
        }
        ForEach(filteredGroups(resources)) { group in
          Section("\(group.fansub) · \(group.resources.count)") {
            ForEach(group.resources) { result in
              VStack(alignment: .leading, spacing: 7) {
                Text(result.title).font(.subheadline.weight(.medium)).lineLimit(3)
                MobileTagFlowLayout {
                  if let size = result.size { MobileTag(text: size) }
                  if let resolution = result.parsedResolution { MobileTag(text: resolution) }
                  if let episode = result.parsedDisplayEpisodeLabel { MobileTag(text: episode) }
                }
                HStack {
                  Button { smartSubscribe(result, group: group) } label: {
                    Image(systemName: MobileMikanPresentation.smartSubscriptionSymbol)
                  }
                  .labelStyle(.iconOnly)
                  .buttonStyle(.glass)
                  .controlSize(MobileMikanPresentation.resourceActionControlSize)
                  .frame(width: 44, height: 44)
                  .contentShape(Rectangle())
                  .accessibilityLabel("智能订阅")
                  .accessibilityHint("根据此资源准备订阅表单")
                  Spacer()
                  Button("下载", systemImage: "arrow.down.circle") { pendingDownload = result }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(MobileMikanPresentation.resourceActionControlSize)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityHint("将此资源添加到下载")
                }
              }
              .padding(.vertical, 4)
            }
          }
        }
      } else if store.mikanProjectResourceLoadingIDs.contains(anime.bangumiId) {
        ProgressView("正在读取资源")
          .frame(maxWidth: .infinity, minHeight: 220)
          .listRowBackground(Color.clear)
      }
    }
    .mobileStatusNavigationTitle(anime.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadMikanProjectResources(for: anime)
    }
    .refreshable {
      guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
      await store.loadMikanProjectResources(for: anime)
    }
    .onChange(of: resources) { _, newValue in
      guard let selectedFansubID,
            newValue?.groups.contains(where: { $0.id == selectedFansubID }) == true else {
        self.selectedFansubID = nil
        return
      }
    }
    .sheet(isPresented: $showingSubscriptionEditor) {
      MobileSubscriptionEditorView().environmentObject(store)
    }
    .alert("添加到下载？", isPresented: Binding(
      get: { pendingDownload != nil },
      set: { if !$0 { pendingDownload = nil } }
    )) {
      Button("添加") {
        guard let result = pendingDownload else { return }
        Task { _ = await store.addDownload(result) }
        pendingDownload = nil
      }
      Button("取消", role: .cancel) { pendingDownload = nil }
    } message: {
      Text(pendingDownload?.title ?? "")
    }
  }

  private func filteredGroups(_ resources: MikanProjectResourcesResponse) -> [MikanProjectResourceGroup] {
    MobileMikanPresentation.filteredGroups(resources.groups, selectedID: selectedFansubID)
  }

  private func smartSubscribe(_ result: SearchResult, group: MikanProjectResourceGroup) {
    Task {
      guard let response = await store.suggestSubscription(from: result),
            let suggestion = response.suggestion else { return }
      let url = anime.detailUrl ?? anime.bangumiUrl
      store.prepareSubscriptionForm(
        from: response,
        suggestion: suggestion,
        result: result,
        mikanBangumiURL: url,
        availableFansubs: resources?.groups.map(\.fansub) ?? [group.fansub]
      )
      showingSubscriptionEditor = true
    }
  }
}

private struct MobileMikanPoster: View {
  var anime: MikanProjectAnime
  var width: CGFloat
  var height: CGFloat
  var store: AppStore

  var body: some View {
    MobilePosterImage(
      url: store.backendResourceURL(anime.posterLocalUrl ?? anime.posterUrl),
      width: width,
      height: height
    )
    .overlay(alignment: .topLeading) {
      if anime.subscribed {
        Text(MobileMikanPresentation.subscribedMarkerTitle)
          .font(.system(size: 9, weight: .semibold))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.thinMaterial, in: Capsule())
          .padding(4)
          .accessibilityLabel("已订阅")
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(anime.subscribed ? "\(anime.title)，已订阅" : "\(anime.title)，未订阅")
  }
}
