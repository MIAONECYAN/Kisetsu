import Foundation

struct CredentialReference: Codable, Equatable, Sendable {
  var scope: String
  var field: String
  var item: String? = nil
}

struct CredentialValue: Decodable {
  var value: String
}

struct PlaylistSettingsResponse: Codable, Hashable {
  var serverUrl: String
  var tokenConfigured: Bool
  var tokenMasked: String?
  var libraryId: String?
  var libraryTitle: String?
  var cdnUrl: String
}

struct PlaylistSettingsUpdate: Codable, Hashable {
  var serverUrl: String
  var token: String?
  var clearToken: Bool
  var libraryId: String?
  var cdnUrl: String
}

struct PlexLibrary: Codable, Hashable, Identifiable {
  var id: String
  var title: String
  var type: String
}

struct PlexConnectionResponse: Codable, Hashable {
  var ok: Bool
  var message: String
  var version: String?
  var machineIdentifier: String?
  var libraries: [PlexLibrary]
}

struct PlaylistSiteLink: Codable, Hashable, Identifiable {
  var site: String
  var title: String
  var kind: String
  var url: String
  var id: String { "\(kind):\(site):\(url)" }
}

struct PlaylistQuarterOption: Codable, Hashable, Identifiable {
  var year: Int
  var month: Int
  var count: Int
  var id: String { "\(year)-\(month)" }
  var title: String { "\(year) 年 \(month) 月" }
}

struct PlexPairing: Codable, Hashable {
  var itemKey: String
  var plexRatingKey: String
  var title: String
  var year: Int?
  var source: String
  var score: Double
  var reason: String
  var valid: Bool
  var updatedAt: String?
}

struct PlaylistQuarterItem: Codable, Hashable, Identifiable {
  var key: String
  var title: String
  var originalTitle: String
  var aliases: [String]
  var mediaType: String
  var begin: String
  var broadcast: String?
  var bangumiId: String?
  var externalIds: [String: String]
  var links: [PlaylistSiteLink]
  var posterUrl: String?
  var pairing: PlexPairing?
  var matchState: String
  var matchReason: String?
  var id: String { key }
}

struct PlaylistQuarterResponse: Codable, Hashable {
  var year: Int
  var month: Int
  var title: String
  var items: [PlaylistQuarterItem]
  var cachedAt: String
  var sourceVersion: String?
  var stale: Bool
  var warning: String?
  var attribution: String
}

struct PlexShow: Codable, Hashable, Identifiable {
  var ratingKey: String
  var title: String
  var originalTitle: String?
  var year: Int?
  var libraryId: String
  var libraryTitle: String?
  var guids: [String]
  var seasonCount: Int?
  var id: String { ratingKey }
}

struct PlexEpisode: Codable, Hashable, Identifiable {
  var ratingKey: String
  var title: String
  var seasonNumber: Int
  var episodeNumber: Int
  var durationMs: Int?
  var playable: Bool
  var id: String { ratingKey }
}

struct PlexSeason: Codable, Hashable, Identifiable {
  var ratingKey: String
  var title: String
  var seasonNumber: Int
  var episodes: [PlexEpisode]
  var id: String { ratingKey }
}

struct PlexShowHierarchy: Codable, Hashable {
  var show: PlexShow
  var seasons: [PlexSeason]
}

struct PairingRequest: Codable, Hashable {
  var itemKey: String
  var plexRatingKey: String
}

struct PairingDeleteRequest: Codable, Hashable {
  var itemKey: String
}

struct PlexPlaylistSummary: Codable, Hashable, Identifiable {
  var ratingKey: String
  var title: String
  var itemCount: Int
  var durationMs: Int?
  var updatedAt: String?
  var posterUrl: String? = nil
  var id: String { ratingKey }
}

struct PlexPlaylistItem: Codable, Hashable, Identifiable {
  var ratingKey: String
  var title: String
  var showTitle: String?
  var seasonNumber: Int?
  var episodeNumber: Int?
  var durationMs: Int?
  var posterUrl: String?
  var id: String { ratingKey }
}

struct PlexPlaylistDetail: Codable, Hashable, Identifiable {
  var playlist: PlexPlaylistSummary
  var items: [PlexPlaylistItem]
  var id: String { playlist.ratingKey }
}

enum PlaylistLibraryPresentation {
  static let posterAspectRatio: CGFloat = 2.0 / 3.0
  static let mobileColumnCount = 3

  static func title(for item: PlexPlaylistItem) -> String {
    let showTitle = item.showTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return showTitle.isEmpty ? item.title : showTitle
  }

  static func seasonEpisodeText(for item: PlexPlaylistItem) -> String? {
    switch (item.seasonNumber, item.episodeNumber) {
    case let (.some(season), .some(episode)):
      return "第 \(season) 季 · 第 \(episode) 集"
    case let (.some(season), .none):
      return "第 \(season) 季"
    case let (.none, .some(episode)):
      return "第 \(episode) 集"
    case (.none, .none):
      return nil
    }
  }

  static func representativePosterURL(
    summary: PlexPlaylistSummary,
    detail: PlexPlaylistDetail? = nil
  ) -> String? {
    if let poster = nonEmpty(summary.posterUrl) { return poster }
    return detail?.items.lazy.compactMap { nonEmpty($0.posterUrl) }.first
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

#if DEBUG
enum PlaylistDebugFixtures {
  static let playlists: [PlexPlaylistSummary] = [
    summary("fixture-playlist-autumn", "2026 年 10 月番组", 20),
    summary("fixture-playlist-winter", "2026 年 1 月番组", 3),
    summary("fixture-playlist-spring", "2026 年 4 月番组", 100),
    summary("fixture-playlist-summer", "2026 年 7 月番组", 8),
    summary("fixture-playlist-empty", "稍后观看", 0),
  ]

  static func detail(for ratingKey: String) -> PlexPlaylistDetail {
    let playlist = playlists.first(where: { $0.ratingKey == ratingKey }) ?? playlists[0]
    let count = min(playlist.itemCount, 100)
    let items = (0..<count).map { index in
      PlexPlaylistItem(
        ratingKey: "\(playlist.ratingKey)-item-\(index)",
        title: "第 \((index % 24) + 1) 集",
        showTitle: fixtureTitles[index % fixtureTitles.count],
        seasonNumber: (index % 3) + 1,
        episodeNumber: (index % 24) + 1,
        durationMs: 1_440_000,
        posterUrl: nil
      )
    }
    return PlexPlaylistDetail(playlist: playlist, items: items)
  }

  private static let fixtureTitles = [
    "脱敏番组：星海纪行",
    "脱敏番组：城市晚风",
    "脱敏番组：雨后列车",
    "脱敏番组：长标题用于验证海报墙中的自然截断与稳定对齐",
    "脱敏番组：静谧书店",
    "脱敏番组：夏日信号",
    "脱敏番组：云端来信",
    "脱敏番组：午夜航线",
  ]

  private static func summary(
    _ ratingKey: String,
    _ title: String,
    _ itemCount: Int
  ) -> PlexPlaylistSummary {
    PlexPlaylistSummary(
      ratingKey: ratingKey,
      title: title,
      itemCount: itemCount,
      durationMs: itemCount * 1_440_000,
      updatedAt: "2026-08-22T12:00:00Z",
      posterUrl: nil
    )
  }
}
#endif

struct PlaylistSelection: Codable, Hashable {
  var itemKey: String
  var episodeRatingKey: String
}

struct PlaylistCreatePreviewRequest: Codable, Hashable {
  var title: String
  var year: Int
  var month: Int
  var selections: [PlaylistSelection]
}

struct PlaylistCreatePreviewItem: Codable, Hashable, Identifiable {
  var itemKey: String
  var animeTitle: String
  var plexShowTitle: String?
  var episodeRatingKey: String?
  var seasonNumber: Int?
  var episodeNumber: Int?
  var episodeTitle: String?
  var duplicate: Bool
  var valid: Bool
  var reason: String?
  var id: String { "\(itemKey):\(episodeRatingKey ?? "invalid")" }
}

struct PlaylistCreatePreviewResponse: Codable, Hashable {
  var confirmationToken: String
  var expiresAt: String
  var title: String
  var selectedCount: Int
  var episodeCount: Int
  var items: [PlaylistCreatePreviewItem]
  var warnings: [String]
  var canCreate: Bool
}

struct PlaylistCreateRequest: Codable, Hashable {
  var confirmationToken: String
  var confirm: Bool
}

struct PlaylistCreateResponse: Codable, Hashable {
  var ok: Bool
  var message: String
  var playlist: PlexPlaylistSummary?
}

struct HealthResponse: Codable {
  var ok: Bool
  var status: String
  var app: String
  var version: String
  var message: String
  var time: String
  var port: Int?
  var databaseStatus: String?
  var qbittorrentConfigured: Bool?
  var transmissionConfigured: Bool?
  var startedAt: String?
  var pid: Int?
}

struct SiteInfo: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var displayName: String?
  var baseUrl: String?
  var primaryUrl: String?
  var mirrors: [String]
  var activeBaseUrl: String?
  var enabled: Bool?
  var brushOnly: Bool? = nil
  var supportsSearch: Bool
  var supportsRss: Bool
  var supportsBrush: Bool? = nil
  var authMode: String? = nil
  var authFields: [String]? = nil
  var apiKeyConfigured: Bool? = nil
  var apiKeyMasked: String? = nil
  var cookieConfigured: Bool? = nil
  var cookieMasked: String? = nil
  var passkeyConfigured: Bool? = nil
  var passkeyMasked: String? = nil
  var authorizationConfigured: Bool? = nil
  var authorizationMasked: String? = nil
  var userAgent: String? = nil
  var timeoutSeconds: Int? = nil
  var rssUrl: String? = nil
  var rssUrlConfigured: Bool? = nil
  var rssUrlMasked: String? = nil
  var defaultRssUrl: String? = nil
  var requestHeadersConfigured: Bool? = nil
  var requestHeadersMasked: [String: String]? = nil
  var apiKey: String? = nil
  var clearApiKey: Bool? = nil
  var cookie: String? = nil
  var clearCookie: Bool? = nil
  var passkey: String? = nil
  var clearPasskey: Bool? = nil
  var authorization: String? = nil
  var clearAuthorization: Bool? = nil
  var clearRssUrl: Bool? = nil
  var requestHeadersText: String? = nil
  var clearRequestHeaders: Bool? = nil

  var label: String { displayName ?? name }
}

struct SiteSettingsUpdate: Codable, Hashable {
  var displayName: String?
  var primaryUrl: String?
  var mirrors: [String]
  var activeBaseUrl: String?
  var enabled: Bool
  var brushOnly: Bool = false
  var apiKey: String? = nil
  var clearApiKey: Bool = false
  var cookie: String? = nil
  var clearCookie: Bool = false
  var passkey: String? = nil
  var clearPasskey: Bool = false
  var authorization: String? = nil
  var clearAuthorization: Bool = false
  var userAgent: String? = nil
  var timeoutSeconds: Int? = nil
  var rssUrl: String? = nil
  var clearRssUrl: Bool = false
  var requestHeaders: [String: String]? = nil
  var clearRequestHeaders: Bool = false
}

struct SiteMirrorRequest: Codable, Hashable {
  var url: String
}

struct SiteCreateRequest: Codable, Hashable {
  var siteId: String
}

struct SiteDomainTestRequest: Codable, Hashable {
  var url: String?
}

struct SiteDomainTestResponse: Codable, Hashable {
  var ok: Bool
  var url: String
  var statusCode: Int?
  var message: String
  var rateLimitEvents: [String]
}

struct SearchRequest: Codable {
  var keyword: String
  var sites: [String]
  var channels: [String]?
  var limit: Int
  var page: Int?
  var pageSize: Int
  var maxPages: Int?
  var deduplicate: Bool
  var stopWhenNoNewResults: Bool
  var timeoutSeconds: Double?
  var includeDiagnostics: Bool
}

struct SearchResponse: Codable {
  var results: [SearchResult]
  var warnings: [String]
  var rawCount: Int?
  var displayCount: Int?
  var deduplicatedCount: Int?
  var pagesFetched: Int?
  var totalFetched: Int?
  var totalUnique: Int?
  var reachedMaxPages: Bool?
  var completedAllAccessiblePages: Bool?
  var reachedInternalSafetyLimit: Bool?
  var hasMore: Bool?
  var diagnostics: SearchDiagnostics?
}

struct SearchResult: Codable, Identifiable, Hashable {
  var id: String
  var title: String
  var subtitle: String?
  var description: String?
  var publishedAt: String?
  var size: String?
  var category: String?
  var language: String?
  var isFree: Bool?
  var discountLabel: String?
  var freeUntil: String?
  var freeRemaining: String?
  var seeders: Int?
  var leechers: Int?
  var downloads: Int?
  var sizeBytes: Int?
  var downloadFactor: Double?
  var uploadFactor: Double?
  var hitAndRun: Bool?
  var isPinned: Bool?
  var isDownloaded: Bool?
  var downloadUrl: String?
  var magnetUrl: String?
  var source: String
  var detailUrl: String?
  var sourceUrl: String?
  var mikanEpisodeId: String?
  var mikanBangumiId: String?
  var mikanGroupId: String?
  var mikanGroupName: String?
  var bangumiUrl: String?
  var bangumiId: String?
  var page: Int?
  var parsedFansub: String?
  var parsedEpisode: Int?
  var parsedEpisodeStart: Int?
  var parsedEpisodeEnd: Int?
  var parsedResolution: String?
  var parsedSubtitleLanguage: String?
  var normalizedTitle: String?
  var parsedIsBatch: Bool?
  var parsedIsMultiEpisode: Bool?
  var parsedIsSpecial: Bool?
  var parsedResourceType: String?
  var parsedSeasonNumber: Int?
  var parsedPartNumber: Int?
  var parsedAbsoluteEpisodeNumber: Int?
  var parsedAbsoluteEpisodeStart: String?
  var parsedAbsoluteEpisodeEnd: String?
  var parsedAbsoluteEpisodeStartSort: Double?
  var parsedAbsoluteEpisodeEndSort: Double?
  var parsedSeasonEpisodeStart: Int?
  var parsedSeasonEpisodeEnd: Int?
  var parsedDisplayEpisodeLabel: String?
  var parsedParseReason: String?

