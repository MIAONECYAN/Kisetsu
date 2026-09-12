import AppKit
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var store: AppStore
  @State private var heroSelection = DashboardHeroSelectionState()
  @StateObject private var playlists = OverviewPlaylistState()
  var navigate: (AppSection) -> Void

  private var overview: OverviewResponse? { store.overview }
  private var availableSubscriptions: [Subscription] {
    OverviewPresentation.sourceSubscriptions(
      overviewItems: overview?.subscriptionItems,
      fallback: store.subscriptions
    )
  }
  private var showcaseSubscriptions: [Subscription] {
    OverviewPresentation.focus(subscriptions: availableSubscriptions, overview: overview)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if !showcaseSubscriptions.isEmpty {
          DashboardHeroPanel(
            subscriptions: showcaseSubscriptions,
            downloadingItems: overview?.downloadingItems ?? [],
            pendingOrganizeItems: overview?.pendingOrganizeItems ?? [],
            issues: overview?.issues ?? [],
            selection: $heroSelection,
            open: { subscription in
              Task {
                await store.loadSubscriptionDetail(for: subscription)
                navigate(.subscriptions)
              }
            }
          )
        }
        if let overview, !overview.issues.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            heading("需要处理") { openTasks(.history) }
            ForEach(overview.issues.prefix(2)) { item in overviewRow(item) }
          }
        }
        if !subscriptions.isEmpty { subscriptionRail }
        plexSection
        VStack(alignment: .leading, spacing: 24) {
          recentlyOrganized
          currentTasks
        }
      }
      .padding(24)
      .frame(maxWidth: 1240, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .task(id: store.backendURL) {
      playlists.reset(endpoint: store.client.baseURL)
      #if DEBUG
      if DesktopDebugConfiguration.usesPlaylistFixtures {
        playlists.useFixtures(endpoint: store.client.baseURL)
        return
      }
      #endif
      await store.loadOverview(silent: true)
      await playlists.load(client: store.client)
    }
    .sheet(item: $playlists.detail) { detail in
      PlaylistDetailSheet(detail: detail) { playlists.detail = nil }
    }
  }

  private var subscriptionRail: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("我的订阅").font(.headline)
        Spacer()
        Button("查看全部", systemImage: "chevron.right") { navigate(.subscriptions) }
          .labelStyle(.iconOnly).buttonStyle(.plain).help("查看全部订阅")
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 14) {
          ForEach(subscriptions) { subscription in
            Button {
              Task { await store.loadSubscriptionDetail(for: subscription); navigate(.subscriptions) }
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                PlaylistPosterView(url: store.backendResourceURL(subscription.posterLocalUrl ?? subscription.posterUrl), width: 112, height: 168)
                Text(subscription.name).font(.caption).lineLimit(2, reservesSpace: true)
              }.frame(width: 112, alignment: .leading)
            }.buttonStyle(.plain)
          }
        }
      }.scrollIndicators(.hidden)
    }
  }

  private var subscriptions: [Subscription] { availableSubscriptions }

  private func heading(_ title: String, action: @escaping () -> Void) -> some View {
    HStack {
      Text(title).font(.headline)
      Spacer()
      Button("查看全部", systemImage: "chevron.right", action: action)
        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        .help("查看全部\(title)")
    }
  }

  @ViewBuilder private var plexSection: some View {
    if playlists.configured != false {
      VStack(alignment: .leading, spacing: 14) {
        heading("Plex 播放列表") { navigate(.playlists) }
        if let error = playlists.error {
          HStack {
            Text(error).font(.callout).foregroundStyle(.secondary)
            Button("重试", systemImage: "arrow.clockwise") { Task { await playlists.load(client: store.client, force: true) } }
              .labelStyle(.iconOnly)
          }
        }
        if playlists.isLoading && playlists.playlists.isEmpty { ProgressView() }
        if playlists.configured == true && playlists.playlists.isEmpty && playlists.error == nil {
          Text("暂无播放列表").font(.callout).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 184), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
          ForEach(playlists.playlists.prefix(6)) { playlist in
            Button { Task { await playlists.open(playlist, client: store.client) } } label: {
              VStack(alignment: .leading, spacing: 7) {
                PlaylistPosterView(url: store.backendResourceURL(playlist.posterUrl), width: 142, height: 213)
                  .overlay {
                    if playlists.loadingDetailID == playlist.id {
                      ProgressView().controlSize(.small).padding(8).background(.regularMaterial, in: Circle())
                    }
                  }
                Text(playlist.title).font(.callout.weight(.medium)).lineLimit(2, reservesSpace: true)
                Text("\(playlist.itemCount) 项").font(.caption).foregroundStyle(.secondary)
              }.frame(width: 142, alignment: .leading)
            }
            .buttonStyle(.plain).disabled(playlists.loadingDetailID != nil)
          }
        }
      }
    }
  }

  @ViewBuilder private var recentlyOrganized: some View {
    if let overview, !overview.recentlyOrganized.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        heading("最近整理") { openTasks(.organized) }
        ForEach(overview.recentlyOrganized.prefix(6)) { media in
          let subscription = availableSubscriptions.first(where: { $0.id == media.subscriptionId })
          Button {
            if let subscription {
              Task { await store.loadSubscriptionDetail(for: subscription); navigate(.subscriptions) }
            } else { openTasks(.organized) }
          } label: {
            HStack(spacing: 12) {
              PlaylistPosterView(url: store.backendResourceURL(subscription?.posterLocalUrl ?? subscription?.posterUrl), width: 44, height: 66)
              VStack(alignment: .leading, spacing: 4) {
                Text(media.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(OverviewPresentation.organizedLabel(media)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              Text(AppRelativeTime.concise(media.completedAt)).font(.caption).foregroundStyle(.tertiary)
            }
          }.buttonStyle(.plain)
        }
      }
    }
  }

  @ViewBuilder private var currentTasks: some View {
    if let overview {
      let tasks = OverviewPresentation.tasks(overview)
      if !tasks.isEmpty {
        VStack(alignment: .leading, spacing: 14) {
          heading("当前任务") { openTasks(.active) }
          ForEach(tasks.prefix(5)) { item in overviewRow(item) }
        }
      }
    }
  }

  private func overviewRow(_ item: OverviewItem) -> some View {
    Button { handleOverviewItem(item) } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: item.systemImage ?? "arrow.down.circle")
          .foregroundStyle(item.severity == "error" ? Color.orange : Color.secondary).frame(width: 22)
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
          if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain)
  }

  private func openTasks(_ section: DesktopTaskSection) {
    store.requestedTaskSection = section.rawValue
    navigate(.tasks)
  }

  private func handleOverviewItem(_ item: OverviewItem) {
    switch item.target.targetType {
    case "subscription":
      if let id = Int(item.target.targetId ?? ""),
       let subscription = availableSubscriptions.first(where: { $0.id == id }) {
        Task {
          await store.loadSubscriptionDetail(for: subscription)
          navigate(.subscriptions)
        }
      } else {
        navigate(.subscriptions)
      }
    case "organize_preview":
      Task {
        if await openPendingOrganize(item) {
          return
        }
        navigate(.tasks)
      }
    case "organize_preview_record":
      Task {
        if await openOrganizePreviewRecord(item) {
          return
        }
        navigate(.tasks)
      }
    case "organize_history":
      openTasks(.organized)
    case "download_history":
      store.selectedHistorySubscriptionID = item.target.subscriptionId
      openTasks(.history)
    default:
      navigate(.dashboard)
    }
  }

  private func openPendingOrganize(_ item: OverviewItem) async -> Bool {
    guard let historyIDText = item.target.targetId,
          let historyID = Int(historyIDText) else {
      return false
    }

    if let subscriptionID = item.target.subscriptionId,
       let subscription = availableSubscriptions.first(where: { $0.id == subscriptionID }) {
      await store.loadSubscriptionDetail(for: subscription)
      if let detail = store.selectedSubscriptionDetail {
        let resources = detail.episodeStatuses.flatMap(\.matchedResources) + detail.unmatchedResources
        if let resource = resources.first(where: { $0.downloadRecordId == historyID }) {
          await store.previewResource(resource)
          return store.organizePreview != nil
        }
      }
    }

    if let history = store.history.first(where: { $0.id == historyID }) {
      await store.previewHistoryItem(history)
      return store.organizePreview != nil
    }
    await store.loadHistory(silent: true)
    if let history = store.history.first(where: { $0.id == historyID }) {
      await store.previewHistoryItem(history)
      return store.organizePreview != nil
    }
    return false
  }

  private func openOrganizePreviewRecord(_ item: OverviewItem) async -> Bool {
    guard let recordIDText = item.target.targetId,
          let recordID = Int(recordIDText) else {
      return false
    }
    await store.loadOrganizePreviews()
    guard let record = store.organizePreviewHistory.first(where: { $0.id == recordID }) else {
      return false
    }
    store.selectPreviewRecord(record)
    store.showingBatchOrganizeSheet = true
    return true
  }
}


