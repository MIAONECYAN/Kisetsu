import Foundation
import Combine
import SwiftUI

struct SubscriptionPaletteColors {
  let primary: Color
  let secondary: Color
  let background: Color
  let downloadedTrack: Color
}

struct SubscriptionPaletteAmbientStyle {
  let backgroundOpacity: Double
  let primaryOpacity: Double
  let secondaryOpacity: Double
}

enum SubscriptionPalettePresentation {
  static func colors(palette: PosterPalette?, colorScheme: ColorScheme) -> SubscriptionPaletteColors {
    let primary = color(hex: palette?.primary) ?? .accentColor
    let secondary = color(hex: palette?.secondary) ?? .accentColor
    let background = color(hex: palette?.background) ?? Color(red: 0.56, green: 0.60, blue: 0.62)
    let downloadedTrack = secondary.opacity(colorScheme == .dark ? 0.36 : 0.24)
    return SubscriptionPaletteColors(
      primary: primary,
      secondary: secondary,
      background: background,
      downloadedTrack: downloadedTrack
    )
  }

  static func color(hex: String?) -> Color? {
    guard let hex else { return nil }
    let cleaned = hex
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }

  static func ambientStyle(colorScheme: ColorScheme) -> SubscriptionPaletteAmbientStyle {
    if colorScheme == .dark {
      return SubscriptionPaletteAmbientStyle(
        backgroundOpacity: 0.05,
        primaryOpacity: 0.22,
        secondaryOpacity: 0.13
      )
    }
    return SubscriptionPaletteAmbientStyle(
      backgroundOpacity: 0.025,
      primaryOpacity: 0.11,
      secondaryOpacity: 0.07
    )
  }
}

enum OverviewPresentation {
  static func subscriptions(_ items: [Subscription]) -> [Subscription] {
    var seen = Set<Int>()
    return items.filter { seen.insert($0.id).inserted }
  }

  static func sourceSubscriptions(
    overviewItems: [Subscription]?,
    fallback: [Subscription]
  ) -> [Subscription] {
    let items = overviewItems?.isEmpty == false ? overviewItems! : fallback
    let fallbackByID = Dictionary(fallback.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return subscriptions(items).map { item in
      guard let cached = fallbackByID[item.id] else { return item }
      return mergeSubscription(item, fallback: cached)
    }
  }

  private static func mergeSubscription(_ item: Subscription, fallback: Subscription) -> Subscription {
    var merged = item
    merged.summary = item.summary ?? fallback.summary
    merged.posterUrl = item.posterUrl ?? fallback.posterUrl
    merged.posterLocalUrl = item.posterLocalUrl ?? fallback.posterLocalUrl
    merged.posterPalette = item.posterPalette ?? fallback.posterPalette
    merged.latestRefreshAt = item.latestRefreshAt ?? fallback.latestRefreshAt
    merged.latestRefreshSummary = item.latestRefreshSummary ?? fallback.latestRefreshSummary
    merged.latestOrganizedAt = item.latestOrganizedAt ?? fallback.latestOrganizedAt
    merged.latestError = item.latestError ?? fallback.latestError
    merged.metadataBindingCount = item.metadataBindingCount ?? fallback.metadataBindingCount
    merged.metadataTitles = item.metadataTitles ?? fallback.metadataTitles
    merged.coverage = item.coverage ?? fallback.coverage
    merged.episodeCount = item.episodeCount ?? fallback.episodeCount
    merged.downloadedCount = item.downloadedCount ?? fallback.downloadedCount
    merged.organizedCount = item.organizedCount ?? fallback.organizedCount
    merged.matchedCount = item.matchedCount ?? fallback.matchedCount
    merged.queuedCount = item.queuedCount ?? fallback.queuedCount
    merged.skippedCount = item.skippedCount ?? fallback.skippedCount
    merged.errorCount = item.errorCount ?? fallback.errorCount
    return merged
  }

  static func date(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
  }

  static func playlists(_ items: [PlexPlaylistSummary]) -> [PlexPlaylistSummary] {
    var seen = Set<String>()
    return items.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) != "稍后观看" }.sorted {
      let lhs = date($0.updatedAt), rhs = date($1.updatedAt)
      if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
      return $0.ratingKey < $1.ratingKey
    }.filter { seen.insert($0.ratingKey).inserted }
  }

  static func focus(subscriptions: [Subscription], overview: OverviewResponse?, now: Date = Date()) -> [Subscription] {
    let recent = (overview?.recentlyOrganized ?? []).filter {
      guard let date = date($0.completedAt) else { return false }
      return now.timeIntervalSince(date) >= 0 && now.timeIntervalSince(date) <= 604_800
    }.compactMap(\.subscriptionId)
    let downloading = (overview?.downloadingItems ?? []).compactMap { $0.target.subscriptionId }
    let all = subscriptions.sorted {
      let left = date($0.updatedAt ?? $0.createdAt) ?? .distantPast
      let right = date($1.updatedAt ?? $1.createdAt) ?? .distantPast
      return left == right ? $0.id < $1.id : left > right
    }.map(\.id)
    var seen = Set<Int>()
    let lookup = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return (recent + downloading + all).filter { seen.insert($0).inserted }.compactMap { lookup[$0] }
  }

  static func organizedLabel(_ media: OverviewOrganizedMedia) -> String {
    if media.mediaType == "movie" { return "电影已整理" }
    let episodes = Array(Set(media.episodes)).sorted()
    guard let first = episodes.first else { return "已整理" }
    if episodes.count == 1 { return "第 \(first) 集已整理" }
    let last = episodes.last!
    if last - first + 1 == episodes.count { return "第 \(first)–\(last) 集已整理" }
    return "第 \(episodes.prefix(4).map(String.init).joined(separator: "、")) 集\(episodes.count > 4 ? "等" : "")已整理"
  }

  static func focusDetail(_ subscription: Subscription, overview: OverviewResponse?) -> String {
    if let media = overview?.recentlyOrganized.first(where: { $0.subscriptionId == subscription.id }) {
      return "\(organizedLabel(media)) · \(AppRelativeTime.concise(media.completedAt))"
    }
    if let item = overview?.downloadingItems.first(where: { $0.target.subscriptionId == subscription.id }) {
      return ["正在下载", item.detail].compactMap { $0 }.joined(separator: " · ")
    }
    if let raw = subscription.latestOrganizedAt, date(raw) != nil {
      return "最近整理 · \(AppRelativeTime.concise(raw))"
    }
    if let raw = subscription.latestRefreshAt, date(raw) != nil {
      return "最近检查 · \(AppRelativeTime.concise(raw))"
    }
    return "尚无近期处理记录"
  }

  static func synopsis(_ subscription: Subscription) -> String? {
    guard let value = subscription.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  static func tasks(_ overview: OverviewResponse) -> [OverviewItem] {
    var seen = Set<String>()
    return (overview.pendingOrganizeItems + overview.downloadingItems).filter {
      let kind = $0.target.targetType == "organize_preview" ? "download_history" : $0.target.targetType
      return seen.insert("\(kind):\($0.target.targetId ?? $0.id)").inserted
    }
  }
}