  var isCollectionResource: Bool {
    if parsedIsBatch == true || parsedIsMultiEpisode == true {
      return true
    }
    if parsedResourceType == "batch" || parsedResourceType == "episode_range" {
      return true
    }
    if let start = parsedEpisodeStart, let end = parsedEpisodeEnd {
      return end > start
    }
    return false
  }
}

struct SiteSearchDiagnostics: Codable, Hashable, Identifiable {
  var id: String { site }
  var site: String
  var pagesFetched: Int
  var totalFetched: Int
  var totalUnique: Int
  var stopReason: String?
  var reachedMaxPages: Bool
  var completedAllAccessiblePages: Bool
  var reachedInternalSafetyLimit: Bool
  var hasMore: Bool
  var supportsPagination: Bool
  var warnings: [String]
  var rateLimitEvents: [String]?
  var error: String?
}

struct SearchDiagnostics: Codable, Hashable {
  var pagesFetched: Int
  var totalFetched: Int
  var totalUnique: Int
  var stopReasons: [String]
  var reachedMaxPages: Bool
  var completedAllAccessiblePages: Bool
  var reachedInternalSafetyLimit: Bool
  var hasMore: Bool
  var siteDiagnostics: [SiteSearchDiagnostics]
}

struct SearchSettings: Codable, Hashable {
  var siteTimeoutSeconds: Double
}

struct MikanProjectSettings: Codable, Hashable {
  var autoRefreshEnabled: Bool = true
  var refreshIntervalHours: Int = 1
}

enum MikanProjectSectionKind: String, Codable, CaseIterable, Identifiable, Hashable {
  case monday
  case tuesday
  case wednesday
  case thursday
  case friday
  case saturday
  case sunday
  case movie
  case ova
  case unknown

  var id: String { rawValue }

  var isVisibleTab: Bool {
    switch self {
    case .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday, .movie:
      true
    case .ova, .unknown:
      false
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self = Self(rawValue: try container.decode(String.self)) ?? .unknown
  }
}

struct MikanProjectAnime: Codable, Identifiable, Hashable {
  var id: String { bangumiId }
  var bangumiId: String
  var title: String
  var originalTitle: String?
  var synopsis: String?
  var posterUrl: String?
  var posterOriginalUrl: String?
  var posterLocalUrl: String?
  var posterPalette: PosterPalette?
  var detailUrl: String?
  var updateDate: String?
  var airDate: String?
  var broadcastDay: String?
  var broadcastStart: String?
  var totalEpisodes: Int?
  var officialUrl: String?
  var bangumiUrl: String?
  var bangumiSubjectId: String?
  var section: MikanProjectSectionKind
  var subscribed: Bool
  var isGrayscale: Bool
  var statusText: String?
  var resourceCount: Int?
}

struct MikanProjectSection: Codable, Identifiable, Hashable {
  var id: MikanProjectSectionKind
  var name: String
  var shortName: String
  var items: [MikanProjectAnime]
}

struct MikanProjectSeasonResponse: Codable, Hashable {
  var cacheVersion: Int
  var seasonTitle: String
  var year: Int
  var season: String
  var cachedAt: String?
  var lastRefreshStartedAt: String?
  var settings: MikanProjectSettings
  var sections: [MikanProjectSection]
  var warnings: [String]

  var visibleSections: [MikanProjectSection] {
    sections.filter { $0.id.isVisibleTab }
  }
}

struct MikanProjectSelectionState: Equatable {
  var selectedSection: MikanProjectSectionKind = .monday

  mutating func synchronize(with season: MikanProjectSeasonResponse) {
    let visibleSections = season.visibleSections
    guard !visibleSections.contains(where: { $0.id == selectedSection }) else { return }
    selectedSection = visibleSections.first?.id ?? .monday
  }

