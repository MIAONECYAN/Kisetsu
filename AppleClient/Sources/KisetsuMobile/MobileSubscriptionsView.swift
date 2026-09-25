import SwiftUI

struct MobileSubscriptionsView: View {
  @EnvironmentObject private var store: AppStore
  var isActive: Bool
  @State private var query = ""
  @State private var showingEditor = false
  @State private var showingAutoRefresh = false
  @State private var showingGroupSettings = false
  @State private var debugDetailSubscription: Subscription?
  @State private var isReadingSubscriptions = false

  private var visibleSubscriptions: [Subscription] {
    SubscriptionGroupFilter.apply(
      store.subscriptions,
      selectedGroupID: store.selectedSubscriptionGroupID,
      completion: store.subscriptionListFilter,
      query: query
    )
  }

  private var emptyTitle: String {
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return store.subscriptionListFilter == .all
        ? "没有匹配的订阅"
        : "当前范围内没有匹配的订阅"
    }
    return store.selectedSubscriptionGroupID == nil
      ? store.subscriptionListFilter.emptyTitle
      : "当前分组没有匹配的订阅"
  }

  private var emptyDescription: String? {
    guard store.subscriptionListFilter != .all || store.selectedSubscriptionGroupID != nil else { return nil }
    let group = store.subscriptionGroups.first(where: { $0.id == store.selectedSubscriptionGroupID })?.name
    return "当前显示：\([group, store.subscriptionListFilter == .all ? nil : store.subscriptionListFilter.title].compactMap { $0 }.joined(separator: " · "))"
  }

  var body: some View {
    List {
      if store.subscriptions.isEmpty && isReadingSubscriptions {
        ProgressView("正在读取订阅")
          .frame(maxWidth: .infinity, minHeight: 360)
          .listRowBackground(Color.clear)
      } else if visibleSubscriptions.isEmpty {
        ContentUnavailableView {
          Label(
            emptyTitle,
            systemImage: query.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass"
          )
        } description: {
          if let emptyDescription {
            Text(emptyDescription)
          }
        } actions: {
          if store.subscriptionListFilter != .all || store.selectedSubscriptionGroupID != nil {
            Button("显示全部") {
              store.subscriptionListFilter = .all
              store.selectedSubscriptionGroupID = nil
            }
          }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .listRowBackground(Color.clear)
      } else {
        ForEach(visibleSubscriptions) { subscription in
          NavigationLink {
            MobileSubscriptionDetailView(subscription: subscription)
          } label: {
            MobileSubscriptionRow(subscription: subscription)
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("编辑", systemImage: "pencil") {
              store.editSubscription(subscription)
              showingEditor = true
            }
            .tint(.blue)
            Button(subscription.enabled ? "停用" : "启用", systemImage: subscription.enabled ? "pause.circle" : "play.circle") {
              Task { await store.toggleSubscriptionEnabled(subscription) }
            }
            .tint(subscription.enabled ? .orange : .green)
          }
        }
      }
    }
    .listStyle(.plain)
    .mobileNavigationTitle("订阅")
    .searchable(text: $query, prompt: "搜索订阅")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        MobileToolbarRefreshButton(
          target: .subscriptions,
          isDisabled: MobileDebugConfiguration.usesFixturesAtRuntime,
          isRefreshing: isReadingSubscriptions || store.refreshQueueRunning
        ) {
          await store.refreshAllSubscriptions()
        }
        Button("新建订阅", systemImage: "plus") {
          store.prepareNewSubscription()
          showingEditor = true
        }
        Menu("更多操作", systemImage: "ellipsis") {
          Section("筛选") {
            Button {
              store.subscriptionListFilter = store.subscriptionListFilter == .completed ? .all : .completed
            } label: {
              Label(
                "订阅完成",
                systemImage: store.subscriptionListFilter == .completed ? "checkmark" : "circle"
              )
            }
            .accessibilityValue(store.subscriptionListFilter == .completed ? "已开启" : "已关闭")
          }
          Section("分组筛选") {
            Button {
              store.selectedSubscriptionGroupID = nil
            } label: {
              Label("全部分组", systemImage: store.selectedSubscriptionGroupID == nil ? "checkmark.circle.fill" : "circle")
            }
            ForEach(store.subscriptionGroups) { group in
              Button {
                store.selectedSubscriptionGroupID = group.id
              } label: {
                Label(group.name, systemImage: store.selectedSubscriptionGroupID == group.id ? "checkmark.circle.fill" : "circle")
              }
            }
          }
          Section {
            Button("分组设置", systemImage: "folder.badge.gearshape") {
              showingGroupSettings = true
            }
            Button("自动刷新", systemImage: "clock.arrow.circlepath") {
              showingAutoRefresh = true
            }
          }
        }
      }
    }
    .sheet(isPresented: $showingEditor, onDismiss: {
      Task { await store.runPendingMetadataRecognitionIfNeeded() }
    }) {
      MobileSubscriptionEditorView()
        .environmentObject(store)
    }
    .sheet(isPresented: $store.showingMetadataReview) {
      MobileMetadataReviewSheet()
        .environmentObject(store)
    }
    .sheet(isPresented: $showingAutoRefresh) {
      MobileAutoRefreshSheet(client: store.client)
        .id(store.backendURL)
    }
    .sheet(isPresented: $showingGroupSettings) {
      MobileSubscriptionGroupSettingsView()
        .environmentObject(store)
        .presentationDetents([.medium, .large])
    }
    .navigationDestination(item: $debugDetailSubscription) { subscription in
      MobileSubscriptionDetailView(subscription: subscription)
    }
    .refreshable {
      await readSubscriptions()
    }
    .task(id: isActive) {
      #if DEBUG
      if isActive, MobileDebugConfiguration.usesFixturesAtRuntime,
         ProcessInfo.processInfo.environment["KISETSU_MOBILE_AUTO_REFRESH_FIXTURE"] == "1" {
        showingAutoRefresh = true
      }
      if isActive,
         MobileDebugConfiguration.usesFixturesAtRuntime,
         MobileDebugConfiguration.initialSubscriptionDetail(
           environment: ProcessInfo.processInfo.environment
         ) == "first",
         debugDetailSubscription == nil {
        debugDetailSubscription = visibleSubscriptions.first
      }
      #endif
      guard isActive else { return }
      if !MobileDebugConfiguration.usesFixturesAtRuntime {
        await store.loadSubscriptionGroups()
      }
      await readSubscriptions()
      guard !MobileDebugConfiguration.usesFixturesAtRuntime else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled, isActive else { return }
        await store.loadSubscriptions(silent: true)
      }
    }
  }

  private func readSubscriptions() async {
    guard !isReadingSubscriptions, !store.refreshQueueRunning else { return }
    isReadingSubscriptions = true
    defer { isReadingSubscriptions = false }
    #if DEBUG
    if MobileDebugConfiguration.usesFixturesAtRuntime {
      try? await Task.sleep(for: .milliseconds(600))
      return
    }
    #endif
    await store.loadSubscriptions(silent: true)
  }
}

private struct MobileSubscriptionRow: View {
  @EnvironmentObject private var store: AppStore
  var subscription: Subscription