@MainActor
final class OverviewPlaylistState: ObservableObject {
  @Published private(set) var playlists: [PlexPlaylistSummary] = []
  @Published var detail: PlexPlaylistDetail?
  @Published private(set) var isLoading = false
  @Published private(set) var loadingDetailID: String?
  @Published private(set) var configured: Bool?
  @Published private(set) var error: String?
  @Published private(set) var fetchedAt: Date?
  private var endpoint: String?
  private var generation = UUID()
  private var flight = PersistentSingleFlight()
  private var details: [String: PlexPlaylistDetail] = [:]

  func reset(endpoint: String) {
    guard self.endpoint != endpoint else { return }
    self.endpoint = endpoint
    generation = UUID()
    playlists = []
    details = [:]
    detail = nil
    error = nil
    fetchedAt = nil
    configured = nil
    isLoading = false
    loadingDetailID = nil
    flight = PersistentSingleFlight()
  }

  func load(client: APIClient, force: Bool = false) async {
    reset(endpoint: client.baseURL)
    let token = generation
    if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 { return }
    await flight.run { [self] in
      guard token == generation else { return }
      isLoading = true
      defer { if token == generation { isLoading = false } }
      do {
        let settings = try await client.playlistSettings()
        guard token == generation else { return }
        configured = !settings.serverUrl.isEmpty && settings.tokenConfigured
        guard configured == true else {
          playlists = []; details = [:]; fetchedAt = Date(); error = nil
          return
        }
        let result = try await client.plexPlaylists()
        guard token == generation else { return }
        playlists = OverviewPresentation.playlists(result)
        fetchedAt = Date()
        error = nil
      } catch {
        guard token == generation else { return }
        self.error = "Plex 读取失败，请重试"
      }
    }
  }

  func open(_ playlist: PlexPlaylistSummary, client: APIClient) async {
    reset(endpoint: client.baseURL)
    guard loadingDetailID == nil else { return }
    if let cached = details[playlist.ratingKey] { detail = cached; return }
    let token = generation
    loadingDetailID = playlist.ratingKey
    error = nil
    defer { if token == generation { loadingDetailID = nil } }
    do {
      let result = try await client.plexPlaylistDetail(ratingKey: playlist.ratingKey)
      guard token == generation else { return }
      details[playlist.ratingKey] = result
      detail = result
    } catch {
      guard token == generation else { return }
      self.error = "播放列表暂时无法打开，请重试"
    }
  }