  func items(in season: MikanProjectSeasonResponse) -> [MikanProjectAnime] {
    season.visibleSections.first(where: { $0.id == selectedSection })?.items ?? []
  }
}

struct MikanProjectResourceGroup: Codable, Identifiable, Hashable {
  var id: String { fansubId ?? fansub }
  var fansubId: String?
  var fansub: String
  var resources: [SearchResult]
}

struct MikanProjectResourcesResponse: Codable, Hashable {
  var anime: MikanProjectAnime?
  var groups: [MikanProjectResourceGroup]
  var warnings: [String]
}

struct QbittorrentConfig: Codable, Equatable {
  var baseUrl: String = "http://127.0.0.1:8080"
  var username: String = ""
  var password: String = ""
  var defaultSavePath: String? = nil
  var defaultCategory: String? = "anime"
  var defaultTags: [String] = ["kisetsu"]
  var passwordConfigured: Bool = false
  var clearPassword: Bool = false
}

struct TransmissionConfig: Codable, Equatable {
  var baseUrl: String = "http://127.0.0.1:9091"
  var username: String = ""
  var password: String = ""
  var defaultSavePath: String? = nil
  var defaultLabels: [String] = ["kisetsu"]
  var passwordConfigured: Bool = false
  var clearPassword: Bool = false
}

struct DownloaderStatus: Codable, Hashable, Identifiable {
  var id: String { downloader }
  var downloader: String
  var configured: Bool
  var verified: Bool
  var stage: String? = nil
  var errorCode: String? = nil
  var version: String?
  var checkedAt: String?
  var message: String
}

struct DownloaderRoutingSettings: Codable, Equatable {
  var subscriptionDownloader: String = "qbittorrent"
  var brushDownloader: String = "qbittorrent"
  var manualDownloader: String = "qbittorrent"
}

struct DownloaderRoutingResponse: Codable {
  var subscriptionDownloader: String
  var brushDownloader: String
  var manualDownloader: String
  var statuses: [DownloaderStatus]
}

struct QbittorrentTestResponse: Codable {
  var ok: Bool
  var downloader: String? = nil
  var stage: String? = nil
  var errorCode: String? = nil
  var version: String?
  var message: String
}

struct TransmissionTestResponse: Codable {
  var ok: Bool
  var downloader: String? = nil
  var stage: String? = nil
  var errorCode: String? = nil
  var version: String?
  var message: String
  var rpcVersion: Int?
}

struct QbittorrentGlobalLimits: Codable, Equatable {
  var downloadLimit: Int = 0
  var uploadLimit: Int = 0
}

struct MetadataSettings: Codable, Hashable {
  var tmdbApiKey: String?
  var clearTmdbApiKey: Bool = false
}

struct MetadataSettingsResponse: Codable, Hashable {
  var tmdbConfigured: Bool
  var tmdbApiKeyConfigured: Bool
  var tmdbApiKeyMasked: String?
  var message: String
}

struct AISettings: Codable, Hashable {
  var enabled: Bool = false
  var provider: String = "none"
  var baseUrl: String? = nil
  var model: String? = nil
  var apiKey: String? = nil
  var useAiForSmartSubscription: Bool = false
  var clearApiKey: Bool = false
}

struct AISettingsResponse: Codable, Hashable {
  var enabled: Bool
  var provider: String
  var baseUrl: String?
  var model: String?
  var apiKeyConfigured: Bool
  var apiKeyMasked: String?
  var useAiForSmartSubscription: Bool
  var configured: Bool
  var message: String
  var providerProfiles: [String: AIProviderProfileResponse]? = nil
}

struct AIProviderProfileResponse: Codable, Hashable {
  var baseUrl: String?
  var model: String?
  var apiKeyConfigured: Bool
  var apiKeyMasked: String?
}

struct AITitleAnalyzeRequest: Codable, Hashable {
  var title: String
  var subscriptionName: String?
  var aliases: [String]
  var site: String?
  var localParse: ParsedAnimeTitle?
}

struct AIModelListRequest: Codable, Hashable {
  var provider: String
  var baseUrl: String?
  var apiKey: String?
  var selectedModel: String?
}

struct AIModelInfo: Codable, Hashable, Identifiable {
  var id: String
  var name: String?
  var ownedBy: String?
  var created: Int?
}

struct AIModelListResponse: Codable, Hashable {
  var ok: Bool
  var models: [AIModelInfo]
  var selectedModel: String?
  var message: String
  var errorCode: String?
}

struct AITitleAnalysisResponse: Codable, Hashable {
  var ok: Bool
  var message: String
  var rawTitle: String?
  var fansub: String?
  var animeTitle: String?
  var animeTitleOriginal: String?
  var animeTitleAliases: [String]
  var episodeNumber: Int?
  var episodeStart: Int?
  var episodeEnd: Int?
  var isBatch: Bool
  var isFinal: Bool?
  var finalConfidence: Double
  var resolution: String?
  var subtitleLanguage: String?
  var sourceTags: [String]
  var formatTags: [String]
  var releaseGroup: String?
  var confidence: Double
  var reason: String?
  var suggestedRegex: String?
  var warnings: [String]
  var requiresConfirmation: Bool
  var errorCode: String? = nil
}

struct TMDBTestRequest: Codable {
  var tmdbApiKey: String?
}

struct OrganizePolicySettings: Codable, Hashable {
  var autoOrganizeByDefault: Bool
  var postOrganizeAction: String?
  var deleteTaskAfterOrganize: Bool
  var deleteFilesAfterOrganize: Bool
  var keepSeeding: Bool
  var seedingStopRatio: Double?
  var seedingStopMinutes: Int?
  var seedingStopMode: String?
  var postSeedingAction: String?
  var cleanEmptyDownloadDirs: Bool?
}

struct AppSettingsResponse: Codable, Hashable {
  var metadata: MetadataSettingsResponse
  var organizePolicy: OrganizePolicySettings
}

struct BarkNotificationSettings: Codable, Hashable {
  var enabled: Bool = false
  var serverUrl: String = "https://api.day.app"
  var deviceKey: String? = nil
  var clearDeviceKey: Bool = false
  var group: String = "Kisetsu"
  var sound: String? = nil
  var icon: String? = nil
  var level: String = "active"
  var url: String? = nil
  var autoCopy: Bool = false
}

struct NotificationEventSettings: Codable, Hashable {
  var subscription: Bool = true
  var download: Bool = true
  var organize: Bool = true
}

struct NotificationSettings: Codable, Hashable {
  var enabled: Bool = false
  var bark: BarkNotificationSettings = BarkNotificationSettings()
  var events: NotificationEventSettings = NotificationEventSettings()
  var showFullPaths: Bool = false
}

struct BarkNotificationSettingsResponse: Codable, Hashable {
  var enabled: Bool
  var serverUrl: String
  var hasDeviceKey: Bool
  var maskedDeviceKey: String?
  var group: String
  var sound: String?
  var icon: String?
  var level: String
  var url: String?
  var autoCopy: Bool
}

struct NotificationSettingsResponse: Codable, Hashable {
  var enabled: Bool
  var bark: BarkNotificationSettingsResponse
  var events: NotificationEventSettings
  var showFullPaths: Bool
  var message: String
}

struct NotificationTestRequest: Codable, Hashable {
  var provider: String = "bark"
  var title: String? = nil
  var body: String? = nil
}

struct NotificationTestResponse: Codable, Hashable {
  var ok: Bool
  var provider: String
  var message: String
}

struct DownloadRequest: Codable {
  var result: SearchResult
  var qbittorrent: QbittorrentConfig?
  var downloaderType: String? = nil
  var savePath: String?
  var organizeTargetId: Int? = nil
  var category: String?
  var tags: [String]
  var dryRun: Bool
}

struct DownloadResponse: Codable {
  var ok: Bool
  var message: String
  var historyId: Int?
  var organizeTargetId: Int?
}

struct SubscriptionDownloadRequest: Codable {
  var matchIds: [Int]
  var allMatches: Bool
  var dryRun: Bool
}

struct SubscriptionDownloadResponse: Codable {
  var subscriptionId: Int
  var ok: Bool
  var message: String
  var submitted: [SearchResult]
  var skipped: [SearchResult]
  var historyIds: [Int]
  var warnings: [String]
}

struct EpisodeParseRule: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var pattern: String
  var enabled: Bool
  var priority: Int
  var episodeGroup: String
  var startGroup: String
  var endGroup: String
  var finalGroup: String
  var ruleType: String = "user"
  var mode: String = "regex"
  var sampleTitle: String?
  var exampleTitle: String?
  var description: String?
  var visualMarks: [EpisodeRuleVisualMark] = []
  var generatedPattern: String?
}

struct EpisodeRuleVisualMark: Codable, Identifiable, Hashable {
  var id: String { "\(markType)-\(tokenId)-\(startIndex)-\(endIndex)-\(splitGroupId ?? "")" }
  var tokenId: Int
  var tokenText: String
  var markType: String
  var startIndex: Int
  var endIndex: Int
  var splitGroupId: String? = nil
}

struct EpisodeTitleToken: Codable, Identifiable, Hashable {
  var id: Int
  var text: String
  var startIndex: Int
  var endIndex: Int
  var kind: String
  var splitGroupId: String? = nil
  var isSplit: Bool = false
}

struct EpisodeRuleTokenizeRequest: Codable, Hashable {
  var title: String
}

struct EpisodeRuleTokenizeResponse: Codable, Hashable {
  var title: String
  var tokens: [EpisodeTitleToken]
}

struct EpisodeRulePreviewRequest: Codable, Hashable {
  var title: String
  var marks: [EpisodeRuleVisualMark]
  var name: String?
}

struct EpisodeRulePreviewResponse: Codable, Hashable {
  var ok: Bool
  var message: String
  var rule: EpisodeParseRule?
  var parsedTitle: ParsedAnimeTitle?
  var tokens: [EpisodeTitleToken]
  var suggestions: [String]
  var generatedPattern: String? = nil
  var confidence: Double? = nil
  var explanation: [String] = []
  var warnings: [String] = []
  var markedTokens: [EpisodeRuleVisualMark] = []
  var positiveTests: [String] = []
  var negativeTests: [String] = []
}

struct EpisodeRuleSettingsResponse: Codable, Hashable {
  var builtinRules: [EpisodeParseRule]
  var userRules: [EpisodeParseRule]
}

struct EpisodeRuleSettingsUpdate: Codable, Hashable {
  var userRules: [EpisodeParseRule]
}

struct SubscriptionCreate: Codable {
  var name: String
  var keyword: String
  var sourceType: String
  var identityKey: String? = nil
  var sites: [String]
  var sourceUrl: String?
  var mikanBangumiUrl: String?
  var aliases: [String]
  var rssUrls: [String]
  var regex: String?
  var regexEnabled: Bool
  var episodeFilter: String?
  var includeKeywords: [String]
  var excludeKeywords: [String]
  var filterOrder: String
  var fansub: String?
  var resolution: String?
  var resolutionMode: String
  var resolutionPreset: String?
  var resolutionCustom: String?
  var minSizeBytes: Int? = nil
  var maxSizeBytes: Int? = nil
  var season: Int?
  var episode: Int?
  var episodeStart: Int?
  var episodeOffset: Int
  var batchResourcePolicy: String
  var episodeParseRules: [EpisodeParseRule]
  var totalEpisodes: Int?
  var totalEpisodesSource: String?
  var metadataEpisodeCount: Int?
  var enabled: Bool
  var autoDownload: Bool
  var organizeTargetId: Int?
  var autoOrganize: Bool
  var postOrganizeAction: String?
  var deleteTaskAfterOrganize: Bool?
  var deleteFilesAfterOrganize: Bool?
  var keepSeeding: Bool?
  var seedingPolicyMode: String = "inherit"
  var seedingStopRatio: Double? = nil
  var seedingStopMinutes: Int? = nil
  var seedingStopMode: String = "any"
  var postSeedingAction: String = "pause"
  var savePath: String?
  var category: String?
  var tags: [String]
  var autoUpdateTotalEpisodes: Bool? = true
  var groupId: Int? = nil
}

struct Subscription: Codable, Identifiable, Hashable {
  var id: Int
  var name: String
  var keyword: String
  var sourceType: String?
  var identityKey: String? = nil
  var sites: [String]
  var sourceUrl: String?
  var mikanBangumiUrl: String?
  var aliases: [String]
  var rssUrls: [String]
  var regex: String?
  var regexEnabled: Bool
  var episodeFilter: String?
  var includeKeywords: [String]
  var excludeKeywords: [String]
  var filterOrder: String
  var fansub: String?
  var resolution: String?
  var resolutionMode: String?
  var resolutionPreset: String?
  var resolutionCustom: String?
  var minSizeBytes: Int?
  var maxSizeBytes: Int?
  var season: Int?
  var episode: Int?
  var episodeStart: Int?
  var episodeOffset: Int
  var batchResourcePolicy: String?
  var episodeParseRules: [EpisodeParseRule]
  var totalEpisodes: Int?
  var totalEpisodesSource: String?
  var metadataEpisodeCount: Int?
  var enabled: Bool
  var autoDownload: Bool
  var organizeTargetId: Int?
  var autoOrganize: Bool?
  var postOrganizeAction: String?
  var deleteTaskAfterOrganize: Bool?
  var deleteFilesAfterOrganize: Bool?
  var keepSeeding: Bool?
  var seedingPolicyMode: String?
  var seedingStopRatio: Double?
  var seedingStopMinutes: Int?
  var seedingStopMode: String?
  var postSeedingAction: String?
  var savePath: String?
  var category: String?
  var tags: [String]
  var createdAt: String
  var updatedAt: String?
  var matchedCount: Int?
  var queuedCount: Int?
  var skippedCount: Int?
  var errorCount: Int?
  var episodeCount: Int?
  var downloadedCount: Int?
  var organizedCount: Int?
  var latestRefreshAt: String?
  var latestRefreshSummary: String?
  var latestOrganizedAt: String?
  var latestError: String?
  var metadataBindingCount: Int?
  var metadataTitles: [String]?
  var posterUrl: String?
  var posterLocalUrl: String?
  var posterPalette: PosterPalette?
  var coverage: SubscriptionCoverageSummary?
  var summary: String? = nil
  var autoUpdateTotalEpisodes: Bool? = true
  var groupId: Int? = nil
}

struct SubscriptionGroup: Codable, Identifiable, Hashable {
  var id: Int
  var name: String
  var isDefault: Bool
  var createdAt: String
  var updatedAt: String?
}

struct SubscriptionGroupNameRequest: Encodable {
  var name: String
}

struct SubscriptionGroupDeleteRequest: Encodable {
  var confirmMigration: Bool
  var expectedMemberCount: Int
}

struct SubscriptionGroupDeleteResponse: Decodable {
  var ok: Bool
  var migratedCount: Int
}

enum SubscriptionGroupFilter {
  static func apply(
    _ subscriptions: [Subscription],
    selectedGroupID: Int?,
    completion: SubscriptionListFilter,
    query: String
  ) -> [Subscription] {
    let grouped = subscriptions.filter { selectedGroupID == nil || ($0.groupId ?? 1) == selectedGroupID }
    return SubscriptionSearch.filter(completion.apply(to: grouped), query: query)
  }
}

struct PosterPalette: Codable, Hashable {
  var primary: String
  var secondary: String
  var accent: String
  var background: String
  var textContrast: String
}

struct SubscriptionCoverageSummary: Codable, Hashable {
  var totalEpisodes: Int
  var catalogTotalEpisodes: Int?
  var targetTotalEpisodes: Int?
  var skippedBeforeStart: Int?
  var downloadedCount: Int
  var organizedCount: Int
  var downloadedRanges: [String]
  var organizedRanges: [String]
  var hasBatchDownload: Bool
  var hasBatchOrganized: Bool
  var batchStatusLabel: String?
}

struct SubscriptionProgressMetrics: Hashable {
  var total: Int
  var downloaded: Int
  var organized: Int

  var downloadedText: String { "\(downloaded)/\(total)" }
  var organizedText: String { "\(organized)/\(total)" }
  var downloadedFraction: Double {
    guard total > 0 else { return 0 }
    return Double(downloaded) / Double(total)
  }
  var organizedFraction: Double {
    guard total > 0 else { return 0 }
    return Double(organized) / Double(total)
  }
}

struct SubscriptionTargetProgressPresentation: Hashable {
  var targetTotal: Int?
  var downloaded: Int
  var organized: Int
  var startBadgeText: String?

  init(subscription: Subscription) {
    let coverage = subscription.coverage
    if let targetTotal = coverage?.targetTotalEpisodes {
      self.targetTotal = targetTotal
    } else if let legacyTotal = coverage?.totalEpisodes, legacyTotal > 0 {
      targetTotal = legacyTotal
    } else if let legacyTotal = subscription.episodeCount, legacyTotal > 0 {
      targetTotal = legacyTotal
    } else {
      targetTotal = nil
    }

    let rawDownloaded = coverage?.downloadedCount ?? subscription.downloadedCount ?? 0
    let rawOrganized = coverage?.organizedCount ?? subscription.organizedCount ?? 0
    if let targetTotal, targetTotal > 0 {
      downloaded = min(rawDownloaded, targetTotal)
      organized = min(rawOrganized, targetTotal)
    } else {
      downloaded = rawDownloaded
      organized = rawOrganized
    }

    if let episodeStart = subscription.episodeStart, episodeStart > 1 {
      startBadgeText = "从 E\(episodeStart) 开始"
    } else {
      startBadgeText = nil
    }
  }

  var metrics: SubscriptionProgressMetrics? {
    guard let targetTotal, targetTotal > 0 else { return nil }
    return SubscriptionProgressMetrics(total: targetTotal, downloaded: downloaded, organized: organized)
  }

  var fallbackText: String? {
    if targetTotal == 0 {
      return "暂无需处理集数"
    }
    if targetTotal == nil {
      return "下载 \(downloaded) 集 · 整理 \(organized) 集 · 总数待识别"
    }
    return nil
  }
}

enum SubscriptionListFilter: String, CaseIterable, Identifiable, Hashable {
  case all
  case completed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "全部订阅"
    case .completed: "订阅完成"
    }
  }

  var emptyTitle: String {
    switch self {
    case .all: "暂无订阅"
    case .completed: "没有订阅完成的项目"
    }
  }

  func includes(_ subscription: Subscription) -> Bool {
    switch self {
    case .all:
      true
    case .completed:
      SubscriptionCompletionPresentation(subscription: subscription).isComplete
    }
  }

  func apply(to subscriptions: [Subscription]) -> [Subscription] {
    guard self != .all else { return subscriptions }
    return subscriptions.filter(includes)
  }
}

struct SubscriptionCompletionPresentation: Hashable {
  private enum EpisodeFilterParseResult: Equatable {
    case absent
    case valid(Set<Int>)
    case invalid
  }

  let targetEpisodes: Set<Int>?
  let downloadedEpisodes: Set<Int>?
  let organizedEpisodes: Set<Int>?
  let isComplete: Bool

  init(subscription: Subscription) {
    if Self.parseEpisodeFilter(subscription.episodeFilter) == .invalid {
      targetEpisodes = nil
      downloadedEpisodes = nil
      organizedEpisodes = nil
      isComplete = false
      return
    }

    let progress = SubscriptionTargetProgressPresentation(subscription: subscription)
    guard let progressMetrics = progress.metrics else {
      targetEpisodes = nil
      downloadedEpisodes = nil
      organizedEpisodes = nil
      isComplete = false
      return
    }

    guard let coverage = subscription.coverage,
          let catalogTotal = Self.catalogTotal(subscription: subscription, coverage: coverage),
          catalogTotal > 0,
          let targets = Self.targetEpisodes(
            subscription: subscription,
            catalogTotal: catalogTotal
          ),
          !targets.isEmpty else {
      targetEpisodes = nil
      downloadedEpisodes = subscription.coverage.flatMap { Self.episodeSet(from: $0.downloadedRanges) }
      organizedEpisodes = subscription.coverage.flatMap { Self.episodeSet(from: $0.organizedRanges) }
      isComplete = progressMetrics.downloaded >= progressMetrics.total
        && progressMetrics.organized >= progressMetrics.total
      return
    }

    targetEpisodes = targets
    downloadedEpisodes = Self.episodeSet(from: coverage.downloadedRanges)
    organizedEpisodes = Self.episodeSet(from: coverage.organizedRanges)

    if let downloadedEpisodes, let organizedEpisodes,
       targets.isSubset(of: downloadedEpisodes),
       targets.isSubset(of: organizedEpisodes) {
      isComplete = true
      return
    }

    let backendTarget = coverage.targetTotalEpisodes ?? (coverage.totalEpisodes > 0 ? coverage.totalEpisodes : nil)
    isComplete = backendTarget == targets.count
      && progressMetrics.total == targets.count
      && progressMetrics.downloaded >= targets.count
      && progressMetrics.organized >= targets.count
  }