  private var progress: SubscriptionTargetProgressPresentation {
    SubscriptionTargetProgressPresentation(subscription: subscription)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      MobilePosterImage(
        urls: [
          store.backendResourceURL(subscription.posterLocalUrl),
          store.backendResourceURL(subscription.posterUrl),
          subscription.posterUrl.flatMap(URL.init(string:)),
        ],
        width: MobilePosterSizing.primaryListWidth,
        height: MobilePosterSizing.primaryListHeight
      )
      VStack(alignment: .leading, spacing: 7) {
        Text(subscription.name)
          .font(.headline)
          .lineLimit(2)
        if let subtitle = MobileSubscriptionMetadataPresentation.subtitle(for: subscription) {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if let metrics = progress.metrics {
          MobileSubscriptionProgressView(
            progress: metrics,
            palette: subscription.posterPalette
          )
        } else if let fallback = progress.fallbackText {
          Text(fallback).font(.caption2).foregroundStyle(.secondary)
        }
        if let organizedTime = MobileOrganizedTimePresentation.text(subscription.latestOrganizedAt) {
          Text(organizedTime).font(.caption2).foregroundStyle(.secondary)
        }
        MobileTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
          ForEach(
            Array(MobileSubscriptionBadgePresentation.values(
              for: subscription,
              siteLabel: { store.siteLabel(for: $0) }
            ).enumerated()),
            id: \.offset
          ) { _, value in
            MobileTag(
              text: value,
              maximumTextWidth: MobileSubscriptionBadgePresentation.maximumTextWidth
            )
          }
        }
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 0) {
        Image(systemName: MobileSubscriptionStatusPresentation.subscriptionSymbol(isEnabled: subscription.enabled))
          .font(.system(size: 18))
          .foregroundStyle(MobileSubscriptionStatusPresentation.tint(palette: subscription.posterPalette, isEnabled: subscription.enabled))
          .frame(width: 24, height: 24)
          .accessibilityLabel(
            MobileSubscriptionStatusPresentation.subscriptionAccessibilityLabel(isEnabled: subscription.enabled)
          )
        Spacer(minLength: 14)
        Image(systemName: MobileSubscriptionStatusPresentation.autoDownloadSymbol(isEnabled: subscription.autoDownload))
          .font(.system(size: 18))
          .foregroundStyle(MobileSubscriptionStatusPresentation.tint(palette: subscription.posterPalette, isEnabled: subscription.autoDownload))
          .frame(width: 24, height: 24)
          .accessibilityLabel(
            MobileSubscriptionStatusPresentation.autoDownloadAccessibilityLabel(isEnabled: subscription.autoDownload)
          )
      }
      .frame(minHeight: MobilePosterSizing.primaryListHeight, maxHeight: .infinity, alignment: .top)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

enum MobileSubscriptionBadgePresentation {
  static let maximumTextWidth: CGFloat = 138

  static func values(
    for subscription: Subscription,
    siteLabel: (String) -> String = { $0 }
  ) -> [String] {
    [
      source(for: subscription, siteLabel: siteLabel),
      firstNonempty(
        subscription.resolutionPreset,
        subscription.resolutionCustom,
        subscription.resolution
      ),
      subscription.season.map { "S\(String(format: "%02d", $0))" },
      SubscriptionTargetProgressPresentation(subscription: subscription).startBadgeText,
      normalized(subscription.fansub),
    ].compactMap { $0 }
  }

  private static func source(
    for subscription: Subscription,
    siteLabel: (String) -> String
  ) -> String? {
    if subscription.sourceType?.lowercased() == "rss" {
      return subscription.rssUrls.isEmpty ? "RSS" : "RSS \(subscription.rssUrls.count)"
    }
    let sites = subscription.sites
      .map(siteLabel)
      .compactMap(normalized)
    return sites.isEmpty ? nil : sites.joined(separator: ", ")
  }

  private static func firstNonempty(_ values: String?...) -> String? {
    values.lazy.compactMap(normalized).first
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum MobileSubscriptionMetadataPresentation {
  static func subtitle(for subscription: Subscription) -> String? {
    let name = normalizedKey(subscription.name)
    let keyword = normalized(subscription.keyword)
    let metadataTitles = (subscription.metadataTitles ?? [])
      .compactMap(normalized)
      .filter { normalizedKey($0) != name }

    if !metadataTitles.isEmpty {
      return metadataTitles.prefix(2).joined(separator: " / ")
    }
    guard let keyword, normalizedKey(keyword) != name else { return nil }
    return keyword
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

enum MobileSubscriptionEpisodePresentation {
  static func isOrganized(_ episode: SubscriptionLogicalEpisodeStatus) -> Bool {
    episode.organizeStatus == "已整理"
      || episode.derivedStatus == "已整理"
      || episode.derivedStatus == "已整理并移除任务"
  }

  static func posterPalette(
    detail: SubscriptionDetail,
    fallback subscription: Subscription
  ) -> PosterPalette? {
    detail.metadataHierarchy.first?.posterPalette
      ?? detail.subscription.posterPalette
      ?? subscription.posterPalette
  }
}

private struct MobileSubscriptionProgressView: View {
  var progress: SubscriptionProgressMetrics
  var palette: PosterPalette?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hasPresentedProgress = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.primary.opacity(0.08))
          Capsule()
            .fill(downloadedColor)
            .scaleEffect(
              x: MobileSubscriptionProgressMotion.scale(
                fraction: progress.downloadedFraction,
                available: geometry.size.width
              ),
              y: 1,
              anchor: .leading
            )
            .opacity(progress.downloaded > 0 ? 1 : 0)
            .animation(progressAnimation, value: progress.downloadedFraction)
          Capsule()
            .fill(organizedColor)
            .scaleEffect(
              x: MobileSubscriptionProgressMotion.scale(
                fraction: progress.organizedFraction,
                available: geometry.size.width
              ),
              y: 1,
              anchor: .leading
            )
            .opacity(progress.organized > 0 ? 1 : 0)
            .animation(progressAnimation, value: progress.organizedFraction)
        }
      }
      .frame(height: 6)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 4) {
          Text("下载 \(progress.downloadedText)")
          Text("·").accessibilityHidden(true)
          Text("整理 \(progress.organizedText)")
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("下载 \(progress.downloadedText)")
          Text("整理 \(progress.organizedText)")
        }
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("下载 \(progress.downloadedText)，整理 \(progress.organizedText)")
    .onAppear { hasPresentedProgress = true }
  }

  private var organizedColor: Color {
    SubscriptionPalettePresentation.colors(palette: palette, colorScheme: colorScheme).primary
  }

  private var downloadedColor: Color {
    SubscriptionPalettePresentation.colors(palette: palette, colorScheme: colorScheme).downloadedTrack
  }

  private var progressAnimation: Animation? {
    reduceMotion || !hasPresentedProgress ? nil : MobileMotion.progress
  }

}

private struct MobileSubscriptionDetailHero: View {
  @EnvironmentObject private var store: AppStore
  var detail: SubscriptionDetail

  private var show: SubscriptionMetadataHierarchy? { detail.metadataHierarchy.first }