private struct DashboardHeroPanel: View {
  @EnvironmentObject private var store: AppStore
  var subscriptions: [Subscription]
  var downloadingItems: [OverviewItem]
  var pendingOrganizeItems: [OverviewItem]
  var issues: [OverviewItem]
  @Binding var selection: DashboardHeroSelectionState
  var open: (Subscription) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHeroHovering = false
  @State private var isApplicationActive = NSApplication.shared.isActive

  private var heroItems: [Subscription] {
    subscriptions
  }

  private var featured: Subscription? {
    guard !heroItems.isEmpty else { return nil }
    return heroItems[selectedIndex]
  }

  private var selectedIndex: Int {
    selection.selectedIndex(in: heroItemIDs)
  }

  private var heroItemIDs: [Int] {
    heroItems.map(\.id)
  }

  private var canAutoRotate: Bool {
    heroItems.count > 1
      && !isHeroHovering
      && !selection.isRailInteractionActive
      && isApplicationActive
      && !reduceMotion
  }

  private var rotationTaskID: HeroRotationTaskID {
    HeroRotationTaskID(
      enabled: canAutoRotate,
      generation: selection.rotationGeneration,
      itemIDs: heroItemIDs
    )
  }

  private var heroMetrics: DashboardHeroMetrics {
    DashboardHeroMetrics(
      subscriptionID: featured?.id,
      downloadingItems: downloadingItems,
      pendingOrganizeItems: pendingOrganizeItems,
      issues: issues
    )
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Button {
        if let featured {
          open(featured)
        }
      } label: {
        ZStack(alignment: .bottomLeading) {
          PosterAmbientBackground(palette: featured?.posterPalette, isEmphasized: true)

          HStack(alignment: .bottom, spacing: 18) {
            if let featured {
              PlaylistPosterView(
                url: store.backendResourceURL(featured.posterLocalUrl ?? featured.posterUrl),
                width: 112,
                height: 158
              )
                .appleTVPosterHover(.hero)
            }

            VStack(alignment: .leading, spacing: 10) {
              Text(featured?.name ?? "动漫媒体库")
                .font(.title.weight(.semibold))
                .lineLimit(2)
              if let featured {
                if let synopsis = OverviewPresentation.synopsis(featured) {
                  Text(synopsis)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                }
                Text(OverviewPresentation.focusDetail(featured, overview: store.overview))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                if let progress = SubscriptionTargetProgressPresentation(subscription: featured).metrics {
                  Text("下载 \(progress.downloadedText) · 整理 \(progress.organizedText)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
              }
            }
            Spacer(minLength: 12)
          }
          .padding(22)
          .id(featured?.id ?? -1)
          .transition(heroTransition)
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(height: 230)
        .clipped()
      }
      .buttonStyle(.plain)

      if heroItems.count > 1 {
        HStack(spacing: 8) {
          heroArrow(systemName: "chevron.left") {
            selectPrevious()
          }
          Text("\(selectedIndex + 1) / \(heroItems.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 36)
            .accessibilityLabel("第 \(selectedIndex + 1) 部，共 \(heroItems.count) 部")
          heroArrow(systemName: "chevron.right") {
            selectNext()
          }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
          Capsule()
            .stroke(KisetsuStyle.subtleBorder)
        }
        .padding(.top, 16)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
    }
    .onHover { hovering in
      isHeroHovering = hovering
    }
    .onAppear {
      isApplicationActive = NSApplication.shared.isActive
      selection.synchronize(itemIDs: heroItemIDs)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      isApplicationActive = true
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      isApplicationActive = false
    }
    .onChange(of: heroItemIDs) { _, _ in
      selection.synchronize(itemIDs: heroItemIDs)
    }
    .onDisappear { isApplicationActive = false; selection.endInteractions() }
    .task(id: rotationTaskID) {
      guard rotationTaskID.enabled else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(12))
        } catch {
          return
        }
        guard canAutoRotate else { return }
        moveSelection(by: 1, restartsClock: false)
      }
    }
  }

  private var heroTransition: AnyTransition {
    guard !reduceMotion, selection.navigationDirection != 0 else {
      return .opacity
    }
    return .opacity
  }


  private func heroArrow(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(systemName == "chevron.left" ? "上一部订阅" : "下一部订阅")
  }

  private func selectPrevious() {
    moveSelection(by: -1, restartsClock: true)
  }

  private func selectNext() {
    moveSelection(by: 1, restartsClock: true)
  }

  private func moveSelection(by step: Int, restartsClock: Bool) {
    guard !heroItems.isEmpty else { return }
    withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.22)) {
      selection.move(by: step, itemIDs: heroItemIDs, restartsClock: restartsClock)
    }
  }
}