  private static func catalogTotal(
    subscription: Subscription,
    coverage: SubscriptionCoverageSummary
  ) -> Int? {
    if let value = coverage.catalogTotalEpisodes, value > 0 { return value }
    if let value = subscription.totalEpisodes, value > 0 { return value }
    if let value = subscription.metadataEpisodeCount, value > 0 { return value }
    return nil
  }

  private static func targetEpisodes(
    subscription: Subscription,
    catalogTotal: Int
  ) -> Set<Int>? {
    let start = max(1, (subscription.episodeStart ?? 1) + subscription.episodeOffset)
    guard start <= catalogTotal else { return [] }
    var targets = Set(start...catalogTotal)

    if let episode = subscription.episode {
      let logicalEpisode = episode + subscription.episodeOffset
      targets.formIntersection([logicalEpisode])
    }

    switch parseEpisodeFilter(subscription.episodeFilter) {
    case .absent:
      break
    case .valid(let filteredEpisodes):
      targets.formIntersection(filteredEpisodes)
    case .invalid:
      return nil
    }

    return targets
  }

  private static func parseEpisodeFilter(_ value: String?) -> EpisodeFilterParseResult {
    guard let value else { return .absent }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .absent }

    var episodes: Set<Int> = []
    for rawPart in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
      let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !part.isEmpty else { return .invalid }
      if let episode = Int(part), episode > 0 {
        episodes.insert(episode)
        continue
      }
      let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      guard bounds.count == 2,
            let lower = Int(bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
            let upper = Int(bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
            lower > 0,
            upper >= lower else {
        return .invalid
      }
      episodes.formUnion(lower...upper)
    }
    return episodes.isEmpty ? .invalid : .valid(episodes)
  }

