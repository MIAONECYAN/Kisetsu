import SwiftUI

struct MobileOverviewView: View {
  @EnvironmentObject private var store: AppStore
  var isActive: Bool
  @State private var heroSelection = MobileOverviewHeroSelectionState()
  @State private var detailSubscription: Subscription?
  @State private var isRefreshing = false
  @StateObject private var playlists = OverviewPlaylistState()

  private var availableSubscriptions: [Subscription] {
    OverviewPresentation.sourceSubscriptions(
      overviewItems: store.overview?.subscriptionItems,
      fallback: store.subscriptions
    )
  }

  private var focus: [Subscription] {
    OverviewPresentation.focus(subscriptions: availableSubscriptions, overview: store.overview)
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        if !focus.isEmpty {
          MobileOverviewHero(subscriptions: focus, isActive: isActive && detailSubscription == nil && playlists.detail == nil,
            selection: $heroSelection, onOpen: { detailSubscription = $0 })
        }
        if let overview = store.overview, !overview.issues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              sectionHeader("需要处理", section: .history)
              ForEach(overview.issues.prefix(2)) { item in taskLink(item) }
            }
        }
        if !subscriptions.isEmpty { subscriptionRail }
        plexSection
        if let overview = store.overview {
          recentSection(overview)
          let tasks = OverviewPresentation.tasks(overview)
          if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              sectionHeader("当前任务", section: .active)
              ForEach(tasks.prefix(3)) { item in taskLink(item) }
            }
          }
        } else if isRefreshing {
          ProgressView("正在读取概览").frame(maxWidth: .infinity, minHeight: 80)
        } else {
          MobileErrorView(title: "概览暂不可用", message: store.operationStatus.detail) {
            Task { await refresh() }
          }
        }
      }
      .padding(.horizontal, 16)
      .safeAreaPadding(.bottom, 16)
    }
    .mobileNavigationTitle("概览")
    .navigationDestination(item: $detailSubscription) { MobileSubscriptionDetailView(subscription: $0) }
    .sheet(item: $playlists.detail) { MobilePlaylistDetailView(detail: $0) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        MobileToolbarRefreshButton(target: .overview, isDisabled: store.isLoading, isRefreshing: isRefreshing) {
          await refresh()
        }
      }
    }
    .refreshable { await refresh() }
    .task(id: store.backendURL) {
      playlists.reset(endpoint: store.client.baseURL)
      await loadPlaylists()
    }
    .task(id: isActive) {
      guard isActive else { return }
      await refresh()
      guard !MobileDebugConfiguration.usesFixturesAtRuntime else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        guard isActive else { return }
        await store.loadOverview(silent: true)
      }
    }
  }

  private var subscriptionRail: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("我的订阅").font(.headline)
        Spacer()
        NavigationLink { MobileSubscriptionsView(isActive: true) } label: {
          Image(systemName: "chevron.right").frame(width: 44, height: 44)
        }.foregroundStyle(.secondary).accessibilityLabel("查看全部订阅")
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 12) {
          ForEach(subscriptions) { subscription in
            NavigationLink { MobileSubscriptionDetailView(subscription: subscription) } label: {
              VStack(alignment: .leading, spacing: 5) {
                MobilePosterImage(url: store.backendResourceURL(subscription.posterLocalUrl ?? subscription.posterUrl), width: 112, height: 168)
                Text(subscription.name).font(.caption2.weight(.medium)).lineLimit(2, reservesSpace: true)
              }.frame(width: 112, alignment: .leading)
            }.buttonStyle(MobilePressStyle()).accessibilityLabel(subscription.name)
          }
        }
      }.scrollIndicators(.hidden)
    }
  }

  private var subscriptions: [Subscription] { availableSubscriptions }

  private func sectionHeader(_ title: String, section: MobileTaskSection) -> some View {
    HStack {
      Text(title).font(.headline)
      Spacer()
      NavigationLink { MobileTasksView(isActive: true, initialSection: section) } label: {
        Image(systemName: "chevron.right").frame(width: 44, height: 44)
      }
      .accessibilityLabel("查看全部\(title)")
      .foregroundStyle(.secondary)
    }
  }

  private func taskLink(_ item: OverviewItem) -> some View {
    NavigationLink {
      if item.target.targetType == "subscription",
         let id = item.target.subscriptionId,
         let subscription = availableSubscriptions.first(where: { $0.id == id }) {
        MobileSubscriptionDetailView(subscription: subscription)
      } else {
        MobileTasksView(isActive: true, initialSection: taskSection(item))
      }
    } label: {
      MobileOverviewItemRow(item: item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func taskSection(_ item: OverviewItem) -> MobileTaskSection {
    switch item.target.targetType {
    case "organize_preview", "organize_preview_record": .pending
    case "organize_history": .organized
    default: .history
    }
  }

  @ViewBuilder private var plexSection: some View {
    if playlists.configured != false {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Plex 播放列表").font(.headline)
          Spacer()
          NavigationLink { MobilePlaylistView() } label: {
            Image(systemName: "chevron.right").frame(width: 44, height: 44)
          }
          .foregroundStyle(.secondary).accessibilityLabel("查看全部 Plex 播放列表")
        }
        if let error = playlists.error {
          HStack {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("重试", systemImage: "arrow.clockwise") { Task { await loadPlaylists(force: true) } }
              .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
          }
        }
        if playlists.isLoading && playlists.playlists.isEmpty {
          ProgressView().frame(maxWidth: .infinity, minHeight: 64)
        } else if playlists.configured == true && playlists.playlists.isEmpty && playlists.error == nil {
          Text("暂无播放列表").font(.subheadline).foregroundStyle(.secondary)
        } else {
          ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
              ForEach(playlists.playlists.prefix(6)) { playlist in
                Button { Task { await playlists.open(playlist, client: store.client) } } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    MobilePosterImage(url: store.backendResourceURL(playlist.posterUrl), width: 112, height: 168)
                      .overlay {
                        if playlists.loadingDetailID == playlist.id {
                          ProgressView().padding(8).background(.regularMaterial, in: Circle())
                        }
                      }
                    Text(playlist.title).font(.caption.weight(.semibold)).lineLimit(2, reservesSpace: true)
                    Text("\(playlist.itemCount) 项").font(.caption2).foregroundStyle(.secondary)
                  }
                  .frame(width: 112, alignment: .leading)
                }
                .buttonStyle(MobilePressStyle()).disabled(playlists.loadingDetailID != nil)
              }
            }
          }.scrollIndicators(.hidden)
        }
      }
    }
  }

  @ViewBuilder private func recentSection(_ overview: OverviewResponse) -> some View {
    if !overview.recentlyOrganized.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        sectionHeader("最近整理", section: .organized)
        ForEach(overview.recentlyOrganized.prefix(6)) { media in
          NavigationLink {
            if let subscription = availableSubscriptions.first(where: { $0.id == media.subscriptionId }) {
              MobileSubscriptionDetailView(subscription: subscription)
            } else { MobileTasksView(isActive: true, initialSection: .organized) }
          } label: {
            let subscription = availableSubscriptions.first(where: { $0.id == media.subscriptionId })
            HStack(spacing: 12) {
              MobilePosterImage(url: store.backendResourceURL(subscription?.posterLocalUrl ?? subscription?.posterUrl), width: 44, height: 66)
              VStack(alignment: .leading, spacing: 4) {
                Text(media.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(OverviewPresentation.organizedLabel(media)).font(.caption).foregroundStyle(.secondary)
                Text(AppRelativeTime.concise(media.completedAt)).font(.caption2).foregroundStyle(.tertiary)
              }
              Spacer(minLength: 0)
            }
          }.buttonStyle(.plain)
        }
      }
    }
  }

  private func loadPlaylists(force: Bool = false) async {
    #if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      playlists.useFixtures(endpoint: store.client.baseURL)
      return
    }
    #endif
    await playlists.load(client: store.client, force: force)
  }

  private func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      await loadPlaylists()
      return
    }
    guard MobileDebugConfiguration.shouldLoadNetworkAtRuntime else { return }
    await store.loadOverview(silent: true)
    await loadPlaylists(force: true)
  }
}