  #if DEBUG
  func useFixtures(endpoint: String) {
    reset(endpoint: endpoint)
    configured = true
    playlists = OverviewPresentation.playlists(PlaylistDebugFixtures.playlists)
    for index in playlists.indices { playlists[index].posterUrl = OverviewDebugFixtures.poster(index) }
    details = Dictionary(uniqueKeysWithValues: playlists.map { ($0.ratingKey, PlaylistDebugFixtures.detail(for: $0.ratingKey)) })
    fetchedAt = Date()
  }
  #endif
}

#if DEBUG
enum OverviewDebugFixtures {
  static func poster(_ index: Int) -> String? {
    guard let base = ProcessInfo.processInfo.environment["KISETSU_OVERVIEW_ARTWORK_BASE"],
          let url = URL(string: base), url.host == "127.0.0.1", url.scheme == "http" else { return nil }
    return url.appendingPathComponent("poster-\(index % 3).jpg").absoluteString
  }

  static func overview(subscriptions: [Subscription]) -> OverviewResponse {
    let now = Date()
    let formatter = ISO8601DateFormatter()
    var subjects = subscriptions
    if let count = ProcessInfo.processInfo.environment["KISETSU_OVERVIEW_FIXTURE_COUNT"].flatMap(Int.init),
       (0...250).contains(count), let template = subjects.first {
      subjects = (0..<count).map { index in
        var item = template
        item.id = 9000 + index
        item.name = "脱敏番组 \(index + 1)"
        item.enabled = index.isMultiple(of: 2)
        return item
      }
    }
    for index in subjects.indices {
      subjects[index].posterUrl = index == 6 ? nil : poster(index)
      subjects[index].posterLocalUrl = nil
    }
    let recent = subjects.prefix(3).enumerated().map { index, item in
      OverviewOrganizedMedia(id: "fixture-media-\(index)", subscriptionId: item.id, historyId: index + 1,
        title: item.name, mediaType: index == 2 ? "movie" : "anime", episodes: index == 2 ? [] : [7, 8, 9], season: 1,
        completedAt: formatter.string(from: now.addingTimeInterval(Double(-720 - index * 3600))))
    }
    let tasks = (0..<12).map { index in
      let target = try! JSONDecoder().decode(OverviewActionTarget.self, from: Data("{\"targetType\":\"download_history\",\"targetId\":\"\(7000 + index)\",\"action\":\"open\"}".utf8))
      return OverviewItem(id: "fixture-download-\(index)", title: "脱敏下载任务 \(index + 1)", subtitle: nil,
        detail: "42% · 2.4 MB/s", status: "下载中", severity: "info", systemImage: "arrow.down.circle",
        createdAt: formatter.string(from: now), target: target)
    }
    var response = OverviewResponse(downloadingItems: Array(tasks.prefix(8)), pendingOrganizeItems: [], issues: [], recentCompleted: [],
      subscriptionSummary: .init(total: subjects.count, enabled: subjects.filter(\.enabled).count, refreshing: 0, failed: 0),
      downloadingCount: tasks.count, pendingOrganizeCount: 0, issuesCount: 0, generatedAt: formatter.string(from: now), recentlyOrganized: recent)
    response.subscriptionItems = subjects
    if let path = ProcessInfo.processInfo.environment["KISETSU_OVERVIEW_FIXTURE_JSON"],
       path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
         let generated = try? decoder.decode(OverviewResponse.self, from: data) {
        response.pendingOrganizeItems = generated.pendingOrganizeItems
        response.pendingOrganizeCount = generated.pendingOrganizeCount
      }
    }
    response.runtimeItems = [
      .init(id: "subscriptions", title: "订阅检查", detail: "自动检查已开启", state: "running", checkedAt: formatter.string(from: now.addingTimeInterval(-900)), nextAt: formatter.string(from: now.addingTimeInterval(900))),
      .init(id: "downloader:qbittorrent", title: "qBittorrent", detail: "最近检测成功", state: "success", checkedAt: formatter.string(from: now.addingTimeInterval(-300))),
      .init(id: "organize", title: "整理目标", detail: "1 个可用配置", state: "configured"),
      .init(id: "sites", title: "站点", detail: "3 个配置 · 连通状态未知", state: "configured"),
      .init(id: "brush", title: "站点刷流", detail: "已停止 · 0 个活动任务", state: "stopped"),
      .init(id: "playlists", title: "Plex", detail: "播放列表已读取", state: "success", checkedAt: formatter.string(from: now)),
    ]
    return response
  }
}
#endif