  private static func episodeSet(from ranges: [String]) -> Set<Int>? {
    guard !ranges.isEmpty else { return [] }
    var episodes: Set<Int> = []
    for rawRange in ranges {
      let value = rawRange.trimmingCharacters(in: .whitespacesAndNewlines)
      if let episode = Int(value), episode > 0 {
        episodes.insert(episode)
        continue
      }
      let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      guard bounds.count == 2,
            let lower = Int(bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
            let upper = Int(bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
            lower > 0,
            upper >= lower else {
        return nil
      }
      episodes.formUnion(lower...upper)
    }
    return episodes
  }
}

struct OverviewActionTarget: Codable, Hashable {
  var targetType: String
  var targetId: String?
  var subscriptionId: Int?
  var action: String

  enum CodingKeys: String, CodingKey {
    case targetType
    case targetId
    case subscriptionId
    case action
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    targetType = try container.decode(String.self, forKey: .targetType)
    if let value = try? container.decodeIfPresent(String.self, forKey: .targetId) {
      targetId = value
    } else if let value = try? container.decodeIfPresent(Int.self, forKey: .targetId) {
      targetId = String(value)
    } else {
      targetId = nil
    }
    subscriptionId = try container.decodeIfPresent(Int.self, forKey: .subscriptionId)
    action = try container.decodeIfPresent(String.self, forKey: .action) ?? "open"
  }
}

struct OverviewItem: Codable, Identifiable, Hashable {
  var id: String
  var title: String
  var subtitle: String?
  var detail: String?
  var status: String?
  var severity: String
  var systemImage: String?
  var createdAt: String?
  var target: OverviewActionTarget
}

struct OverviewSubscriptionSummary: Codable, Hashable {
  var total: Int
  var enabled: Int
  var refreshing: Int
  var failed: Int
  var latestRefreshSummary: String?
  var latestError: String?
}

struct OverviewResponse: Codable, Hashable {
  var downloadingItems: [OverviewItem]
  var pendingOrganizeItems: [OverviewItem]
  var issues: [OverviewItem]
  var recentCompleted: [OverviewItem]
  var subscriptionSummary: OverviewSubscriptionSummary
  var downloadingCount: Int?
  var pendingOrganizeCount: Int?
  var issuesCount: Int?
  var recentCompletedCount: Int?
  var generatedAt: String? = nil
  var recentlyOrganized: [OverviewOrganizedMedia] = []
  var runtimeItems: [OverviewRuntimeItem] = []
  var subscriptionItems: [Subscription]? = nil

  enum CodingKeys: String, CodingKey {
    case downloadingItems, pendingOrganizeItems, issues, recentCompleted, subscriptionSummary
    case downloadingCount, pendingOrganizeCount, issuesCount, recentCompletedCount, generatedAt, recentlyOrganized, runtimeItems, subscriptionItems
  }

  init(downloadingItems: [OverviewItem], pendingOrganizeItems: [OverviewItem], issues: [OverviewItem], recentCompleted: [OverviewItem], subscriptionSummary: OverviewSubscriptionSummary, downloadingCount: Int? = nil, pendingOrganizeCount: Int? = nil, issuesCount: Int? = nil, recentCompletedCount: Int? = nil, generatedAt: String? = nil, recentlyOrganized: [OverviewOrganizedMedia] = []) {
    self.downloadingItems = downloadingItems
    self.pendingOrganizeItems = pendingOrganizeItems
    self.issues = issues
    self.recentCompleted = recentCompleted
    self.subscriptionSummary = subscriptionSummary
    self.downloadingCount = downloadingCount
    self.pendingOrganizeCount = pendingOrganizeCount
    self.issuesCount = issuesCount
    self.recentCompletedCount = recentCompletedCount
    self.generatedAt = generatedAt
    self.recentlyOrganized = recentlyOrganized
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    downloadingItems = try c.decodeIfPresent([OverviewItem].self, forKey: .downloadingItems) ?? []
    pendingOrganizeItems = try c.decodeIfPresent([OverviewItem].self, forKey: .pendingOrganizeItems) ?? []
    issues = try c.decodeIfPresent([OverviewItem].self, forKey: .issues) ?? []
    recentCompleted = try c.decodeIfPresent([OverviewItem].self, forKey: .recentCompleted) ?? []
    subscriptionSummary = try c.decodeIfPresent(OverviewSubscriptionSummary.self, forKey: .subscriptionSummary) ?? OverviewSubscriptionSummary(total: 0, enabled: 0, refreshing: 0, failed: 0, latestRefreshSummary: nil, latestError: nil)
    downloadingCount = try c.decodeIfPresent(Int.self, forKey: .downloadingCount)
    pendingOrganizeCount = try c.decodeIfPresent(Int.self, forKey: .pendingOrganizeCount)
    issuesCount = try c.decodeIfPresent(Int.self, forKey: .issuesCount)
    recentCompletedCount = try c.decodeIfPresent(Int.self, forKey: .recentCompletedCount)
    generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
    recentlyOrganized = try c.decodeIfPresent([OverviewOrganizedMedia].self, forKey: .recentlyOrganized) ?? []
    runtimeItems = try c.decodeIfPresent([OverviewRuntimeItem].self, forKey: .runtimeItems) ?? []
    subscriptionItems = try c.decodeIfPresent([Subscription].self, forKey: .subscriptionItems)
  }
}

struct OverviewOrganizedMedia: Codable, Hashable, Identifiable {
  var id: String
  var subscriptionId: Int?
  var historyId: Int
  var title: String
  var mediaType: String
  var episodes: [Int]
  var season: Int?
  var completedAt: String
}

struct OverviewRuntimeItem: Codable, Hashable, Identifiable {
  var id: String
  var title: String
  var detail: String
  var state: String
  var checkedAt: String?
  var nextAt: String?
}

struct SubscriptionSuggestionRequest: Codable {
  var result: SearchResult
  var sites: [String]
  var organizeTargetId: Int?
  var savePath: String?
  var category: String?
  var tags: [String]
}

struct SubscriptionSuggestionResponse: Codable {
  var ok: Bool
  var message: String
  var parsedTitle: ParsedAnimeTitle
  var suggestion: SubscriptionCreate?
  var confidence: Double
  var warnings: [String]
  var duplicateSubscriptionId: Int?
  var duplicateSubscriptionName: String?
  var identityKey: String? = nil
  var matchStatus: String = "none"
  var matchReason: String? = nil
  var matchCandidateIds: [Int] = []
  var matchedSubscription: Subscription? = nil
}

struct SmartSubscriptionPrefillRequest: Codable {
  var result: SearchResult
  var sites: [String]
  var organizeTargetId: Int?
  var savePath: String?
  var category: String?
  var tags: [String]
  var useAi: Bool?
}

struct SmartSubscriptionPrefillResponse: Codable {
  var ok: Bool
  var message: String
  var formDefaults: SubscriptionCreate?
  var aiResult: AITitleAnalysisResponse?
  var localResult: ParsedAnimeTitle
  var source: String
  var warnings: [String]
  var duplicateSubscriptionId: Int?
  var duplicateSubscriptionName: String?
  var identityKey: String? = nil
  var matchStatus: String = "none"
  var matchReason: String? = nil
  var matchCandidateIds: [Int] = []
  var matchedSubscription: Subscription? = nil

  var asSuggestionResponse: SubscriptionSuggestionResponse {
    SubscriptionSuggestionResponse(
      ok: ok,
      message: message,
      parsedTitle: localResult,
      suggestion: formDefaults,
      confidence: aiResult?.confidence ?? localResult.confidence,
      warnings: warnings,
      duplicateSubscriptionId: duplicateSubscriptionId,
      duplicateSubscriptionName: duplicateSubscriptionName,
      identityKey: identityKey,
      matchStatus: matchStatus,
      matchReason: matchReason,
      matchCandidateIds: matchCandidateIds,
      matchedSubscription: matchedSubscription
    )
  }
}

struct RefreshResponse: Codable {
  var subscriptionId: Int
  var refreshHistoryId: Int?
  var matched: [SearchResult]
  var added: [SearchResult]
  var skipped: [SearchResult]
  var matchRecords: [SubscriptionMatch]
  var warnings: [String]
  var diagnostics: MatchDiagnostics?
}

struct MatchDiagnosticSample: Codable, Identifiable, Hashable {
  var id: String { "\(source)-\(title)-\(reason)" }
  var title: String
  var source: String
  var reason: String
  var parsedFansub: String?
  var siteFansubId: String?
  var siteFansub: String?
  var parsedResolution: String?
  var parsedEpisode: Int?
  var parsedEpisodeStart: Int?
  var parsedEpisodeEnd: Int?
  var resourceType: String?
  var displayEpisodeLabel: String?
  var isBatch: Bool?
  var isMultiEpisode: Bool?
  var absoluteEpisodeStart: String?
  var absoluteEpisodeEnd: String?
  var seasonEpisodeStart: Int?
  var seasonEpisodeEnd: Int?
  var isFinal: Bool?
  var parseRuleName: String?
  var parseFailureReason: String?
  var explicitSeasonNumber: Int?
  var inferredSeasonNumber: Int?
  var contextSeasonNumber: Int?
  var effectiveSeasonNumber: Int?
  var seasonSource: String?
  var seasonConflict: Bool?
  var seasonConflictReason: String?
  var titleMatchSource: String?
  var episodeParseSource: String?
  var seasonParseSource: String?
  var fansubParseSource: String?
  var resolutionParseSource: String?
  var parseConflictReason: String?
}

struct MatchDiagnostics: Codable, Hashable {
  var totalFetched: Int
  var totalUnique: Int?
  var pagesFetched: Int?
  var stopReasons: [String]?
  var reachedMaxPages: Bool?
  var completedAllAccessiblePages: Bool?
  var reachedInternalSafetyLimit: Bool?
  var hasMore: Bool?
  var matchedCount: Int
  var matchedBySubtitle: Int?
  var episodeParsedFromSubtitle: Int?
  var excludedByTitle: Int
  var excludedByFansub: Int
  var excludedByInclude: Int
  var excludedByExclude: Int
  var excludedByResolution: Int
  var excludedBySize: Int?
  var excludedByRegex: Int
  var excludedByEpisodeFilter: Int
  var excludedByBatchPolicy: Int?
  var excludedByEpisodeCoverage: Int?
  var seasonMatchedCount: Int?
  var excludedBySeasonMismatch: Int?
  var excludedByMetadataMismatch: Int?
  var excludedByBangumiIdMismatch: Int?
  var duplicateCount: Int
  var parseFailedCount: Int
  var searchDiagnostics: SearchDiagnostics?
  var sampleExcludedItems: [MatchDiagnosticSample]
}

struct SubscriptionTestMatchRequest: Codable {
  var subscription: SubscriptionCreate
}

struct SubscriptionTestMatchResponse: Codable {
  var ok: Bool
  var message: String
  var matched: [SearchResult]
  var matchedSamples: [MatchDiagnosticSample]
  var excluded: [MatchDiagnosticSample]
  var diagnostics: MatchDiagnostics
  var warnings: [String]
}

struct RssTestRequest: Codable {
  var url: String?
  var site: String
  var siteSettings: SiteSettingsUpdate? = nil
  var keyword: String? = nil
  var category: String? = nil
  var limit: Int = 100
  var page: Int = 1
  var pageSize: Int = 25
}

struct RssTestResponse: Codable {
  var ok: Bool
  var message: String
  var site: String
  var url: String?
  var count: Int
  var page: Int
  var pageSize: Int
  var totalPages: Int
  var hasPrevious: Bool
  var hasNext: Bool
  var elapsedMs: Int?
  var categories: [String]
  var results: [SearchResult]
  var warnings: [String]
  var diagnostics: SearchDiagnostics
}

struct RefreshAllResponse: Codable {
  var refreshed: Int
  var responses: [RefreshResponse]
  var warnings: [String]
  var skipped: Int? = nil
}

struct SchedulerStartRequest: Codable {
  var intervalSeconds: Int
}

struct SchedulerStatus: Codable, Hashable {
  var running: Bool
  var intervalSeconds: Int
  var lastRunAt: String?
  var lastError: String?
  var nextRunAt: String?
  var lastSuccessAt: String?
  var lastErrorAt: String?
  var lastErrorMessage: String?
  var currentJobId: String?
  var message: String?
}

struct TaskStateSyncStatus: Codable, Hashable {
  var running: Bool
  var intervalSeconds: Int
  var currentRun: Bool
  var nextRunAt: String?
  var lastStartedAt: String?
  var lastFinishedAt: String?
  var durationMs: Double?
  var historyUpdatedCount: Int?
  var brushUpdatedCount: Int?
  var organizedCount: Int?
  var brushCleanedCount: Int?
  var skippedOverlapCount: Int
  var lastError: String?
}

struct AutomationStatus: Codable, Hashable {
  var backendRunning: Bool
  var schedulerRunning: Bool
  var autoRefreshEnabled: Bool
  var autoRefreshIntervalSeconds: Int
  var autoDownloadEnabled: Bool
  var autoOrganizeEnabled: Bool
  var notificationsEnabled: Bool
  var lastRunAt: String?
  var nextRunAt: String?
  var lastSuccessAt: String?
  var lastErrorAt: String?
  var lastErrorMessage: String?
  var currentJobId: String?
  var message: String
}

struct AutomationSettingsRequest: Codable {
  var autoRefreshEnabled: Bool
  var autoRefreshIntervalSeconds: Int
  var autoDownloadEnabled: Bool = true
  var autoOrganizeEnabled: Bool = true
  var notificationsEnabled: Bool = true
}

struct OKResponse: Codable {
  var ok: Bool
  var message: String?
}

struct DownloadHistory: Codable, Identifiable, Hashable {
  var id: Int
  var fingerprint: String
  var title: String
  var source: String
  var downloadUrl: String?
  var qbittorrentHash: String?
  var downloaderType: String
  var remoteTaskId: String?
  var torrentName: String?
  var savePath: String?
  var subscriptionId: Int?
  var status: String
  var organizeStatus: String
  var taskStatus: String
  var derivedStatus: String?
  var derivedStatusDetail: String?
  var organizeAvailable: Bool?
  var organizeBlockReason: String?
  var resourceType: String?
  var displayEpisodeLabel: String?
  var episodeStart: Int?
  var episodeEnd: Int?
  var absoluteEpisodeStart: String?
  var absoluteEpisodeEnd: String?
  var seasonEpisodeStart: Int?
  var seasonEpisodeEnd: Int?
  var isBatch: Bool?
  var isMultiEpisode: Bool?
  var createdAt: String
  var qbittorrent: QbittorrentTaskProgress?
}

struct QbittorrentTaskProgress: Codable, Hashable {
  var downloadRecordId: Int?
  var subscriptionId: Int?
  var episodeNumber: Int?
  var matched: Bool
  var matchConfidence: Double?
  var matchReason: String?
  var hash: String?
  var name: String?
  var state: String?
  var stateLabel: String?
  var progress: Double?
  var progressPercent: Double?
  var downloaded: Int?
  var totalSize: Int?
  var downloadSpeed: Int?
  var uploadSpeed: Int?
  var eta: Int?
  var ratio: Double?
  var seedingTime: Int?
  var numSeeds: Int?
  var numComplete: Int?
  var numIncomplete: Int?
  var numLeechs: Int?
  var lastSeenAt: String?
  var seedingStopCondition: String?
  var postSeedingAction: String?
  var seedingTargetSeconds: Int?
  var seedingRemainingSeconds: Int?
  var seedingTargetRatio: Double?
  var seedingTargetReached: Bool?
  var seedingStopMode: String?
  var message: String
}

struct DownloadHistoryManageRequest: Codable {
  var action: String
}

struct DownloadHistoryManageResponse: Codable {
  var ok: Bool
  var historyId: Int
  var action: String
  var status: String
  var message: String
  var commandSent: Bool?
  var taskFound: Bool?
  var beforeState: String?
  var afterState: String?
  var needsRefresh: Bool?
}

struct HistoryClearRequest: Codable {
  var scope: String
  var subscriptionId: Int?
  var deleteQbittorrentTasks: Bool
  var deleteFiles: Bool
  var confirm: Bool
}

struct HistoryClearResponse: Codable {
  var ok: Bool
  var scope: String
  var message: String
  var downloadHistoryDeleted: Int
  var subscriptionMatchesDeleted: Int
  var subscriptionRefreshesDeleted: Int
  var organizePreviewsDeleted: Int
  var organizeHistoryDeleted: Int
  var metadataBindingsDeleted: Int
  var qbittorrentTasksDeleted: Int
  var warnings: [String]
}

struct ResetSubscriptionRequest: Codable {
  var confirm: Bool
}

struct SubscriptionHistoryClearRequest: Codable {
  var scope: String
  var confirm: Bool
}

struct OrganizeHistoryClearRequest: Codable {
  var confirm: Bool
}

struct OrganizeFailedHistoryDeleteRequest: Codable {
  var confirm: Bool
  var subscriptionId: Int?
}

struct OrganizeFailedHistorySummary: Codable {
  var subscriptionId: Int?
  var failedCount: Int
}

struct OrganizeFailedHistoryDeleteResponse: Codable {
  var ok: Bool
  var deletedCount: Int
  var scope: String
  var message: String
}

struct OrganizeTargetCreate: Codable {
  var name: String
  var path: String
  var mediaType: String
  var isDefault: Bool
  var enabled: Bool
}

struct OrganizeTarget: Codable, Identifiable, Hashable {
  var id: Int
  var name: String
  var path: String
  var mediaType: String
  var isDefault: Bool
  var enabled: Bool
  var createdAt: String
  var updatedAt: String?
}

struct OrganizeTargetPreview: Codable, Hashable {
  var targetName: String?
  var rootPath: String?
  var showDirectory: String?
  var seasonDirectory: String?
  var showPath: String?
  var seasonPath: String?
  var message: String?
}

struct OrganizeTargetValidateResponse: Codable {
  var ok: Bool
  var targetId: Int
  var message: String
  var pathExists: Bool
  var isDirectory: Bool
  var isAbsolute: Bool
}

struct ResetSubscriptionResponse: Codable {
  var ok: Bool
  var subscriptionId: Int
  var message: String
  var downloadHistoryDeleted: Int
  var subscriptionMatchesDeleted: Int
  var subscriptionRefreshesDeleted: Int
  var organizePreviewsDeleted: Int
  var organizeHistoryDeleted: Int
  var metadataBindingsDeleted: Int
  var plexMappingsDeleted: Int?
}

struct SubscriptionRefreshHistory: Codable, Identifiable, Hashable {
  var id: Int
  var subscriptionId: Int
  var matchedCount: Int
  var addedCount: Int
  var skippedCount: Int
  var errorCount: Int
  var warnings: [String]
  var logs: [String]
  var errors: [String]
  var summary: String?
  var createdAt: String
}

struct SubscriptionMatch: Codable, Identifiable, Hashable {
  var id: Int
  var subscriptionId: Int
  var fingerprint: String
  var result: SearchResult
  var parsedTitle: ParsedAnimeTitle
  var status: String
  var firstSeenAt: String
  var lastSeenAt: String
  var logicalEpisodeStart: Int?
  var logicalEpisodeEnd: Int?
  var episodeOffsetApplied: Int?
  var episodeMappingLabel: String?

  var stableDisplayID: String {
    let resourceKey = [
      result.id,
      result.downloadUrl,
      result.magnetUrl,
      result.detailUrl,
      result.sourceUrl,
      result.title
    ]
    .compactMap { value in
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }
    .first ?? "unknown"
    return "\(subscriptionId)-\(id)-\(fingerprint)-\(resourceKey)"
  }

  var displaySourceID: String {
    let source = result.source.trimmingCharacters(in: .whitespacesAndNewlines)
    return source.isEmpty ? "rss" : source
  }

  var displaySize: String {
    let value = result.size?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value! : "大小未知"
  }

  var displayPublishedAt: String {
    let value = result.publishedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value! : "发布时间未知"
  }

  var displayEpisodeLabel: String {
    if let label = parsedTitle.displayEpisodeLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
      return label
    }
    if let episode = parsedTitle.episode {
      if parsedTitle.isBatch == true, let end = parsedTitle.episodeEnd {
        return "E\(episode)-E\(end)"
      }
      return "E\(episode)"
    }
    if let episode = parsedTitle.episodeNumber {
      return "E\(episode)"
    }
    return "集数未识别"
  }
}

struct SubscriptionEpisodeStatus: Codable, Identifiable, Hashable {
  var id: Int { matchId }
  var matchId: Int
  var downloadHistoryId: Int?
  var title: String
  var source: String
  var episode: Int?
  var season: Int?
  var resolution: String?
  var matchStatus: String
  var downloadStatus: String
  var completionStatus: String
  var qbittorrent: QbittorrentTaskProgress?
  var organizePreviewStatus: String
  var derivedStatus: String?
  var derivedStatusDetail: String?
  var lastSeenAt: String
}

struct SubscriptionEpisodeResource: Codable, Identifiable, Hashable {
  var id: Int { matchId }
  var matchId: Int
  var rawTitle: String
  var site: String
  var fansubGroup: String?
  var resolution: String?
  var resourceType: String?
  var displayEpisodeLabel: String?
  var episodeStart: Int?
  var episodeEnd: Int?
  var absoluteEpisodeStart: String?
  var absoluteEpisodeEnd: String?
  var seasonEpisodeStart: Int?
  var seasonEpisodeEnd: Int?
  var logicalEpisodeStart: Int?
  var logicalEpisodeEnd: Int?
  var episodeOffsetApplied: Int?
  var episodeMappingLabel: String?
  var isBatch: Bool?
  var isMultiEpisode: Bool?
  var size: String?
  var publishTime: String?
  var downloadLink: String?
  var magnet: String?
  var torrentHash: String?
  var downloadRecordId: Int?
  var matchScore: Double?
  var status: String
  var downloadStatus: String
  var organizeStatus: String
  var qbittorrent: QbittorrentTaskProgress?
  var derivedStatus: String?
  var derivedStatusDetail: String?
}

struct SubscriptionLogicalEpisodeStatus: Codable, Identifiable, Hashable {
  var id: String { "\(seasonNumber)-\(episodeNumber)" }
  var seasonNumber: Int
  var episodeNumber: Int
  var episodeTitle: String?
  var displayTitle: String
  var metadataSource: String
  var matchedResources: [SubscriptionEpisodeResource]
  var downloadStatus: String
  var organizeStatus: String
  var autoOrganizeStatus: String
  var derivedStatus: String?
  var derivedStatusDetail: String?
  var organizeAvailable: Bool
  var excludedByEpisodeStart: Bool?
  var selected: Bool
  var lastMatchedAt: String?
}

enum SubscriptionEpisodeScopePresentation {
  static func isExcluded(_ episode: SubscriptionLogicalEpisodeStatus) -> Bool {
    episode.excludedByEpisodeStart == true
  }

  static func isSelectable(_ episode: SubscriptionLogicalEpisodeStatus) -> Bool {
    !isExcluded(episode) && episode.organizeAvailable
  }

  static func accessibilityLabel(for episode: SubscriptionLogicalEpisodeStatus) -> String {
    if isExcluded(episode) {
      return "第 \(episode.episodeNumber) 集，起始集数前，已跳过"
    }
    let status = episode.derivedStatus?.isEmpty == false ? episode.derivedStatus! : episode.downloadStatus
    return "第 \(episode.episodeNumber) 集，\(status)"
  }