private struct MobileOverviewHero: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var colorScheme
  var subscriptions: [Subscription]
  var isActive: Bool
  @Binding var selection: MobileOverviewHeroSelectionState
  var onOpen: (Subscription) -> Void
  @GestureState private var isInteracting = false
  @State private var isPressed = false
  @State private var dragTranslation: CGFloat = 0
  @State private var heroWidth: CGFloat = 390

  private var itemIDs: [Int] { subscriptions.map(\.id) }

  private var selectedIndex: Int {
    selection.selectedIndex(in: itemIDs)
  }

  private var featured: Subscription {
    subscriptions[selectedIndex]
  }

  private var canAutoRotate: Bool {
    #if DEBUG
    if MobileDebugConfiguration.disablesFixtureHeroRotation(
      environment: ProcessInfo.processInfo.environment
    ) { return false }
    #endif
    return MobileOverviewHeroRotationPolicy(
      isPageActive: isActive,
      isSceneActive: scenePhase == .active,
      reduceMotion: reduceMotion,
      isInteracting: isInteracting,
      itemCount: subscriptions.count
    ).canRotate
  }

  private var rotationTaskID: MobileOverviewHeroRotationTaskID {
    MobileOverviewHeroRotationTaskID(
      enabled: canAutoRotate,
      generation: selection.rotationGeneration,
      itemIDs: itemIDs
    )
  }

  var body: some View {
      ZStack(alignment: .topTrailing) {
        ZStack(alignment: .bottomLeading) {
          ambientBackground

          HStack(alignment: .bottom, spacing: 16) {
            MobilePosterImage(
              urls: [
                store.backendResourceURL(featured.posterLocalUrl),
                store.backendResourceURL(featured.posterUrl),
                featured.posterUrl.flatMap(URL.init(string:)),
              ],
              width: 104,
              height: 148
            )
            .shadow(color: .black.opacity(0.16), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 8) {
              Text(featured.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
              if let synopsis = OverviewPresentation.synopsis(featured) {
                Text(synopsis)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
              }
              Text(heroSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
              if let progress = SubscriptionTargetProgressPresentation(subscription: featured).metrics {
                Text("下载 \(progress.downloadedText) · 整理 \(progress.organizedText)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(18)
          .id(featured.id)
          .transition(heroTransition)
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(height: heroHeight, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        if subscriptions.count > 1 {
          Text("\(selectedIndex + 1)/\(subscriptions.count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .padding(10)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .offset(x: heroDragOffset)
    .scaleEffect(reduceMotion || !isPressed || isInteracting ? 1 : 0.975)
    .opacity(isPressed && !isInteracting ? 0.96 : 1)
    .animation(
      reduceMotion ? MobileMotion.pressOut : (isPressed ? MobileMotion.pressIn : MobileMotion.pressOut),
      value: isPressed && !isInteracting
    )
    .onTapGesture { onOpen(featured) }
    .onLongPressGesture(minimumDuration: .infinity, pressing: { isPressed = $0 }, perform: {})
    .simultaneousGesture(horizontalSwipeGesture)
    .onChange(of: isInteracting) { _, interacting in
      guard !interacting else { return }
      settleDrag()
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      heroWidth = max(width, 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("推荐订阅，\(featured.name)，第 \(selectedIndex + 1) 个，共 \(subscriptions.count) 个")
    .accessibilityHint("轻点打开详情，左右轻扫切换")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onOpen(featured) }
    .accessibilityAction(named: "上一部") { move(by: -1, restartsClock: true) }
    .accessibilityAction(named: "下一部") { move(by: 1, restartsClock: true) }
    .onAppear { selection.synchronize(itemIDs: itemIDs) }
    .onChange(of: itemIDs) { _, newIDs in selection.synchronize(itemIDs: newIDs) }
    .task(id: rotationTaskID) {
      guard rotationTaskID.enabled else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(12))
        } catch {
          return
        }
        guard canAutoRotate else { return }
        move(by: 1, restartsClock: false)
      }
    }
  }

  private var ambientBackground: some View {
    let palette = SubscriptionPalettePresentation.colors(
      palette: featured.posterPalette,
      colorScheme: colorScheme
    )
    let style = SubscriptionPalettePresentation.ambientStyle(colorScheme: colorScheme)
    return ZStack {
      Color(.systemBackground)
      LinearGradient(
        colors: [
          palette.background.opacity(style.backgroundOpacity),
          palette.primary.opacity(style.primaryOpacity),
          palette.secondary.opacity(style.secondaryOpacity),
          .clear,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private var heroSubtitle: String {
    OverviewPresentation.focusDetail(featured, overview: store.overview)
  }

  private var heroTransition: AnyTransition {
    .opacity
  }

  private var horizontalSwipeGesture: some Gesture {
    DragGesture(minimumDistance: 18)
      .updating($isInteracting) { _, interacting, _ in
        interacting = true
      }
      .onChanged { value in
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        guard !reduceMotion else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          dragTranslation = MobileOverviewHeroGesturePhysics.resistedTranslation(
            value.translation.width,
            dimension: heroWidth
          )
        }
      }
      .onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height) else {
          settleDrag()
          return
        }
        let shouldMove = MobileOverviewHeroGesturePhysics.shouldMove(
          translation: value.translation.width,
          predictedEndTranslation: value.predictedEndTranslation.width,
          dimension: heroWidth
        )
        guard shouldMove else {
          settleDrag()
          return
        }
        move(by: value.translation.width < 0 ? 1 : -1, restartsClock: true)
      }
  }

  private var heroDragOffset: CGFloat {
    reduceMotion ? 0 : dragTranslation
  }

  private var heroHeight: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? 260 : 184
  }

  private func move(by step: Int, restartsClock: Bool) {
    let animation = reduceMotion ? MobileMotion.reducedFade : (restartsClock ? MobileMotion.hero : .easeOut(duration: 0.22))
    withAnimation(animation) {
      dragTranslation = 0
      selection.move(by: step, itemIDs: itemIDs, restartsClock: restartsClock)
    }
  }

  private func settleDrag() {
    guard dragTranslation != 0 else { return }
    withAnimation(reduceMotion ? MobileMotion.reducedFade : MobileMotion.hero) {
      dragTranslation = 0
    }
  }
}

enum MobileOverviewHeroGesturePhysics {
  static let directTravel: CGFloat = 56

  static func resistedTranslation(_ translation: CGFloat, dimension: CGFloat) -> CGFloat {
    let magnitude = abs(translation)
    guard magnitude > directTravel else { return translation }
    let overflow = magnitude - directTravel
    let available = max(dimension - directTravel, 1)
    let rubberBand = (1 - (1 / ((overflow * 0.55 / available) + 1))) * available
    return (translation < 0 ? -1 : 1) * (directTravel + rubberBand)
  }

  static func shouldMove(
    translation: CGFloat,
    predictedEndTranslation: CGFloat,
    dimension: CGFloat
  ) -> Bool {
    guard translation.isFinite, predictedEndTranslation.isFinite, dimension.isFinite,
          translation != 0 else { return false }
    let distanceThreshold = max(44, min(72, dimension * 0.14))
    // The system projection includes release momentum; callback timing does not.
    guard predictedEndTranslation == 0
      || (translation > 0) == (predictedEndTranslation > 0) else { return false }
    return abs(translation) >= distanceThreshold
      || (abs(predictedEndTranslation) >= distanceThreshold
        && abs(predictedEndTranslation) > abs(translation))
  }
}

private struct MobileOverviewHeroRotationTaskID: Hashable {
  var enabled: Bool
  var generation: Int
  var itemIDs: [Int]
}

struct MobileOverviewHeroRotationPolicy: Equatable {
  var isPageActive: Bool
  var isSceneActive: Bool
  var reduceMotion: Bool
  var isInteracting: Bool
  var itemCount: Int

  var canRotate: Bool {
    isPageActive
      && isSceneActive
      && !reduceMotion
      && !isInteracting
      && itemCount > 1
  }
}

struct MobileOverviewHeroSelectionState: Equatable {
  private(set) var selectedSubscriptionID: Int?
  private(set) var rotationGeneration = 0
  private(set) var navigationDirection = 1
  private var knownItemIDs: [Int] = []

  func selectedIndex(in itemIDs: [Int]) -> Int {
    guard let selectedSubscriptionID,
          let index = itemIDs.firstIndex(of: selectedSubscriptionID) else { return 0 }
    return index
  }

  mutating func synchronize(itemIDs: [Int]) {
    let previousIndex = selectedIndex(in: knownItemIDs)
    knownItemIDs = itemIDs
    guard !itemIDs.isEmpty else {
      selectedSubscriptionID = nil
      return
    }
    if let selectedSubscriptionID, itemIDs.contains(selectedSubscriptionID) { return }
    selectedSubscriptionID = itemIDs[min(previousIndex, itemIDs.count - 1)]
  }

  mutating func move(by step: Int, itemIDs: [Int], restartsClock: Bool) {
    guard !itemIDs.isEmpty else {
      selectedSubscriptionID = nil
      return
    }
    let currentIndex = selectedIndex(in: itemIDs)
    let nextIndex = (currentIndex + step % itemIDs.count + itemIDs.count) % itemIDs.count
    navigationDirection = step < 0 ? -1 : 1
    selectedSubscriptionID = itemIDs[nextIndex]
    if restartsClock { rotationGeneration += 1 }
  }
}

private struct MobileOverviewItemRow: View {
  var item: OverviewItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: item.systemImage ?? "circle.fill")
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        if let subtitle = item.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if let detail = item.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      if let status = item.status, !status.isEmpty {
        MobileTag(text: status, tint: tint)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var tint: Color {
    switch item.severity {
    case "error": .red
    case "warning": .orange
    case "success": .green
    default: .secondary
    }
  }
}