  private var posterURLs: [URL?] {
    [
      store.backendResourceURL(show?.posterLocalUrl),
      store.backendResourceURL(show?.posterUrl),
      show?.posterUrl.flatMap(URL.init(string:)),
      store.backendResourceURL(detail.subscription.posterLocalUrl),
      store.backendResourceURL(detail.subscription.posterUrl),
      detail.subscription.posterUrl.flatMap(URL.init(string:)),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 16) {
        MobilePosterImage(urls: posterURLs, width: 118, height: 168)
          .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
        VStack(alignment: .leading, spacing: 8) {
          Text(show?.title ?? detail.subscription.name)
            .font(.title3.weight(.semibold))
            .lineLimit(3)
          if let originalTitle = show?.originalTitle,
             !originalTitle.isEmpty,
             originalTitle != show?.title {
            Text(originalTitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          MobileTagFlowLayout {
            statusTags
          }
        }
        Spacer(minLength: 0)
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(metadataLines.enumerated()), id: \.offset) { _, line in
          Label(line.text, systemImage: line.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let summary = show?.summary, !summary.isEmpty {
        Text(summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }

      if let tags = show?.tags, !tags.isEmpty {
        MobileTagFlowLayout {
          ForEach(tags.prefix(12), id: \.self) { tag in
            MobileTag(text: tag)
          }
        }
      }

      HStack(spacing: 0) {
        metric(title: "匹配", value: detail.matchedCount, tint: .pink)
        Divider().frame(height: 34)
        metric(title: "已提交", value: detail.queuedCount, tint: .green)
        Divider().frame(height: 34)
        metric(title: "跳过", value: detail.skippedCount, tint: .secondary)
        Divider().frame(height: 34)
        metric(title: "错误", value: detail.errorCount, tint: .orange)
      }
      .accessibilityElement(children: .combine)
    }
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var statusTags: some View {
    if let resolution = detail.subscription.resolutionPreset ?? detail.subscription.resolution,
       !resolution.isEmpty {
      MobileTag(text: resolution)
    }
    if let season = detail.subscription.season {
      MobileTag(text: "S\(String(format: "%02d", season))")
    }
    if let start = SubscriptionTargetProgressPresentation(subscription: detail.subscription).startBadgeText {
      MobileTag(text: start)
    }
    if let fansub = detail.subscription.fansub, !fansub.isEmpty {
      MobileTag(text: fansub)
    }
    if let rating = show?.rating {
      MobileTag(text: rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill", tint: .orange)
    }
  }

  private var metadataLines: [(systemImage: String, text: String)] {
    let subscriptionKind = detail.subscription.sourceType == "rss" ? "RSS 订阅" : "自动订阅"
    let identity = [subscriptionKind, show?.sourceLabel]
      .compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
      .joined(separator: " · ")
    let release = [
      show?.airDate,
      show?.totalEpisodes.map { "\($0) 集" },
    ]
      .compactMap { $0 }
      .joined(separator: " · ")

    var lines = [(systemImage: "info.circle", text: identity)]
    if !release.isEmpty {
      lines.append((systemImage: "calendar", text: release))
    }
    return lines
  }

  private func metric(title: String, value: Int, tint: Color) -> some View {
    VStack(spacing: 2) {
      Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(tint)
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

struct MobileSubscriptionDetailView: View {
  @EnvironmentObject private var store: AppStore
  var subscription: Subscription
  @State private var showingEditor = false
  @State private var showingDeleteConfirmation = false
  @State private var pendingConfirmation: MobileSubscriptionConfirmation?

  var body: some View {
    List {
      if let detail = currentDetail {
        let posterPalette = MobileSubscriptionEpisodePresentation.posterPalette(
          detail: detail,
          fallback: subscription
        )
        Section {
          MobileSubscriptionDetailHero(detail: detail)
        }

        Section("剧集") {
          if detail.episodeStatuses.isEmpty {
            Text("尚未形成剧集状态").foregroundStyle(.secondary)
          } else {
            ForEach(detail.episodeStatuses) { episode in
              MobileSubscriptionEpisodeRow(
                episode: episode,
                detail: detail,
                posterPalette: posterPalette,
                confirm: { pendingConfirmation = $0 }
              )
            }
          }
        }

        if !detail.unmatchedResources.isEmpty {
          Section("未匹配资源") {
            ForEach(detail.unmatchedResources) { resource in
              VStack(alignment: .leading, spacing: 4) {
                Text(resource.rawTitle).font(.subheadline).lineLimit(3)
                Text([store.siteLabel(for: resource.site), resource.size].compactMap { $0 }.joined(separator: " · "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        if !detail.matches.isEmpty {
          Section("匹配记录") {
            ForEach(detail.matches) { match in
              VStack(alignment: .leading, spacing: 5) {
                Text(match.result.title)
                  .font(.subheadline)
                  .lineLimit(3)
                HStack(spacing: 8) {
                  MobileTag(text: match.displayEpisodeLabel)
                  MobileTag(text: store.siteLabel(for: match.displaySourceID))
                  Text(match.displaySize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              .contextMenu {
                Button("提交下载", systemImage: "arrow.down.circle") {
                  pendingConfirmation = .download(match)
                }
                Button("生成整理预览", systemImage: "wand.and.stars") {
                  Task { await store.previewMatch(match) }
                }
                Button("识别番剧", systemImage: "sparkles.tv") {
                  Task { await store.matchMetadata(for: match) }
                }
              }
            }
          }
        }
      } else if store.isLoading {
        ProgressView("正在读取订阅详情")
          .frame(maxWidth: .infinity, minHeight: 320)
          .listRowBackground(Color.clear)
      } else {
        MobileErrorView(title: "无法读取订阅", message: store.operationStatus.detail) {
          Task { await store.loadSubscriptionDetail(for: subscription) }
        }
        .frame(minHeight: 320)
        .listRowBackground(Color.clear)
      }
    }
    .mobileNavigationTitle(subscription.name, displayMode: .inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu("订阅操作", systemImage: "ellipsis.circle") {
          Button("编辑", systemImage: "pencil") {
            store.editSubscription(currentDetail?.subscription ?? subscription)
            showingEditor = true
          }
          Button("重新识别", systemImage: "sparkles") {
            store.beginMobileSubscriptionMetadataReview()
          }
          Divider()
          Menu("清理当前订阅", systemImage: "eraser") {
            Button("清除识别结果", systemImage: "sparkles.rectangle.stack", role: .destructive) {
              pendingConfirmation = .clearRecognition(currentDetail?.subscription ?? subscription)
            }
            Button("清空匹配历史", systemImage: "tray.and.arrow.down", role: .destructive) {
              pendingConfirmation = .clearMatches(currentDetail?.subscription ?? subscription)
            }
            Button("清空整理记录", systemImage: "folder.badge.minus", role: .destructive) {
              pendingConfirmation = .clearOrganize(currentDetail?.subscription ?? subscription)
            }
            Button("清空刷新历史", systemImage: "clock.badge.xmark", role: .destructive) {
              pendingConfirmation = .clearHistory(currentDetail?.subscription ?? subscription, scope: "refresh")
            }
            Button("清空下载历史", systemImage: "xmark.bin", role: .destructive) {
              pendingConfirmation = .clearHistory(currentDetail?.subscription ?? subscription, scope: "download")
            }
            Button("重置全部状态", systemImage: "arrow.counterclockwise", role: .destructive) {
              pendingConfirmation = .resetSubscription(currentDetail?.subscription ?? subscription)
            }
          }
          Divider()
          Button("删除订阅", systemImage: "trash", role: .destructive) {
            showingDeleteConfirmation = true
          }
        }
        MobileToolbarRefreshButton(
          target: .subscriptionDetail,
          isDisabled: MobileDebugConfiguration.usesFixturesAtRuntime
        ) {
          await store.refreshSubscription(currentDetail?.subscription ?? subscription)
        }
      }
    }
    .task(id: subscription.id) {
      guard !MobileDebugConfiguration.usesFixturesAtRuntime else { return }
      await store.loadSubscriptionDetail(for: subscription)
    }
    .refreshable {
      guard !MobileDebugConfiguration.usesFixturesAtRuntime else { return }
      await store.refreshSelectedSubscriptionDetail(silent: true)
    }
    .sheet(isPresented: $showingEditor) {
      MobileSubscriptionEditorView().environmentObject(store)
    }
    .sheet(isPresented: $store.showingMetadataReview) {
      MobileMetadataReviewSheet().environmentObject(store)
    }
    .sheet(isPresented: $store.showingBatchOrganizeSheet) {
      MobileOrganizePreviewSheet().environmentObject(store)
    }
    .alert(item: $pendingConfirmation) { confirmation in
      Alert(
        title: Text(confirmation.title),
        message: Text(confirmation.message),
        primaryButton: .cancel(Text("取消")),
        secondaryButton: confirmation.isDestructive
          ? .destructive(Text(confirmation.confirmTitle)) { perform(confirmation) }
          : .default(Text(confirmation.confirmTitle)) { perform(confirmation) }
      )
    }
    .alert("删除订阅？", isPresented: $showingDeleteConfirmation) {
      Button("删除", role: .destructive) { Task { await store.deleteSubscription(subscription) } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只删除订阅配置；下载器任务和文件仍按后端现有规则处理。")
    }
  }

  private var currentDetail: SubscriptionDetail? {
    guard store.selectedSubscriptionDetail?.subscription.id == subscription.id else { return nil }
    return store.selectedSubscriptionDetail
  }

  private func perform(_ confirmation: MobileSubscriptionConfirmation) {
    Task {
      switch confirmation {
      case let .download(match): await store.downloadMatch(match)
      case let .deleteHistory(item): await store.deleteHistoryRecord(item)
      case let .deleteTask(item): await store.manageHistory(item, action: "delete")
      case let .deleteOrganize(subscriptionID, matchID):
        await store.deleteEpisodeOrganizeRecord(subscriptionID: subscriptionID, matchID: matchID)
      case let .resetEpisode(subscriptionID, matchID):
        await store.resetEpisodeState(subscriptionID: subscriptionID, matchID: matchID)
      case let .clearRecognition(value): await store.clearSubscriptionRecognition(value)
      case let .clearMatches(value): await store.clearSubscriptionMatchHistory(value)
      case let .clearOrganize(value): await store.clearSubscriptionOrganizeRecords(value)
      case let .clearHistory(value, scope): await store.clearSubscriptionHistory(value, scope: scope)
      case let .resetSubscription(value): await store.resetSubscriptionState(value)
      }
    }
  }
}

private enum MobileSubscriptionConfirmation: Identifiable {
  case download(SubscriptionMatch)
  case deleteHistory(DownloadHistory)
  case deleteTask(DownloadHistory)
  case deleteOrganize(subscriptionID: Int, matchID: Int)
  case resetEpisode(subscriptionID: Int, matchID: Int)
  case clearRecognition(Subscription)
  case clearMatches(Subscription)
  case clearOrganize(Subscription)
  case clearHistory(Subscription, scope: String)
  case resetSubscription(Subscription)

  var id: String {
    switch self {
    case let .download(match): "download-\(match.id)"
    case let .deleteHistory(item): "delete-history-\(item.id)"
    case let .deleteTask(item): "delete-task-\(item.id)"
    case let .deleteOrganize(subscriptionID, matchID): "delete-organize-\(subscriptionID)-\(matchID)"
    case let .resetEpisode(subscriptionID, matchID): "reset-episode-\(subscriptionID)-\(matchID)"
    case let .clearRecognition(value): "clear-recognition-\(value.id)"
    case let .clearMatches(value): "clear-matches-\(value.id)"
    case let .clearOrganize(value): "clear-organize-\(value.id)"
    case let .clearHistory(value, scope): "clear-history-\(value.id)-\(scope)"
    case let .resetSubscription(value): "reset-subscription-\(value.id)"
    }
  }

  var title: String {
    switch self {
    case .download: "提交这个资源？"
    case .deleteHistory: "删除下载记录？"
    case .deleteTask: "删除下载任务？"
    case .deleteOrganize: "删除整理记录？"
    case .resetEpisode: "重置本资源状态？"
    case .clearRecognition: "清除识别结果？"
    case .clearMatches: "清空匹配历史？"
    case .clearOrganize: "清空整理记录？"
    case let .clearHistory(_, scope): scope == "refresh" ? "清空刷新历史？" : "清空下载历史？"
    case .resetSubscription: "重置订阅状态？"
    }
  }

  var confirmTitle: String {
    switch self {
    case .download: "提交下载"
    case .deleteHistory: "删除记录"
    case .deleteTask: "删除任务"
    case .deleteOrganize: "删除整理记录"
    case .resetEpisode: "重置本资源"
    case .clearRecognition: "清除识别结果"
    case .clearMatches: "清空匹配历史"
    case .clearOrganize: "清空整理记录"
    case .clearHistory: "清空历史"
    case .resetSubscription: "重置状态"
    }
  }

  var isDestructive: Bool {
    switch self {
    case .download: false
    default: true
    }
  }

  var message: String {
    switch self {
    case let .download(match):
      "将把“\(match.result.title)”提交到订阅下载器。"
    case let .deleteHistory(item):
      "只删除 Kisetsu 中的下载历史，不删除下载器任务或文件：\(item.title)"
    case let .deleteTask(item):
      "从下载器移除任务但保留文件：\(item.title)"
    case .deleteOrganize:
      "只删除本资源的整理预览和整理记录，不删除真实文件。"
    case .resetEpisode:
      "删除本资源的本地下载与整理记录并恢复为新匹配，不删除下载器任务或真实文件。"
    case let .clearRecognition(value):
      "清除“\(value.name)”的 Bangumi/TMDB 识别结果和整理规则缓存，不删除订阅、任务或文件。"
    case let .clearMatches(value):
      "清空“\(value.name)”的资源匹配历史，不删除下载历史、任务或文件。"
    case let .clearOrganize(value):
      "清空“\(value.name)”的整理记录，不删除真实文件。"
    case let .clearHistory(value, scope):
      scope == "refresh"
        ? "清空“\(value.name)”的刷新历史，不删除匹配、下载记录或规则。"
        : "清空“\(value.name)”的下载历史，不删除下载器任务或文件。"
    case let .resetSubscription(value):
      "清空“\(value.name)”的匹配、刷新、下载与整理状态，保留订阅规则和番剧信息。"
    }
  }
}

private struct MobileSubscriptionEpisodeRow: View {
  @EnvironmentObject private var store: AppStore
  var episode: SubscriptionLogicalEpisodeStatus
  var detail: SubscriptionDetail
  var posterPalette: PosterPalette?
  var confirm: (MobileSubscriptionConfirmation) -> Void

  var body: some View {
    DisclosureGroup {
      if episode.matchedResources.isEmpty {
        Text("暂无匹配资源").foregroundStyle(.secondary)
      } else {
        ForEach(episode.matchedResources) { resource in
          MobileSubscriptionResourceRow(
            resource: resource,
            match: match(for: resource),
            history: history(for: resource),
            confirm: confirm,
            preview: {
              #if DEBUG
              if MobileDebugConfiguration.usesFixturesAtRuntime {
                store.organizePreview = MobileDebugFixtureData.organizePreview
                store.showingBatchOrganizeSheet = true
                return
              }
              #endif
              Task { await store.previewResource(resource) }
            }
          )
        }
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(episode.displayTitle).font(.subheadline.weight(.medium))
          if !isOrganized {
            Text(episode.derivedStatus ?? episode.downloadStatus)
              .font(.caption)
              .foregroundStyle(episode.excludedByEpisodeStart == true ? .tertiary : .secondary)
          }
        }
        Spacer()
        if episode.excludedByEpisodeStart == true {
          MobileTag(text: "已跳过", systemImage: "forward.end", tint: .secondary)
        } else if isOrganized {
          Label("已整理", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(organizedTint)
        } else {
          Text("\(episode.matchedResources.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityLabel(SubscriptionEpisodeScopePresentation.accessibilityLabel(for: episode))
  }

  private var isOrganized: Bool {
    MobileSubscriptionEpisodePresentation.isOrganized(episode)
  }

  private var organizedTint: Color {
    MobileSubscriptionStatusPresentation.tint(
      palette: posterPalette,
      isEnabled: true
    )
  }

  private func match(for resource: SubscriptionEpisodeResource) -> SubscriptionMatch? {
    detail.matches.first { $0.id == resource.matchId }
  }

  private func history(for resource: SubscriptionEpisodeResource) -> DownloadHistory? {
    if let recordID = resource.downloadRecordId {
      return detail.history.first { $0.id == recordID }
    }
    guard let match = match(for: resource) else { return nil }
    return detail.history.first { $0.fingerprint == match.fingerprint }
  }
}

private struct MobileSubscriptionResourceRow: View {
  @EnvironmentObject private var store: AppStore
  var resource: SubscriptionEpisodeResource
  var match: SubscriptionMatch?
  var history: DownloadHistory?
  var confirm: (MobileSubscriptionConfirmation) -> Void
  var preview: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(resource.rawTitle)
        .font(.subheadline)
        .lineLimit(3)
      HStack(spacing: 7) {
        MobileTag(text: store.siteLabel(for: resource.site))
        if let resolution = resource.resolution { MobileTag(text: resolution) }
        if let size = resource.size {
          Text(size).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      if let detail = resource.derivedStatusDetail, !detail.isEmpty {
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          MobileSubscriptionResourceActionButton(
            title: "下载这个资源",
            systemImage: "arrow.down.circle"
          ) {
            if let match { confirm(.download(match)) }
          }
          .disabled(match == nil || store.isLoading)

          MobileSubscriptionResourceActionButton(
            title: "整理这个资源",
            systemImage: "wand.and.stars",
            action: preview
          )
          .disabled(history == nil || match == nil || store.isLoading)

          Spacer(minLength: 0)

          Menu {
            if let history {
              Button("删除下载任务", systemImage: "trash", role: .destructive) {
                confirm(.deleteTask(history))
              }
              Button("删除下载记录", systemImage: "xmark.bin", role: .destructive) {
                confirm(.deleteHistory(history))
              }
            }
            if let detail = store.selectedSubscriptionDetail {
              Button("删除整理记录", systemImage: "folder.badge.minus", role: .destructive) {
                confirm(.deleteOrganize(subscriptionID: detail.subscription.id, matchID: resource.matchId))
              }
              Button("重置本资源状态", systemImage: "arrow.counterclockwise", role: .destructive) {
                confirm(.resetEpisode(subscriptionID: detail.subscription.id, matchID: resource.matchId))
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: MobileTaskActionPresentation.symbolSize, weight: .semibold))
              .frame(
                width: MobileTaskActionPresentation.visibleSize,
                height: MobileTaskActionPresentation.visibleSize
              )
          }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          .frame(
            width: MobileTaskActionPresentation.hitTargetSize,
            height: MobileTaskActionPresentation.hitTargetSize
          )
          .accessibilityLabel("更多资源操作")
        }
      }
    }
    .padding(.vertical, 5)
  }
}

private struct MobileSubscriptionResourceActionButton: View {
  var title: String
  var systemImage: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: MobileTaskActionPresentation.symbolSize, weight: .semibold))
        .frame(
          width: MobileTaskActionPresentation.visibleSize,
          height: MobileTaskActionPresentation.visibleSize
        )
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.small)
    .frame(
      width: MobileTaskActionPresentation.hitTargetSize,
      height: MobileTaskActionPresentation.hitTargetSize
    )
    .accessibilityLabel(title)
  }
}

struct MobileOrganizePreviewSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var confirmingApply = false

  var body: some View {
    NavigationStack {
      List {
        if let preview = store.organizePreview {
          Section("目标") {
            LabeledContent("文件", value: preview.filename)
            Text(preview.destinationPreview)
              .font(.caption.monospaced())
              .textSelection(.enabled)
            if let reason = preview.blockReason, !reason.isEmpty {
              Label(reason, systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
            }
            ForEach(preview.warnings, id: \.self) { warning in
              Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }

          if !store.pendingFileMappings(for: preview).isEmpty {
            Section("文件映射") {
              ForEach(store.pendingFileMappings(for: preview)) { mapping in
                MobileOrganizeMappingEditor(mapping: mapping)
              }
            }
          }

          if let subtitles = preview.subtitleMappings, !subtitles.isEmpty {
            Section("字幕") {
              ForEach(subtitles, id: \.sourcePath) { subtitle in
                VStack(alignment: .leading, spacing: 3) {
                  Text(subtitle.originalFilename).font(.subheadline)
                  Text(subtitle.targetFilename).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        } else {
          ContentUnavailableView("没有整理预览", systemImage: "wand.and.stars")
        }
      }
      .mobileStatusNavigationTitle("整理预览")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            store.showingBatchOrganizeSheet = false
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("确认整理", systemImage: "wand.and.stars") { confirmingApply = true }
            .disabled(store.isLoading || store.organizePreview?.canApply == false)
        }
      }
      .alert("执行整理？", isPresented: $confirmingApply) {
        Button("整理") { Task { await store.applyOrganizePreview() } }
        Button("取消", role: .cancel) {}
      } message: {
        Text("将按当前文件映射执行真实整理，并应用订阅已有的任务处理策略。")
      }
    }
    .interactiveDismissDisabled(store.isLoading)
  }
}

struct MobileOrganizeMappingEditor: View {
  @EnvironmentObject private var store: AppStore
  var mapping: OrganizePreviewFileMapping

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(mapping.originalFilename)
        .font(.subheadline.weight(.medium))
        .lineLimit(3)
      Text(mapping.targetFilename)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
      if store.organizePreview?.mediaType != "movie" {
      DisclosureGroup("调整季集数") {
      Stepper("第 \(mapping.seasonNumber) 季") {
        store.updateOrganizePreviewMapping(id: mapping.id, seasonNumber: mapping.seasonNumber + 1)
      } onDecrement: {
        store.updateOrganizePreviewMapping(id: mapping.id, seasonNumber: max(0, mapping.seasonNumber - 1))
      }
      Stepper(mapping.episodeNumber.map { "第 \($0) 集" } ?? "请选择集数") {
        store.updateOrganizePreviewMapping(id: mapping.id, episodeNumber: (mapping.episodeNumber ?? 1) + 1)
      } onDecrement: {
        store.updateOrganizePreviewMapping(id: mapping.id, episodeNumber: max(1, (mapping.episodeNumber ?? 1) - 1))
      }
      Toggle("特别篇", isOn: Binding(
        get: { mapping.isSpecial },
        set: { store.updateOrganizePreviewMapping(id: mapping.id, isSpecial: $0) }
      ))
      }
      }
      Toggle("包含此文件", isOn: Binding(
        get: { mapping.status != "skipped" },
        set: { store.updateOrganizePreviewMapping(id: mapping.id, skipped: !$0) }
      ))
      if !mapping.message.isEmpty {
        Text(mapping.message)
          .font(.caption)
          .foregroundStyle(mapping.status == "needs_confirmation" ? .orange : .secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

struct MobileSubscriptionEditorView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var isSaving = false
  @State private var isTesting = false
  @State private var isAdvancedMatchingExpanded = false
  @State private var episodeRuleEditorRoute: MobileEpisodeRuleEditorRoute?

  var body: some View {
    NavigationStack {
      Form {
        Section("基本信息") {
          MobileSubscriptionTextField(
            label: "订阅名称",
            prompt: "例如：葬送的芙莉莲",
            text: $store.subscriptionName
          )
          Picker("分组", selection: $store.subscriptionGroupID) {
            if store.subscriptionGroups.isEmpty {
              Text(store.subscriptionGroupID == nil ? "默认分组" : "当前分组")
                .tag(store.subscriptionGroupID)
            }
            ForEach(store.subscriptionGroups) { group in
              Text(group.name).tag(Optional(group.id))
            }
          }
          .disabled(store.subscriptionGroups.isEmpty)
          Picker("订阅来源", selection: $store.subscriptionSourceType) {
            Text("关键词搜索").tag("keyword")
            Text("Mikan 番组").tag("mikan_bangumi")
            Text("RSS").tag("rss")
          }
          if store.subscriptionSourceType == "mikan_bangumi" {
            MobileSubscriptionTextField(
              label: "关键词",
              prompt: "用于显示、匹配和整理命名",
              text: $store.subscriptionKeyword
            )
            MobileSubscriptionTextField(
              label: MobileSubscriptionEditorPresentation.sourceFieldLabel(for: store.subscriptionSourceType),
              prompt: "https://mikanani.me/Home/Bangumi/...",
              text: $store.subscriptionSourceURL
            )
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
            MobileFormValidationMessage(message: sourceURLValidationMessage)
          } else if store.subscriptionSourceType == "rss" {
            MobileSubscriptionTextField(
              label: MobileSubscriptionEditorPresentation.keywordFieldLabel(for: store.subscriptionSourceType),
              prompt: "用于显示、匹配和整理命名",
              text: $store.subscriptionKeyword
            )
            MobileFormSecureField(
              label: "RSS 地址",
              prompt: "每行一个 RSS 地址",
              text: $store.subscriptionRSSURLs
            )
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            MobileFormValidationMessage(message: sourceURLValidationMessage)
          } else {
            MobileSubscriptionTextField(
              label: MobileSubscriptionEditorPresentation.sourceFieldLabel(for: store.subscriptionSourceType),
              prompt: "例如：葬送的芙莉莲",
              text: $store.subscriptionKeyword
            )
          }
          MobileSubscriptionTextField(
            label: "别名",
            prompt: "多个别名用逗号分隔",
            text: $store.subscriptionAliases
          )
          MobileSubscriptionTextField(
            label: "总集数",
            prompt: "例如：12",
            text: $store.subscriptionTotalEpisodes
          )
            .keyboardType(.numberPad)
          MobileFormValidationMessage(message: totalEpisodesValidationMessage)
        }

        Section("来源站点") {
          ForEach(store.subscriptionSiteOptions) { site in
            Toggle(site.label, isOn: siteBinding(site.id))
          }
        }

        Section("资源筛选") {
          MobileSubscriptionFansubField(
            text: $store.subscriptionFansub,
            options: store.smartSubscriptionFansubOptions
          )
          Picker("分辨率", selection: $store.subscriptionResolution) {
            Text("不限").tag("")
            Text("720p").tag("720p")
            Text("1080p").tag("1080p")
            Text("2160p").tag("2160p")
            Text("自定义").tag("custom")
          }
          if store.subscriptionResolution == "custom" {
            MobileSubscriptionTextField(
              label: "自定义分辨率关键词",
              prompt: "例如：1440p、HEVC、AV1",
              text: $store.subscriptionResolutionCustom
            )
            MobileSubscriptionInlineHelp("多个关键词可用逗号分隔；留空按不限保存。")
          }

          LabeledContent("最小体积") {
            HStack {
              TextField("不限", text: $store.subscriptionMinSize)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
              Picker("单位", selection: Binding(
                get: { store.subscriptionMinSizeUnit },
                set: { store.setSubscriptionMinSizeUnit($0) }
              )) {
                ForEach(SubscriptionSizeUnit.allCases) { Text($0.rawValue).tag($0) }
              }
              .labelsHidden()
            }
          }
          LabeledContent("最大体积") {
            HStack {
              TextField("不限", text: $store.subscriptionMaxSize)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
              Picker("单位", selection: Binding(
                get: { store.subscriptionMaxSizeUnit },
                set: { store.setSubscriptionMaxSizeUnit($0) }
              )) {
                ForEach(SubscriptionSizeUnit.allCases) { Text($0.rawValue).tag($0) }
              }
              .labelsHidden()
            }
          }
          if let message = store.subscriptionSizeValidationMessage {
            Text(message).font(.caption).foregroundStyle(.red)
          }
          MobileSubscriptionTextField(
            label: "包含词",
            prompt: MobileSubscriptionEditorPresentation.includeKeywordsPrompt,
            text: $store.subscriptionIncludeKeywords
          )
          MobileSubscriptionInlineHelp("逗号分隔表示任意匹配；括号内表示全部匹配。")
          if let message = store.subscriptionIncludeKeywordValidationMessage {
            Text(message).font(.caption).foregroundStyle(.red)
          }
          MobileSubscriptionTextField(
            label: "排除词",
            prompt: MobileSubscriptionEditorPresentation.excludeKeywordsPrompt,
            text: $store.subscriptionExcludeKeywords
          )
          MobileSubscriptionInlineHelp("任一条件成立即排除；括号内关键词必须全部命中才触发排除。")
          if let message = store.subscriptionExcludeKeywordValidationMessage {
            Text(message).font(.caption).foregroundStyle(.red)
          }
          Picker("过滤顺序", selection: $store.subscriptionFilterOrder) {
            Text("先包含后排除").tag("include_first")
            Text("先排除后包含").tag("exclude_first")
          }
        }

        Section("集数规则") {
          MobileSubscriptionTextField(
            label: "季数",
            prompt: "例如：1",
            text: $store.subscriptionSeason
          )
            .keyboardType(.numberPad)
          MobileFormValidationMessage(message: seasonValidationMessage)
          MobileSubscriptionTextField(
            label: "起始集数",
            prompt: "默认从第 1 集开始",
            text: $store.subscriptionEpisodeStart
          )
            .keyboardType(.numberPad)
          MobileFormValidationMessage(message: episodeStartValidationMessage)
          MobileSubscriptionTextField(
            label: "指定集数",
            prompt: "例如：1-6, 8, 10-12",
            text: $store.subscriptionEpisodeFilter
          )
          MobileFormValidationMessage(message: episodeFilterValidationMessage)
          MobileSubscriptionTextField(
            label: "集数偏移",
            prompt: "默认 0",
            text: $store.subscriptionEpisodeOffset
          )
            .keyboardType(.numbersAndPunctuation)
          MobileFormValidationMessage(message: episodeOffsetValidationMessage)
          Toggle("刷新时自动更新总集数", isOn: $store.subscriptionAutoUpdateTotalEpisodes)
        }

        Section("集数识别") {
          Picker("规则来源", selection: episodeRuleSourceBinding) {
            Text("使用全局规则").tag("global")
            Text("订阅专属规则").tag("subscription")
          }
          .pickerStyle(.segmented)

          MobileSubscriptionInlineHelp(
            store.subscriptionUseCustomEpisodeRules
              ? "专属规则会优先于全局规则尝试，只影响当前订阅。"
              : "当前使用设置页中的全局识别规则。"
          )

          if store.subscriptionUseCustomEpisodeRules {
            MobileEpisodeRuleManager(
              rules: $store.subscriptionEpisodeParseRules,
              builtinRules: store.builtinEpisodeParseRules,
              testTitle: $store.subscriptionEpisodeRuleTestTitle,
              testResponse: store.lastEpisodeRuleTestResponse,
              isTesting: isTesting,
              addTemplate: { store.addEpisodeParseRule(template: $0) },
              runTest: {
                isTesting = true
                if MobileDebugConfiguration.usesFixturesAtRuntime {
                  #if DEBUG
                  store.lastEpisodeRuleTestResponse = MobileDebugFixtureData.episodeRuleTestResponse
                  #endif
                } else {
                  _ = await store.testEpisodeParseRules()
                }
                isTesting = false
              },
              presentEditor: { episodeRuleEditorRoute = $0 }
            )
          }
        }

        Section {
          DisclosureGroup(isExpanded: $isAdvancedMatchingExpanded) {
            Toggle("启用正则表达式", isOn: $store.subscriptionRegexEnabled)
            MobileSubscriptionTextEditor(
              label: "资源标题正则表达式",
              hint: "对资源主标题与副标题进行匹配；留空或关闭时不参与匹配。",
              text: $store.subscriptionRegex,
              minHeight: 72
            )
              .font(.body.monospaced())
              .disabled(!store.subscriptionRegexEnabled)
              .opacity(store.subscriptionRegexEnabled ? 1 : 0.58)
          } label: {
            Label("资源标题正则", systemImage: "curlybraces")
          }
        } header: {
          Text("高级匹配")
        } footer: {
          Text("这是资源标题过滤，不会改变集数识别规则。")
        }

        Section {
          Toggle("启用订阅", isOn: $store.subscriptionEnabled)
          Toggle("自动下载", isOn: $store.subscriptionAutoDownload)
          Toggle("下载完成后自动整理", isOn: $store.subscriptionAutoOrganize)
          Picker("整理后任务处理", selection: $store.subscriptionPostOrganizeAction) {
            Text("使用全局默认").tag("default")
            Text("继续做种").tag("keep_seeding")
            Text("移除任务，保留文件").tag("remove_task_keep_files")
            Text("移除任务和原文件").tag("remove_task_delete_files")
            Text("手动处理").tag("manual")
          }
          MobileSubscriptionInlineHelp(
            store.subscriptionPostOrganizeAction == "default"
              ? "使用设置页中的默认整理策略。"
              : store.organizePolicyDescription(store.subscriptionPostOrganizeAction)
          )
          Picker("整理目标", selection: $store.subscriptionOrganizeTargetID) {
            Text("使用默认目标").tag(nil as Int?)
            ForEach(store.organizeTargets.filter(\.enabled)) { target in
              Text(target.isDefault ? "\(target.name)（默认）" : target.name)
                .tag(Optional(target.id))
            }
          }
          if store.organizeTargets.filter(\.enabled).isEmpty {
            Label("暂无可用整理目标；仍可保存，并继续使用默认设置。", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("自动化")
        } footer: {
          if !store.subscriptionAutoOrganize {
            Text("整理策略会被保留，开启自动整理后生效。")
          }
        }

        if store.subscriptionPostOrganizeAction == "keep_seeding" {
          Section("继续做种") {
            Picker("做种规则", selection: $store.subscriptionSeedingPolicyMode) {
              Text("使用全局设置").tag("inherit")
              Text("当前订阅自定义").tag("custom")
            }
            .pickerStyle(.segmented)
            if store.subscriptionSeedingPolicyMode == "inherit" {
              MobileSubscriptionInlineHelp(store.subscriptionGlobalSeedingSummary)
            }
            if store.subscriptionSeedingPolicyMode == "custom" {
              Toggle("目标做种时间", isOn: $store.subscriptionSeedingTimeEnabled)
              if store.subscriptionSeedingTimeEnabled {
                MobileSubscriptionTextField(
                  label: "做种时长（小时）",
                  prompt: "例如：24",
                  text: $store.subscriptionSeedingHours
                )
                .keyboardType(.decimalPad)
              }
              Toggle("目标分享率", isOn: $store.subscriptionSeedingRatioEnabled)
              if store.subscriptionSeedingRatioEnabled {
                MobileSubscriptionTextField(
                  label: "目标分享率（%）",
                  prompt: "例如：100",
                  text: $store.subscriptionSeedingRatioPercent
                )
                .keyboardType(.decimalPad)
              }
              if store.subscriptionSeedingTimeEnabled && store.subscriptionSeedingRatioEnabled {
                Picker("达标方式", selection: $store.subscriptionSeedingStopMode) {
                  Text("任一目标达成").tag("any")
                  Text("全部目标达成").tag("all")
                }
              }
              Picker("达标后处理", selection: $store.subscriptionPostSeedingAction) {
                Text("暂停任务").tag("pause")
                Text("移除任务，保留文件").tag("remove_task_keep_files")
                Text("移除任务和原文件").tag("remove_task_delete_files")
                Text("等待手动处理").tag("manual")
              }
              MobileSubscriptionInlineHelp(store.subscriptionCustomSeedingSummary)
            }
            if let message = store.subscriptionSeedingValidationMessage {
              Text(message).font(.caption).foregroundStyle(.red)
            }
          }
        }

        Section {
          MobileSubscriptionTextField(
            label: "保存路径",
            prompt: "使用下载器默认路径",
            text: $store.subscriptionSavePath
          )
            .textInputAutocapitalization(.never)
          MobileSubscriptionTextField(
            label: "分类",
            prompt: "使用下载器默认分类",
            text: $store.subscriptionCategory
          )
          MobileSubscriptionTextField(
            label: "标签",
            prompt: "多个标签用逗号分隔",
            text: $store.subscriptionTags
          )
        } header: {
          Text("下载器")
        } footer: {
          Text("保存路径、分类和标签留空时使用下载器默认设置。")
        }

        Section("保存前检查") {
          Button(store.subscriptionSourceType == "rss" ? "测试 RSS" : "测试当前匹配规则", systemImage: "checkmark.seal") {
            Task {
              isTesting = true
              if store.subscriptionSourceType == "rss" {
                _ = await store.testRSSForm()
              } else {
                _ = await store.testSubscriptionForm()
              }
              isTesting = false
            }
          }
          .buttonStyle(.glass)
          .disabled(isTesting || isSaving || submitDisabledReason != nil)
          if let response = store.lastSubscriptionTestMatchResponse {
            LabeledContent("匹配结果", value: response.message)
          }
          if let submitDisabledReason {
            Label(submitDisabledReason, systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .mobileStatusNavigationTitle(store.subscriptionEditorTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            store.cancelSubscriptionEditing()
            dismiss()
          }
          .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(store.subscriptionPrimaryActionTitle) {
            Task {
              isSaving = true
              let saved = await store.saveSubscriptionForm()
              isSaving = false
              if saved { dismiss() }
            }
          }
          .disabled(
            isSaving
              || isTesting
              || hasValidationError
              || submitDisabledReason != nil
              || MobileDebugConfiguration.usesFixturesAtRuntime
          )
        }
      }
      .overlay {
        if isSaving || isTesting {
          ProgressView(isSaving ? "正在保存" : "正在测试")
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
      }
      .navigationDestination(item: $episodeRuleEditorRoute) { route in
        MobileEpisodeRuleEditorDestination(route: route) { updated in
          MobileEpisodeRuleCollection.save(updated, to: &store.subscriptionEpisodeParseRules)
        }
        .environmentObject(store)
      }
    }
    .interactiveDismissDisabled(isSaving)
    .task {
      if store.subscriptionGroups.isEmpty { await store.loadSubscriptionGroups() }
      guard !MobileDebugConfiguration.usesFixturesAtRuntime else { return }
      if !store.sitesLoaded { await store.loadSites() }
      if store.organizeTargets.isEmpty { await store.loadOrganizeTargets() }
    }
  }

  private func siteBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { store.selectedSiteIDs.contains(id) },
      set: { selected in
        if selected { store.selectedSiteIDs.insert(id) } else { store.selectedSiteIDs.remove(id) }
      }
    )
  }

  private var episodeRuleSourceBinding: Binding<String> {
    Binding(
      get: { store.subscriptionUseCustomEpisodeRules ? "subscription" : "global" },
      set: { store.subscriptionUseCustomEpisodeRules = $0 == "subscription" }
    )
  }

  private var submitDisabledReason: String? {
    MobileSubscriptionEditorPresentation.requiredFieldMessage(
      sourceType: store.subscriptionSourceType,
      name: store.subscriptionName,
      keyword: store.subscriptionKeyword,
      sourceURL: store.subscriptionSourceURL,
      rssURLs: store.subscriptionRSSURLs,
      selectedSiteCount: store.selectedSiteIDs.count
    )
  }

  private var hasValidationError: Bool {
    store.subscriptionSizeValidationMessage != nil
      || store.subscriptionIncludeKeywordValidationMessage != nil
      || store.subscriptionExcludeKeywordValidationMessage != nil
      || store.subscriptionSeedingValidationMessage != nil
      || MobileEpisodeRuleValidation.hasInvalidRules(
        store.subscriptionEpisodeParseRules,
        enabled: store.subscriptionUseCustomEpisodeRules
      )
      || sourceURLValidationMessage != nil
      || seasonValidationMessage != nil
      || totalEpisodesValidationMessage != nil
      || episodeStartValidationMessage != nil
      || episodeFilterValidationMessage != nil
      || episodeOffsetValidationMessage != nil
  }

  private var sourceURLValidationMessage: String? {
    switch store.subscriptionSourceType {
    case "mikan_bangumi":
      MobileFormValidation.httpURLMessage(store.subscriptionSourceURL, field: "Mikan 番组地址")
    case "rss":
      MobileFormValidation.httpURLListMessage(
        store.subscriptionRSSURLs,
        field: "RSS 地址",
        requiresValue: true
      )
    default:
      nil
    }
  }

  private var seasonValidationMessage: String? {
    MobileFormValidation.integerMessage(
      store.subscriptionSeason,
      field: "季数",
      minimum: 0,
      allowsEmpty: true
    )
  }

  private var totalEpisodesValidationMessage: String? {
    MobileFormValidation.integerMessage(
      store.subscriptionTotalEpisodes,
      field: "总集数",
      minimum: 1,
      allowsEmpty: true
    )
  }

  private var episodeStartValidationMessage: String? {
    MobileFormValidation.integerMessage(
      store.subscriptionEpisodeStart,
      field: "起始集数",
      minimum: 1,
      allowsEmpty: false
    )
  }

  private var episodeFilterValidationMessage: String? {
    MobileFormValidation.episodeFilterMessage(store.subscriptionEpisodeFilter)
  }

  private var episodeOffsetValidationMessage: String? {
    MobileFormValidation.signedIntegerMessage(
      store.subscriptionEpisodeOffset,
      field: "集数偏移",
      allowsEmpty: true
    )
  }
}

enum MobileSubscriptionDetailMenuPresentation {
  static let topLevelActionTitles = ["编辑", "重新识别", "清理当前订阅", "删除订阅"]
  static let contextualBulkActionTitles = ["提交全部匹配", "整理全部已下载剧集", "选择剧集整理"]
}

enum MobileSubscriptionEditorPresentation {
  static let includeKeywordsPrompt = "例如：(简体, 1080p), WEB-DL"
  static let excludeKeywordsPrompt = "例如：(先行, 1080p), CAM"

  static let persistentFieldLabels = [
    "订阅名称",
    "别名",
    "季数",
    "总集数",
    "字幕组",
    "包含词",
    "排除词",
    "起始集数",
    "指定集数",
    "集数偏移",
    "保存路径",
    "分类",
    "标签",
  ]

  static func sourceFieldLabel(for sourceType: String) -> String {
    switch sourceType {
    case "mikan_bangumi": "Mikan 番组地址"
    case "rss": "RSS 地址"
    default: "搜索关键词"
    }
  }

  static func keywordFieldLabel(for sourceType: String) -> String {
    sourceType == "rss" ? "订阅名称或关键词" : "搜索关键词"
  }

  static func accessibilityValue(for value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未设置" : trimmed
  }

  static func requiredFieldMessage(
    sourceType: String,
    name: String,
    keyword: String,
    sourceURL: String,
    rssURLs: String,
    selectedSiteCount: Int
  ) -> String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    switch sourceType {
    case "rss":
      if name.isEmpty && keyword.isEmpty { return "请输入订阅名称或关键词。" }
      if rssURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请输入 RSS 地址。"
      }
    case "mikan_bangumi":
      if keyword.isEmpty { return "请输入关键词。" }
      if sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请输入 Mikan 番组地址。"
      }
    default:
      if keyword.isEmpty { return "请输入搜索关键词。" }
    }
    return selectedSiteCount == 0 ? "请选择至少一个来源站点。" : nil
  }
}

private struct MobileSubscriptionInlineHelp: View {
  var text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct MobileSubscriptionFansubField: View {
  @Binding var text: String
  var options: [String]

  var body: some View {
    LabeledContent("字幕组") {
      HStack(spacing: 8) {
        TextField("不限字幕组", text: $text)
          .multilineTextAlignment(.trailing)
          .accessibilityLabel("字幕组")
          .accessibilityValue(MobileSubscriptionEditorPresentation.accessibilityValue(for: text))
        if !options.isEmpty {
          Menu("选择字幕组", systemImage: "chevron.up.chevron.down") {
            Button("不限字幕组") { text = "" }
            Divider()
            ForEach(options, id: \.self) { option in
              Button {
                text = option
              } label: {
                if text == option {
                  Label(option, systemImage: "checkmark")
                } else {
                  Text(option)
                }
              }
            }
          }
          .labelStyle(.iconOnly)
          .accessibilityLabel("选择字幕组")
        }
      }
    }
  }
}

private struct MobileSubscriptionTextField: View {
  var label: String
  var prompt: String
  @Binding var text: String

  var body: some View {
    LabeledContent {
      TextField(prompt, text: $text)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(label)
        .accessibilityValue(MobileSubscriptionEditorPresentation.accessibilityValue(for: text))
        .accessibilityHint("可编辑")
    } label: {
      Text(label)
    }
  }
}

private struct MobileSubscriptionTextEditor: View {
  var label: String
  var hint: String?
  @Binding var text: String
  var minHeight: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label)
        .font(.subheadline)
      TextEditor(text: $text)
        .frame(minHeight: minHeight)
        .accessibilityLabel(label)
        .accessibilityValue(MobileSubscriptionEditorPresentation.accessibilityValue(for: text))
        .accessibilityHint("可编辑")
      if let hint {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MobileSubscriptionGroupSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var newName = ""
  @State private var renameTarget: SubscriptionGroup?
  @State private var renameDraft = ""
  @State private var deleteTarget: SubscriptionGroup?

  var body: some View {
    NavigationStack {
      Form {
        if let error = store.subscriptionGroupError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Button("重新读取") { Task { await store.loadSubscriptionGroups() } }
          }
        }
        Section("新建分组") {
          TextField("分组名称", text: $newName)
          Button("添加分组", systemImage: "plus") {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
              await store.createSubscriptionGroup(name: name)
              if store.subscriptionGroupError == nil { newName = "" }
            }
          }
          .disabled(store.subscriptionGroupSubmitting || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section("分组") {
          if store.subscriptionGroupsLoading && store.subscriptionGroups.isEmpty {
            ProgressView("正在读取分组")
          }
          ForEach(store.subscriptionGroups) { group in
            HStack {
              Text(group.name)
              Spacer()
              if group.isDefault {
                Text("默认").foregroundStyle(.secondary)
              }
              Menu("分组操作", systemImage: "ellipsis") {
                if !group.isDefault {
                  Button("设为默认", systemImage: "checkmark.circle") {
                    Task { await store.setDefaultSubscriptionGroup(id: group.id) }
                  }
                }
                Button("重命名", systemImage: "pencil") {
                  renameDraft = group.name
                  renameTarget = group
                }
                if !group.isDefault {
                  Button("删除分组", systemImage: "trash", role: .destructive) {
                    let count = memberCount(group.id)
                    if count == 0 {
                      Task { await store.deleteSubscriptionGroup(id: group.id, confirmMigration: false, expectedMemberCount: 0) }
                    } else {
                      deleteTarget = group
                    }
                  }
                }
              }
              .labelStyle(.iconOnly)
              .disabled(store.subscriptionGroupSubmitting)
            }
          }
        }
      }
      .navigationTitle("分组设置")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
      .overlay(alignment: .top) {
        if store.subscriptionGroupSubmitting { ProgressView().padding(8) }
      }
    }
    .task { await store.loadSubscriptionGroups() }
    .alert("重命名分组", isPresented: Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )) {
      TextField("分组名称", text: $renameDraft)
      Button("取消", role: .cancel) { renameTarget = nil }
      Button("保存") {
        guard let group = renameTarget else { return }
        Task { await store.renameSubscriptionGroup(id: group.id, name: renameDraft) }
        renameTarget = nil
      }
      .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .confirmationDialog(
      "删除后将把该组的 \(deleteTarget.map { memberCount($0.id) } ?? 0) 条订阅移至当前默认分组。",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除并迁移", role: .destructive) {
        guard let group = deleteTarget else { return }
        let count = memberCount(group.id)
        Task { await store.deleteSubscriptionGroup(id: group.id, confirmMigration: true, expectedMemberCount: count) }
        deleteTarget = nil
      }
    }
  }

  private func memberCount(_ id: Int) -> Int {
    store.subscriptions.filter { ($0.groupId ?? 1) == id }.count
  }
}