  static func summary(
    coverage: SubscriptionCoverageSummary?,
    episodes: [SubscriptionLogicalEpisodeStatus]
  ) -> String {
    let skipped = coverage?.skippedBeforeStart ?? episodes.filter(isExcluded).count
    if let catalogTotal = coverage?.catalogTotalEpisodes {
      let targetTotal = coverage?.targetTotalEpisodes ?? coverage?.totalEpisodes ?? 0
      var parts = ["总 \(catalogTotal) 集"]
      parts.append(targetTotal == 0 ? "暂无需处理" : "需处理 \(targetTotal) 集")
      if skipped > 0 {
        parts.append("起始前 \(skipped) 集")
      }
      return parts.joined(separator: " · ")
    }

    let listedTargetCount = episodes.filter { !isExcluded($0) }.count
    var parts = ["总数待识别", "已列出 \(listedTargetCount) 集"]
    if skipped > 0 {
      parts.append("起始前 \(skipped) 集")
    }
    return parts.joined(separator: " · ")
  }
}

struct SubscriptionHierarchyEpisode: Codable, Identifiable, Hashable {
  var id: Int { matchId }
  var matchId: Int
  var downloadHistoryId: Int?
  var title: String
  var source: String
  var episodeNumber: Int?
  var resolution: String?
  var downloadStatus: String
  var qbittorrent: QbittorrentTaskProgress?
  var organizeStatus: String
  var derivedStatus: String?
  var derivedStatusDetail: String?
  var downloaded: Bool
  var organized: Bool
}

struct SubscriptionHierarchySeason: Codable, Identifiable, Hashable {
  var id: Int { seasonNumber }
  var seasonNumber: Int
  var title: String
  var episodes: [SubscriptionHierarchyEpisode]
}

struct SubscriptionMetadataHierarchy: Codable, Identifiable, Hashable {
  var id: String { "\(source):\(externalId ?? title)" }
  var source: String
  var sourceLabel: String
  var externalId: String?
  var title: String
  var originalTitle: String?
  var chineseTitle: String?
  var aliases: [String]
  var subtitle: String?
  var summary: String?
  var posterUrl: String?
  var backdropUrl: String?
  var posterLocalUrl: String?
  var posterPalette: PosterPalette?
  var airDate: String?
  var totalEpisodes: Int?
  var episodeTitles: [String: String] = [:]
  var rating: Double?
  var tags: [String]
  var seasonNumber: Int?
  var episodeCount: Int?
  var externalIds: [String: String]
  var seasons: [SubscriptionHierarchySeason]

  enum CodingKeys: String, CodingKey {
    case source
    case sourceLabel
    case externalId
    case title
    case originalTitle
    case chineseTitle
    case aliases
    case subtitle
    case summary
    case posterUrl
    case backdropUrl
    case posterLocalUrl
    case posterPalette
    case airDate
    case totalEpisodes
    case episodeTitles
    case rating
    case tags
    case seasonNumber
    case episodeCount
    case externalIds
    case seasons
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    source = try container.decode(String.self, forKey: .source)
    sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
    externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
    title = try container.decode(String.self, forKey: .title)
    originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
    chineseTitle = try container.decodeIfPresent(String.self, forKey: .chineseTitle)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
    backdropUrl = try container.decodeIfPresent(String.self, forKey: .backdropUrl)
    posterLocalUrl = try container.decodeIfPresent(String.self, forKey: .posterLocalUrl)
    posterPalette = try container.decodeIfPresent(PosterPalette.self, forKey: .posterPalette)
    airDate = try container.decodeIfPresent(String.self, forKey: .airDate)
    totalEpisodes = try container.decodeIfPresent(Int.self, forKey: .totalEpisodes)
    episodeTitles = try container.decodeIfPresent([String: String].self, forKey: .episodeTitles) ?? [:]
    rating = try container.decodeIfPresent(Double.self, forKey: .rating)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
    episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount)
    externalIds = try container.decodeIfPresent([String: String].self, forKey: .externalIds) ?? [:]
    seasons = try container.decodeIfPresent([SubscriptionHierarchySeason].self, forKey: .seasons) ?? []
  }
}

struct SubscriptionDetail: Codable {
  var subscription: Subscription
  var organizeTarget: OrganizeTarget?
  var organizeTargetPreview: OrganizeTargetPreview?
  var matches: [SubscriptionMatch]
  var history: [DownloadHistory]
  var refreshHistory: [SubscriptionRefreshHistory]
  var metadataBindings: [MetadataBindingRecord]
  var metadataHierarchy: [SubscriptionMetadataHierarchy]
  var plexMappings: [PlexMappingRecord]
  var episodes: [SubscriptionEpisodeStatus]
  var episodeStatuses: [SubscriptionLogicalEpisodeStatus]
  var unmatchedResources: [SubscriptionEpisodeResource]
  var autoOrganizeStatus: String
  var matchedCount: Int
  var queuedCount: Int
  var skippedCount: Int
  var errorCount: Int
  var latestRefreshAt: String?
  var latestRefreshSummary: String?
  var latestOrganizedAt: String?
  var latestError: String?
  var coverage: SubscriptionCoverageSummary?

  enum CodingKeys: String, CodingKey {
    case subscription
    case organizeTarget
    case organizeTargetPreview
    case matches
    case history
    case refreshHistory
    case metadataBindings
    case metadataHierarchy
    case plexMappings
    case episodes
    case episodeStatuses
    case unmatchedResources
    case autoOrganizeStatus
    case matchedCount
    case queuedCount
    case skippedCount
    case errorCount
    case latestRefreshAt
    case latestRefreshSummary
    case latestOrganizedAt
    case latestError
    case coverage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subscription = try container.decode(Subscription.self, forKey: .subscription)
    organizeTarget = try container.decodeIfPresent(OrganizeTarget.self, forKey: .organizeTarget)
    organizeTargetPreview = try container.decodeIfPresent(OrganizeTargetPreview.self, forKey: .organizeTargetPreview)
    matches = try container.decodeIfPresent([SubscriptionMatch].self, forKey: .matches) ?? []
    history = try container.decodeIfPresent([DownloadHistory].self, forKey: .history) ?? []
    refreshHistory = try container.decodeIfPresent([SubscriptionRefreshHistory].self, forKey: .refreshHistory) ?? []
    metadataBindings = try container.decodeIfPresent([MetadataBindingRecord].self, forKey: .metadataBindings) ?? []
    metadataHierarchy = try container.decodeIfPresent([SubscriptionMetadataHierarchy].self, forKey: .metadataHierarchy) ?? []
    plexMappings = try container.decodeIfPresent([PlexMappingRecord].self, forKey: .plexMappings) ?? []
    episodes = try container.decodeIfPresent([SubscriptionEpisodeStatus].self, forKey: .episodes) ?? []
    episodeStatuses = try container.decodeIfPresent([SubscriptionLogicalEpisodeStatus].self, forKey: .episodeStatuses) ?? []
    unmatchedResources = try container.decodeIfPresent([SubscriptionEpisodeResource].self, forKey: .unmatchedResources) ?? []
    autoOrganizeStatus = try container.decodeIfPresent(String.self, forKey: .autoOrganizeStatus) ?? "未开启"
    matchedCount = try container.decodeIfPresent(Int.self, forKey: .matchedCount) ?? matches.count
    queuedCount = try container.decodeIfPresent(Int.self, forKey: .queuedCount) ?? matches.filter { $0.status == "queued" }.count
    skippedCount = try container.decodeIfPresent(Int.self, forKey: .skippedCount) ?? matches.filter { $0.status == "skipped" }.count
    errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount) ?? matches.filter { $0.status == "error" }.count
    latestRefreshAt = try container.decodeIfPresent(String.self, forKey: .latestRefreshAt)
    latestRefreshSummary = try container.decodeIfPresent(String.self, forKey: .latestRefreshSummary)
    latestOrganizedAt = try container.decodeIfPresent(String.self, forKey: .latestOrganizedAt)
    latestError = try container.decodeIfPresent(String.self, forKey: .latestError)
    coverage = try container.decodeIfPresent(SubscriptionCoverageSummary.self, forKey: .coverage)
  }
}

struct MetadataSearchRequest: Codable {
  var query: String
  var year: Int?
  var mediaType: String
  var sources: [String]
}

struct MetadataMatchRequest: Codable {
  var title: String
  var year: Int?
  var downloadRecordId: Int? = nil
  var mediaType: String? = nil
}

struct MetadataSearchResponse: Codable {
  var candidates: [MetadataCandidate]
  var warnings: [String]
  var parsedTitle: ParsedAnimeTitle?
  var recommendedCandidateId: String?
  var suggestedMapping: PlexSeasonMapping?
  var mergeSummary: String?
}

struct MetadataCandidate: Codable, Identifiable, Hashable {
  var source: String
  var externalId: String
  var title: String
  var originalTitle: String?
  var chineseTitle: String?
  var aliases: [String]
  var summary: String?
  var posterUrl: String?
  var backdropUrl: String?
  var airDate: String?
  var totalEpisodes: Int?
  var episodeTitles: [String: String] = [:]
  var rating: Double?
  var tags: [String]
  var seasonNumber: Int?
  var episodeCount: Int?
  var externalIds: [String: String]
  var matchScore: Double?
  var matchReason: [String]
  var mediaType: String? = nil

  var id: String {
    source == "tmdb" && mediaType == "movie" ? "tmdb:movie:\(externalId)" : "\(source):\(externalId)"
  }

  enum CodingKeys: String, CodingKey {
    case source
    case externalId
    case title
    case originalTitle
    case chineseTitle
    case aliases
    case summary
    case posterUrl
    case backdropUrl
    case airDate
    case totalEpisodes
    case episodeTitles
    case rating
    case tags
    case seasonNumber
    case episodeCount
    case externalIds
    case matchScore
    case matchReason
    case mediaType
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    source = try container.decode(String.self, forKey: .source)
    externalId = try container.decode(String.self, forKey: .externalId)
    title = try container.decode(String.self, forKey: .title)
    originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
    chineseTitle = try container.decodeIfPresent(String.self, forKey: .chineseTitle)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
    backdropUrl = try container.decodeIfPresent(String.self, forKey: .backdropUrl)
    airDate = try container.decodeIfPresent(String.self, forKey: .airDate)
    totalEpisodes = try container.decodeIfPresent(Int.self, forKey: .totalEpisodes)
    episodeTitles = try container.decodeIfPresent([String: String].self, forKey: .episodeTitles) ?? [:]
    rating = try container.decodeIfPresent(Double.self, forKey: .rating)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
    episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount)
    externalIds = try container.decodeIfPresent([String: String].self, forKey: .externalIds) ?? [:]
    matchScore = try container.decodeIfPresent(Double.self, forKey: .matchScore)
    matchReason = try container.decodeIfPresent([String].self, forKey: .matchReason) ?? []
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
  }
}

struct MetadataBindRequest: Codable {
  var targetType: String
  var targetId: String
  var bangumiId: String?
  var tmdbId: String?
  var selectedTitle: String?
  var originalTitle: String?
  var chineseTitle: String? = nil
  var aliases: [String] = []
  var summary: String?
  var posterUrl: String?
  var backdropUrl: String? = nil
  var posterLocalUrl: String? = nil
  var localPosterPath: String? = nil
  var posterCachedAt: String? = nil
  var airDate: String?
  var totalEpisodes: Int?
  var episodeTitles: [String: String] = [:]
  var rating: Double?
  var tags: [String]
  var seasonNumber: Int? = nil
  var episodeCount: Int? = nil
  var externalIds: [String: String] = [:]
  var notes: String?
  var mediaType: String? = nil

  init(
    candidate: MetadataCandidate,
    targetType: String,
    targetId: String,
    selectedTitle: String? = nil,
    originalTitle: String? = nil,
    notes: String? = nil
  ) {
    self.targetType = targetType
    self.targetId = targetId
    bangumiId = candidate.source == "bangumi" ? candidate.externalId : nil
    tmdbId = candidate.source == "tmdb" ? candidate.externalId : nil
    self.selectedTitle = selectedTitle ?? candidate.title
    self.originalTitle = originalTitle ?? candidate.originalTitle
    chineseTitle = candidate.chineseTitle
    aliases = candidate.aliases
    summary = candidate.summary
    posterUrl = candidate.posterUrl
    backdropUrl = candidate.backdropUrl
    airDate = candidate.airDate
    totalEpisodes = candidate.totalEpisodes
    episodeTitles = candidate.episodeTitles
    rating = candidate.rating
    tags = candidate.tags
    seasonNumber = candidate.seasonNumber
    episodeCount = candidate.episodeCount
    externalIds = candidate.externalIds
    self.notes = notes
    mediaType = candidate.mediaType
  }
}

struct MetadataBindResponse: Codable {
  var ok: Bool
  var bindingId: Int
}

struct MetadataBindingRecord: Codable, Identifiable, Hashable {
  var id: Int
  var targetType: String
  var targetId: String
  var bangumiId: String?
  var tmdbId: String?
  var selectedTitle: String?
  var originalTitle: String?
  var chineseTitle: String?
  var aliases: [String]
  var summary: String?
  var posterUrl: String?
  var backdropUrl: String?
  var posterLocalUrl: String?
  var localPosterPath: String?
  var posterCachedAt: String?
  var airDate: String?
  var totalEpisodes: Int?
  var episodeTitles: [String: String] = [:]
  var rating: Double?
  var tags: [String]
  var seasonNumber: Int?
  var episodeCount: Int?
  var externalIds: [String: String]
  var notes: String?
  var createdAt: String
  var mediaType: String? = nil