private struct HeroRotationTaskID: Hashable {
  var enabled: Bool
  var generation: Int
  var itemIDs: [Int]
}

struct DashboardHeroSelectionState: Equatable {
  private(set) var selectedSubscriptionID: Int?
  private(set) var hoveredSubscriptionID: Int?
  private(set) var focusedSubscriptionID: Int?
  private(set) var pendingHoveredSubscriptionID: Int?
  private(set) var isRailHovered = false
  private(set) var isRailScrolling = false
  private(set) var rotationGeneration = 0
  private(set) var navigationDirection = 1
  private var knownItemIDs: [Int] = []

  var isRailInteractionActive: Bool {
    isRailHovered
      || isRailScrolling
      || hoveredSubscriptionID != nil
      || focusedSubscriptionID != nil
  }

  func selectedIndex(in itemIDs: [Int]) -> Int {
    guard let selectedSubscriptionID,
          let index = itemIDs.firstIndex(of: selectedSubscriptionID) else {
      return 0
    }
    return index
  }

  mutating func synchronize(itemIDs: [Int]) {
    let previousItemIDs = knownItemIDs
    let previousIndex = selectedSubscriptionID.flatMap { previousItemIDs.firstIndex(of: $0) } ?? 0
    let itemsChanged = previousItemIDs != itemIDs
    knownItemIDs = itemIDs

    if let hoveredSubscriptionID, !itemIDs.contains(hoveredSubscriptionID) {
      self.hoveredSubscriptionID = nil
    }
    if let focusedSubscriptionID, !itemIDs.contains(focusedSubscriptionID) {
      self.focusedSubscriptionID = nil
    }
    if let pendingHoveredSubscriptionID, !itemIDs.contains(pendingHoveredSubscriptionID) {
      self.pendingHoveredSubscriptionID = nil
    }

    guard !itemIDs.isEmpty else {
      selectedSubscriptionID = nil
      if itemsChanged {
        restartRotationClock()
      }
      return
    }
    if let selectedSubscriptionID, itemIDs.contains(selectedSubscriptionID) {
      if itemsChanged {
        restartRotationClock()
      }
      return
    }

    selectedSubscriptionID = itemIDs[min(previousIndex, itemIDs.count - 1)]
    if itemsChanged {
      restartRotationClock()
    }
  }