  enum CodingKeys: String, CodingKey {
    case id
    case targetType
    case targetId
    case bangumiId
    case tmdbId
    case selectedTitle
    case originalTitle
    case chineseTitle
    case aliases
    case summary
    case posterUrl
    case backdropUrl
    case posterLocalUrl
    case localPosterPath
    case posterCachedAt
    case airDate
    case totalEpisodes
    case episodeTitles
    case rating
    case tags
    case seasonNumber
    case episodeCount
    case externalIds
    case notes
    case createdAt
    case mediaType
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    targetType = try container.decode(String.self, forKey: .targetType)
    targetId = try container.decode(String.self, forKey: .targetId)
    bangumiId = try container.decodeIfPresent(String.self, forKey: .bangumiId)
    tmdbId = try container.decodeIfPresent(String.self, forKey: .tmdbId)
    selectedTitle = try container.decodeIfPresent(String.self, forKey: .selectedTitle)
    originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
    chineseTitle = try container.decodeIfPresent(String.self, forKey: .chineseTitle)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
    backdropUrl = try container.decodeIfPresent(String.self, forKey: .backdropUrl)
    posterLocalUrl = try container.decodeIfPresent(String.self, forKey: .posterLocalUrl)
    localPosterPath = try container.decodeIfPresent(String.self, forKey: .localPosterPath)
    posterCachedAt = try container.decodeIfPresent(String.self, forKey: .posterCachedAt)
    airDate = try container.decodeIfPresent(String.self, forKey: .airDate)
    totalEpisodes = try container.decodeIfPresent(Int.self, forKey: .totalEpisodes)
    episodeTitles = try container.decodeIfPresent([String: String].self, forKey: .episodeTitles) ?? [:]
    rating = try container.decodeIfPresent(Double.self, forKey: .rating)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
    episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount)
    externalIds = try container.decodeIfPresent([String: String].self, forKey: .externalIds) ?? [:]
    notes = try container.decodeIfPresent(String.self, forKey: .notes)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
  }
}

struct ParsedAnimeTitle: Codable, Hashable {
  var originalTitle: String
  var title: String? = nil
  var episode: Int? = nil
  var episodeNumber: Int? = nil
  var episodeStart: Int? = nil
  var episodeEnd: Int? = nil
  var isBatch: Bool? = nil
  var isMultiEpisode: Bool? = nil
  var isFinal: Bool? = nil
  var isSpecial: Bool? = nil
  var resourceType: String? = nil
  var displayEpisodeLabel: String? = nil
  var parseRuleName: String? = nil
  var parseReason: String? = nil
  var parseConfidence: Double? = nil
  var parseFailureReason: String? = nil
  var season: Int? = nil
  var seasonNumber: Int? = nil
  var explicitSeasonNumber: Int? = nil
  var inferredSeasonNumber: Int? = nil
  var contextSeasonNumber: Int? = nil
  var effectiveSeasonNumber: Int? = nil
  var seasonSource: String? = nil
  var seasonConflict: Bool? = nil
  var seasonConflictReason: String? = nil
  var partNumber: Int? = nil
  var absoluteEpisodeNumber: Int? = nil
  var absoluteEpisodeStart: String? = nil
  var absoluteEpisodeEnd: String? = nil
  var absoluteEpisodeStartSort: Double? = nil
  var absoluteEpisodeEndSort: Double? = nil
  var seasonEpisodeStart: Int? = nil
  var seasonEpisodeEnd: Int? = nil
  var logicalEpisodeStart: Int? = nil
  var logicalEpisodeEnd: Int? = nil
  var episodeOffsetApplied: Int? = nil
  var episodeMappingLabel: String? = nil
  var batchTitle: String? = nil
  var fansub: String? = nil
  var resolution: String? = nil
  var subtitleLanguage: String? = nil
  var version: String? = nil
  var fileSize: String? = nil
  var confidence: Double = 0
  var needsConfirmation: Bool = true
}

struct TitleParseRequest: Codable {
  var title: String
  var episodeParseRules: [EpisodeParseRule] = []
}

struct EpisodeRuleTestCase: Codable, Hashable, Identifiable {
  var id: String { "\(expectedMatch)-\(title)" }
  var title: String
  var expectedMatch: Bool
}

struct EpisodeRuleTestItem: Codable, Hashable, Identifiable {
  var id: String { "\(expectedMatch)-\(title)" }
  var title: String
  var expectedMatch: Bool
  var matched: Bool
  var passed: Bool
  var parsedTitle: ParsedAnimeTitle
  var message: String
}

struct EpisodeRuleTestRequest: Codable {
  var title: String
  var episodeParseRules: [EpisodeParseRule]
  var tests: [EpisodeRuleTestCase] = []
}

struct EpisodeRuleTestResponse: Codable, Hashable {
  var ok: Bool
  var parsedTitle: ParsedAnimeTitle
  var message: String
  var results: [EpisodeRuleTestItem] = []
}

struct PlexSeasonMapping: Codable, Hashable {
  var subjectKey: String
  var showName: String
  var showYear: Int?
  var seasonNumber: Int
  var episodeOffset: Int
  var specialEpisodeNumbers: [String: Int]
}

struct PlexMappingResponse: Codable {
  var ok: Bool
  var mappingId: Int
}

struct PlexMappingRecord: Codable, Identifiable {
  var id: Int
  var mapping: PlexSeasonMapping
  var createdAt: String
  var updatedAt: String?
}

struct OrganizePreviewRequest: Codable {
  var sourcePath: String
  var downloadRecordId: Int?
  var libraryRoot: String
  var organizeTargetId: Int?
  var originalFilename: String
  var parsedTitle: ParsedAnimeTitle?
  var mapping: PlexSeasonMapping
  var episodeTitle: String?
  var isSpecial: Bool
  var singleFileMode: String? = nil
  var fileMappingOverrides: [OrganizePreviewFileOverride] = []
  var mediaType: String? = nil
  var selectFiles: Bool? = nil
}

struct OrganizePreviewFileOverride: Codable, Hashable {
  var id: String
  var seasonNumber: Int
  var episodeNumber: Int?
  var isSpecial: Bool
  var skipped: Bool
}

struct OrganizePreviewItem: Codable, Hashable {
  var previewId: Int?
  var downloadRecordId: Int?
  var organizeTargetId: Int? = nil
  var sourcePath: String
  var libraryRoot: String
  var showDirectory: String
  var seasonDirectory: String
  var filename: String
  var destinationPreview: String
  var willMove: Bool
  var canApply: Bool?
  var blockReason: String?
  var warnings: [String]
  var isBatch: Bool?
  var batchMode: String?
  var singleFileMode: String?
  var episodeStart: Int?
  var episodeEnd: Int?
  var fileMappings: [OrganizePreviewFileMapping]?
  var subtitleMappings: [OrganizeSubtitleMapping]?
  var mediaType: String? = nil
}

struct OrganizeSubtitleMapping: Codable, Hashable {
  var sourcePath: String
  var originalFilename: String
  var targetFilename: String
  var targetPath: String
  var languageSuffix: String
  var `extension`: String
  var status: String
  var message: String
}

struct OrganizePreviewFileMapping: Codable, Identifiable, Hashable {
  var id: String
  var sourcePath: String
  var originalFilename: String
  var parsedEpisode: Int?
  var seasonNumber: Int
  var episodeNumber: Int?
  var isSpecial: Bool
  var targetFilename: String
  var targetPath: String
  var status: String
  var message: String
  var manualOverride: Bool
  var overrideReason: String?
  var warnings: [String]
  var subtitleMappings: [OrganizeSubtitleMapping]?
}

struct OrganizePreviewRecord: Codable, Identifiable {
  var id: Int
  var request: OrganizePreviewRequest
  var preview: OrganizePreviewItem
  var createdAt: String
  var remainingSourcePaths: [String]? = nil
}

struct OrganizeHistoryRecord: Codable, Identifiable {
  var id: Int
  var sourcePath: String
  var destinationPath: String
  var status: String
  var message: String
  var preview: OrganizePreviewItem
  var qbittorrentTaskDeleted: Bool
  var deleteFilesFromQbittorrent: Bool
  var cleanupAttempted: Bool
  var cleanupStatus: String?
  var cleanupPath: String?
  var cleanupMessage: String?
  var subscriptionId: Int?
  var subscriptionSeason: Int?
  var resourceExplicitSeason: Int?
  var effectiveSeason: Int?
  var seasonSource: String?
  var manualOverride: Bool?
  var overrideReason: String?
  var createdAt: String
}

struct OrganizeApplyRequest: Codable {
  var preview: OrganizePreviewItem
  var confirmRealMove: Bool
}

struct OrganizeApplyResponse: Codable {
  var ok: Bool
  var status: String
  var message: String
  var sourcePath: String
  var destinationPath: String
  var historyId: Int
  var subtitleMappings: [OrganizeSubtitleMapping]?
}

struct SubscriptionOrganizeRequest: Codable {
  var episodeNumbers: [Int]
  var matchIds: [Int]
  var organizeTargetId: Int?
  var deleteQbittorrentTaskAfterSuccess: Bool?
  var deleteFilesFromQbittorrent: Bool?
  var keepSeeding: Bool?
  var dryRun: Bool
  var confirm: Bool
  var manualOverride: Bool?
  var overrideReason: String?
}

struct SubscriptionOrganizeEpisodeResult: Codable, Identifiable, Hashable {
  var id: String { "\(matchId ?? -1)-\(episodeNumber ?? -1)-\(destinationPath ?? title)" }
  var episodeNumber: Int?
  var matchId: Int?
  var title: String
  var status: String
  var message: String
  var sourcePath: String?
  var destinationPath: String?
  var historyId: Int?
  var qbittorrentTaskDeleted: Bool
  var deleteFilesFromQbittorrent: Bool
  var cleanupAttempted: Bool
  var cleanupStatus: String?
  var cleanupPath: String?
  var cleanupMessage: String?
  var subtitleMappings: [OrganizeSubtitleMapping]?
}

struct SubscriptionOrganizeResponse: Codable {
  var ok: Bool
  var subscriptionId: Int
  var message: String
  var organized: Int
  var skipped: Int
  var failed: Int
  var dryRun: Bool
  var target: OrganizeTarget?
  var results: [SubscriptionOrganizeEpisodeResult]
  var warnings: [String]
}

struct BrushCapabilities: Codable, Hashable, Identifiable {
  var id: String { siteId }
  var siteId: String
  var supportsPromotion: Bool
  var supportsDoubleUpload: Bool
  var supportsSeeders: Bool
  var supportsPagination: Bool
  var missingFields: [String]
}

struct BrushRule: Codable, Hashable {
  var promotionMode: String = "free"
  var promotionModes: [String]? = nil
  var includePattern: String? = nil
  var excludePattern: String? = nil
  var sizeMinGb: Double? = nil
  var sizeMaxGb: Double? = nil
  var seedersMin: Int? = nil
  var seedersMax: Int? = nil
  var publishAgeMinMinutes: Int? = nil
  var publishAgeMaxMinutes: Int? = 120
  var seedTimeHours: Double? = 72
  var seedRatio: Double? = 2
  var uploadedGb: Double? = nil
  var downloadTimeoutHours: Double? = nil
  var minimumAverageUploadKib: Double? = nil
  var inactiveMinutes: Double? = nil

  private enum CodingKeys: String, CodingKey {
    case promotionMode
    case promotionModes
    case includePattern
    case excludePattern
    case sizeMinGb
    case sizeMaxGb
    case seedersMin
    case seedersMax
    case publishAgeMinMinutes
    case publishAgeMaxMinutes
    case seedTimeHours
    case seedRatio
    case uploadedGb
    case downloadTimeoutHours
    case minimumAverageUploadKib
    case inactiveMinutes
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(promotionMode, forKey: .promotionMode)
    try container.encodeIfPresent(promotionModes, forKey: .promotionModes)
    try container.encodeIfPresent(includePattern, forKey: .includePattern)
    try container.encodeIfPresent(excludePattern, forKey: .excludePattern)
    try container.encodeIfPresent(sizeMinGb, forKey: .sizeMinGb)
    try container.encodeIfPresent(sizeMaxGb, forKey: .sizeMaxGb)
    try container.encodeIfPresent(seedersMin, forKey: .seedersMin)
    try container.encodeIfPresent(seedersMax, forKey: .seedersMax)
    try container.encodeIfPresent(publishAgeMinMinutes, forKey: .publishAgeMinMinutes)
    if let publishAgeMaxMinutes {
      try container.encode(publishAgeMaxMinutes, forKey: .publishAgeMaxMinutes)
    } else {
      try container.encodeNil(forKey: .publishAgeMaxMinutes)
    }
    try container.encodeIfPresent(seedTimeHours, forKey: .seedTimeHours)
    try container.encodeIfPresent(seedRatio, forKey: .seedRatio)
    try container.encodeIfPresent(uploadedGb, forKey: .uploadedGb)
    try container.encodeIfPresent(downloadTimeoutHours, forKey: .downloadTimeoutHours)
    try container.encodeIfPresent(minimumAverageUploadKib, forKey: .minimumAverageUploadKib)
    try container.encodeIfPresent(inactiveMinutes, forKey: .inactiveMinutes)
  }

  var effectivePromotionModes: Set<String> {
    if let promotionModes {
      return Set(promotionModes.filter { $0 == "free" || $0 == "2xfree" })
    }
    switch promotionMode {
    case "2xfree": return ["2xfree"]
    case "any": return []
    default: return ["free", "2xfree"]
    }
  }

  var promotionSelectionSummary: String {
    let selected = effectivePromotionModes
    if selected.isEmpty { return "不限制优惠" }
    if selected == ["free"] { return "仅 FREE" }
    if selected == ["2xfree"] { return "仅双倍上传 FREE" }
    return "FREE + 双倍上传 FREE"
  }

  mutating func setPromotionSelection(_ mode: String, enabled: Bool) {
    guard mode == "free" || mode == "2xfree" else { return }
    var selected = effectivePromotionModes
    if enabled {
      selected.insert(mode)
    } else {
      selected.remove(mode)
    }
    applyPromotionSelection(selected)
  }

  mutating func clearPromotionSelection() {
    applyPromotionSelection([])
  }

  private mutating func applyPromotionSelection(_ selected: Set<String>) {
    promotionModes = ["free", "2xfree"].filter(selected.contains)
    if selected.isEmpty {
      promotionMode = "any"
    } else if selected == ["2xfree"] {
      promotionMode = "2xfree"
    } else {
      promotionMode = "free"
    }
  }
}

struct BrushSiteOverride: Codable, Hashable {
  var enabled: Bool = true
  var rule: BrushRule? = nil
  var seedTimeHours: Double? = nil
  var seedRatio: Double? = nil
}

struct BrushGroup: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  var enabled: Bool = true
  var siteIds: [String] = []
  var rule: BrushRule = BrushRule()
  var excludeSubscriptions: Bool = true
  var maxTasks: Int? = nil
  var maxDownloading: Int? = 3
  var maxAdditionsPerRun: Int = 1
  var candidatesPerSite: Int = 50
  var sequentialSites: Bool? = nil
  var automaticCategory: Bool = false
  var firstLastPiecePriority: Bool = false
}

struct BrushSettings: Codable, Hashable {
  var enabled: Bool = false
  var notificationsEnabled: Bool = true
  var selectedSites: [String] = ["mteam", "hddolby", "soulvoice", "opencd"]
  var savePath: String = ""
  var category: String = "Kisetsu刷流"
  var tags: [String] = ["Kisetsu刷流"]
  var brushIntervalMinutes: Int = 10
  var checkIntervalMinutes: Int = 5
  var activeTimeStart: String? = nil
  var activeTimeEnd: String? = nil
  var sequentialSites: Bool = false
  var excludeSubscriptions: Bool = true
  var maxStorageGb: Double? = nil
  var maxTasks: Int? = nil
  var maxDownloading: Int? = 3
  var maxAdditionsPerRun: Int = 1
  var automaticCategory: Bool = false
  var firstLastPiecePriority: Bool = false
  var proxyDownload: Bool = false
  var deleteFilesOnCleanup: Bool = true
  var cleanupExcludedTags: [String] = []
  var dynamicCleanupMinGb: Double? = nil
  var dynamicCleanupMaxGb: Double? = nil
  var archiveAfterDays: Int? = 30
  var candidatesPerSite: Int = 50
  var globalRule: BrushRule = BrushRule()
  var siteOverrides: [String: BrushSiteOverride] = [:]
  var groups: [BrushGroup]? = nil

  var brushGroups: [BrushGroup] {
    get {
      if let groups {
        return groups.map { group in
          var migrated = group
          migrated.sequentialSites = migrated.sequentialSites ?? sequentialSites
          return migrated
        }
      }
      let activeSites = selectedSites.filter { siteOverrides[$0]?.enabled != false }
      return [BrushGroup(
        id: "default",
        name: "默认分组",
        siteIds: activeSites,
        rule: globalRule,
        excludeSubscriptions: excludeSubscriptions,
        maxTasks: maxTasks,
        maxDownloading: maxDownloading,
        maxAdditionsPerRun: maxAdditionsPerRun,
        candidatesPerSite: candidatesPerSite,
        sequentialSites: sequentialSites,
        automaticCategory: automaticCategory,
        firstLastPiecePriority: firstLastPiecePriority
      )]
    }
    set {
      groups = newValue
      selectedSites = newValue.flatMap(\.siteIds)
    }
  }

  mutating func materializeBrushGroups() {
    brushGroups = brushGroups
  }

  func hasSameRuleConfiguration(as other: BrushSettings) -> Bool {
    var current = self
    var comparison = other
    current.enabled = false
    comparison.enabled = false
    return current == comparison
  }

  func preservingRuntimeEnabled(_ runtimeEnabled: Bool) -> BrushSettings {
    var settings = self
    settings.enabled = runtimeEnabled
    return settings
  }
}

struct BrushStats: Codable, Hashable {
  var totalTasks: Int
  var activeTasks: Int
  var downloadingTasks: Int
  var seedingTasks: Int
  var deletedTasks: Int
  var occupiedBytes: Int
  var uploadedBytes: Int
  var downloadedBytes: Int
  var overallRatio: Double
}

struct BrushDownloaderTransfer: Codable, Hashable {
  var downloaderType: String
  var downloaderName: String
  var downloadedBytes: Int?
  var uploadedBytes: Int?
  var overallRatio: Double?
  var fetchedAt: String?
  var available: Bool
  var error: String?
}

struct BrushDeleteCapability: Codable, Hashable {
  var available: Bool
  var platformMode: String?
  var reason: String?
}

struct BrushStatus: Codable, Hashable {
  var enabled: Bool
  var schedulerRunning: Bool
  var currentOperation: String?
  var nextBrushAt: String?
  var nextCheckAt: String?
  var lastBrushAt: String?
  var lastCheckAt: String?
  var lastError: String?
  var message: String
  var stats: BrushStats
  var downloaderTransfer: BrushDownloaderTransfer?
  var transmissionDeleteCapability: BrushDeleteCapability?
}

struct BrushTask: Codable, Hashable, Identifiable {
  var id: Int
  var taskKey: String
  var siteId: String
  var siteName: String
  var groupId: String? = nil
  var groupName: String? = nil
  var resourceId: String
  var title: String
  var subtitle: String?
  var sizeBytes: Int?
  var qbittorrentHash: String?
  var downloaderType: String
  var remoteTaskId: String?
  var uniqueTag: String
  var category: String
  var savePath: String
  var status: String
  var progress: Double
  var downloadSpeed: Int
  var uploadSpeed: Int
  var downloaded: Int
  var uploaded: Int
  var ratio: Double
  var seedingTime: Int
  var addedAt: String
  var completedAt: String?
  var lastActivityAt: String?
  var lastCheckedAt: String?
  var deletedAt: String?
  var cleanupReason: String?
  var errorMessage: String?
  var ruleSnapshot: BrushTaskRuleSnapshot
  var torrentTags: [String]
}

struct BrushTaskRuleSnapshot: Codable, Hashable {
  var groupId: String? = nil
  var groupName: String? = nil
  var rule: BrushRule?
  var reason: String?
}

struct BrushRun: Codable, Hashable, Identifiable {
  var id: Int
  var runType: String
  var status: String
  var startedAt: String
  var finishedAt: String?
  var candidatesCount: Int
  var addedCount: Int
  var checkedCount: Int
  var deletedCount: Int
  var skippedCount: Int
  var errorCount: Int
  var summary: String?
  var details: [String]
  var matchedCount: Int = 0
  var attemptedCount: Int = 0
  var duplicateCount: Int = 0
  var submissionFailedCount: Int = 0
  var rejectionReasons: [String: Int] = [:]
  var siteDiagnostics: [BrushSiteRunDiagnostic] = []
  var trigger: String?
  var addedTasks: [BrushRunTaskSnapshot]
}

struct BrushRunTaskSnapshot: Codable, Hashable, Identifiable {
  var taskId: Int
  var title: String
  var siteId: String
  var siteName: String
  var groupId: String? = nil
  var groupName: String? = nil
  var sizeBytes: Int?
  var promotionLabel: String?
  var downloaderType: String
  var status: String
  var addedAt: String

  var id: Int { taskId }
}

struct BrushSiteRunDiagnostic: Codable, Hashable, Identifiable {
  var groupId: String? = nil
  var groupName: String? = nil
  var siteId: String
  var siteName: String
  var readCount: Int
  var matchedCount: Int
  var attemptedCount: Int
  var addedCount: Int
  var duplicateCount: Int
  var submissionFailedCount: Int
  var rejectionReasons: [String: Int]
  var error: String?

  var id: String { "\(groupId ?? "legacy"):\(siteId)" }
}

enum BrushRuleSettingLocation {
  static func path(forRejectionReason reason: String) -> String? {
    switch reason {
    case "资源发布时间超过规则上限":
      "规则 → 资源筛选 → 发布时间 → 仅获取最近"
    case "资源发布时间过新":
      "规则 → 资源筛选 → 发布时间 → 发布至少经过"
    case "发布时间无法确认":
      "规则 → 资源筛选 → 发布时间"
    default:
      nil
    }
  }
}

struct BrushSiteAccount: Codable, Hashable, Identifiable {
  var siteId: String
  var siteName: String
  var uploadedBytes: Int?
  var downloadedBytes: Int?
  var ratio: Double?
  var fetchedAt: String
  var status: String
  var error: String?

  var id: String { siteId }
}

struct BrushActionRequest: Codable { var action: String }
struct BrushBatchActionRequest: Codable { var taskIds: [Int]; var action: String }
struct BrushActionResponse: Codable {
  var ok: Bool
  var message: String
  var affected: Int
  var platformMode: String?
  var stage: String?
}
struct BrushRunResponse: Codable { var ok: Bool; var message: String; var status: BrushStatus; var run: BrushRun? }
struct BrushClearRequest: Codable { var includeActive: Bool; var confirm: Bool }

struct FileBrowserRootResponse: Codable, Hashable {
  var roots: [FileBrowserRoot]
  var readOnly: Bool
  var message: String
}

struct FileBrowserRoot: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  var path: String
  var kind: String
  var sources: [String]
  var exists: Bool
  var readable: Bool
  var writable: Bool
}

struct FileBrowserDirectoryResponse: Codable, Hashable {
  var rootId: String
  var path: String
  var items: [FileBrowserItem]
  var offset: Int
  var limit: Int
  var total: Int
  var hasMore: Bool
}

struct FileBrowserItem: Codable, Hashable, Identifiable {
  var id: String
  var rootId: String
  var path: String
  var parentPath: String
  var name: String
  var kind: String
  var isDirectory: Bool
  var isSymbolicLink: Bool
  var isHidden: Bool
  var isExpandable: Bool
  var sizeBytes: Int64?
  var modifiedAt: String?
}

struct FileBrowserEditSessionRequest: Codable { var confirm: Bool }
struct FileBrowserEditSession: Codable, Hashable {
  var token: String
  var expiresAt: String
  var message: String
}
struct FileBrowserLockRequest: Codable { var token: String }

struct FileBrowserWriteResponse: Codable, Hashable {
  var ok: Bool
  var message: String
  var item: FileBrowserItem?
}

struct FileBrowserRenameRequest: Codable {
  var editToken: String
  var rootId: String
  var path: String
  var newName: String
}

struct FileBrowserCreateFolderRequest: Codable {
  var editToken: String
  var rootId: String
  var parentPath: String
  var name: String
}

struct FileBrowserReference: Codable, Hashable {
  var rootId: String
  var path: String
}

struct FileBrowserDeletePreviewRequest: Codable {
  var editToken: String
  var sources: [FileBrowserReference]
}

struct FileBrowserDeletePreview: Codable, Hashable, Identifiable {
  var token: String
  var expiresAt: String
  var itemsTotal: Int
  var filesTotal: Int
  var directoriesTotal: Int
  var bytesTotal: Int64
  var itemNames: [String]
  var namesTruncated: Bool
  var message: String

  var id: String { token }
}

struct FileBrowserDeleteRequest: Codable {
  var editToken: String
  var previewToken: String
}

struct FileBrowserOperationRequest: Codable {
  var editToken: String
  var kind: String
  var sources: [FileBrowserReference]
  var destinationRootId: String
  var destinationPath: String
}

struct FileBrowserOperationStatus: Codable, Hashable, Identifiable {
  var id: String
  var kind: String
  var status: String
  var itemsTotal: Int
  var itemsCompleted: Int
  var bytesTotal: Int64?
  var bytesCompleted: Int64
  var currentItem: String?
  var startedAt: String
  var finishedAt: String?
  var message: String
  var errors: [String]
}

struct FileBrowserCancelRequest: Codable { var editToken: String }