  mutating func move(by step: Int, itemIDs: [Int], restartsClock: Bool) {
    guard !itemIDs.isEmpty else { return }
    synchronizeIfNeeded(itemIDs: itemIDs)
    navigationDirection = step < 0 ? -1 : 1
    let nextIndex = (selectedIndex(in: itemIDs) + step + itemIDs.count) % itemIDs.count
    selectedSubscriptionID = itemIDs[nextIndex]
    if restartsClock {
      restartRotationClock()
    }
  }

  mutating func setHoveredSubscription(_ id: Int, hovering: Bool, itemIDs: [Int]) {
    synchronizeIfNeeded(itemIDs: itemIDs)
    guard itemIDs.contains(id) else { return }

    if isRailScrolling {
      if hovering {
        pendingHoveredSubscriptionID = id
      } else if pendingHoveredSubscriptionID == id {
        pendingHoveredSubscriptionID = nil
      }
      return
    }

    if hovering {
      hoveredSubscriptionID = id
      select(id, itemIDs: itemIDs, isPreview: true)
    } else if hoveredSubscriptionID == id {
      hoveredSubscriptionID = nil
    }
  }

  mutating func setRailScrolling(_ scrolling: Bool, itemIDs: [Int]) {
    synchronizeIfNeeded(itemIDs: itemIDs)
    guard isRailScrolling != scrolling else { return }
    isRailScrolling = scrolling

    if scrolling {
      pendingHoveredSubscriptionID = hoveredSubscriptionID
      return
    }

    let pendingID = pendingHoveredSubscriptionID
    pendingHoveredSubscriptionID = nil
    hoveredSubscriptionID = nil
    if let pendingID, itemIDs.contains(pendingID) {
      hoveredSubscriptionID = pendingID
      select(pendingID, itemIDs: itemIDs, isPreview: true)
    } else if !isRailHovered {
      restartRotationClock()
    }
  }

  mutating func setFocusedSubscription(_ id: Int?, itemIDs: [Int]) {
    synchronizeIfNeeded(itemIDs: itemIDs)
    let previousID = focusedSubscriptionID
    guard let id else {
      focusedSubscriptionID = nil
      if previousID != nil {
        restartRotationClock()
      }
      return
    }
    guard itemIDs.contains(id) else { return }
    focusedSubscriptionID = id
    select(id, itemIDs: itemIDs, isPreview: true)
  }

  mutating func setRailHovered(_ hovering: Bool) {
    guard isRailHovered != hovering else { return }
    isRailHovered = hovering
    if !hovering {
      hoveredSubscriptionID = nil
      pendingHoveredSubscriptionID = nil
      restartRotationClock()
    }
  }

  mutating func endInteractions() {
    let wasInteracting = isRailInteractionActive
    isRailHovered = false
    isRailScrolling = false
    hoveredSubscriptionID = nil
    focusedSubscriptionID = nil
    pendingHoveredSubscriptionID = nil
    if wasInteracting {
      restartRotationClock()
    }
  }

  private mutating func select(_ id: Int, itemIDs: [Int], isPreview: Bool) {
    let currentIndex = selectedIndex(in: itemIDs)
    guard let targetIndex = itemIDs.firstIndex(of: id) else { return }
    if selectedSubscriptionID != id {
      navigationDirection = isPreview ? 0 : (targetIndex < currentIndex ? -1 : 1)
      selectedSubscriptionID = id
    }
  }

  private mutating func synchronizeIfNeeded(itemIDs: [Int]) {
    if knownItemIDs != itemIDs {
      synchronize(itemIDs: itemIDs)
    }
  }

  private mutating func restartRotationClock() {
    rotationGeneration += 1
  }
}

struct DashboardHeroMetrics: Equatable {
  var downloadingCount: Int
  var pendingOrganizeCount: Int
  var issueCount: Int

  init(
    subscriptionID: Int?,
    downloadingItems: [OverviewItem],
    pendingOrganizeItems: [OverviewItem],
    issues: [OverviewItem]
  ) {
    guard let subscriptionID else {
      downloadingCount = 0
      pendingOrganizeCount = 0
      issueCount = 0
      return
    }
    downloadingCount = downloadingItems.count {
      $0.target.subscriptionId == subscriptionID
    }
    pendingOrganizeCount = pendingOrganizeItems.count {
      $0.target.subscriptionId == subscriptionID
    }
    issueCount = issues.count {
      $0.target.subscriptionId == subscriptionID
    }
  }
}

enum DashboardSubscriptionShowcaseData {
  static func items(from subscriptions: [Subscription]) -> [Subscription] { subscriptions }
}
