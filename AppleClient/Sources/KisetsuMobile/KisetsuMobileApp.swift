import SwiftUI

#if DEBUG
enum MobileSubscriptionProgressFixture {
  static func snapshots(for subscription: Subscription) -> [Subscription] {
    guard let metrics = SubscriptionTargetProgressPresentation(subscription: subscription).metrics else { return [] }
    return [1, max(metrics.total / 3, 1), metrics.total].map { increment in
      var snapshot = subscription
      let downloaded = min(metrics.total, max(metrics.downloaded, 0) + increment)
      let organized = min(downloaded, max(metrics.organized, 0) + increment / 2)
      snapshot.downloadedCount = downloaded
      snapshot.organizedCount = organized
      snapshot.coverage?.downloadedCount = downloaded
      snapshot.coverage?.organizedCount = organized
      return snapshot
    }
  }
}

enum MobileTaskManagementFixture {
  enum Failure: LocalizedError {
    case rejected
    var errorDescription: String? { "脱敏任务未改变，可以重试。" }
  }

  static func perform(
    _ item: DownloadHistory, action: MobileHistoryManagementAction,
    fails: Bool = false, latency: Duration = .zero
  ) async throws -> DownloadHistory {
    if latency > .zero { try await Task.sleep(for: latency) }
    try Task.checkCancellation()
    if fails { throw Failure.rejected }
    var updated = item
    updated.status = action == .pause ? "paused" : "downloading"
    updated.derivedStatus = action == .pause ? "已暂停" : "下载中"
    return updated
  }
}

enum MobileFileBrowserFixture {
  static func makeClient(latency: Duration = .zero) -> APIClient {
    APIClient(baseURL: "https://kisetsu-fixture.invalid") { request in
      guard let url = request.url,
            url.host == "kisetsu-fixture.invalid",
            request.httpMethod == "GET",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw URLError(.unsupportedURL)
      }
      if latency > .zero { try await Task.sleep(for: latency) }
      try Task.checkCancellation()
      switch components.path {
      case "/api/files/roots":
        return try response(FileBrowserRootResponse(
          roots: [FileBrowserRoot(
            id: "fixture-media", name: "脱敏媒体库", path: "/fixture/media", kind: "library",
            sources: [], exists: true, readable: true, writable: false
          )], readOnly: true, message: "默认只读，不会修改后端文件。"
        ), url: url)
      case "/api/files/operations":
        return try response([FileBrowserOperationStatus](), url: url)
      case "/api/files/list":
        let query = components.queryItems ?? []
        guard query.first(where: { $0.name == "root_id" })?.value == "fixture-media" else {
          throw URLError(.unsupportedURL)
        }
        let path = query.first(where: { $0.name == "path" })?.value ?? ""
        let offset = max(0, Int(query.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0)
        let items: [FileBrowserItem]
        switch path {
        case "":
          items = [item("Animation", directory: true), item("Empty", directory: true), item("Unavailable", directory: true)]
        case "Animation":
          items = [item("Animation/Season 01", directory: true)]
        case "Animation/Season 01":
          items = (1...3).map { item("Animation/Season 01/Fixture E0\($0).mkv", directory: false) }
        case "Empty":
          items = []
        default:
          return try response(Failure(detail: "模拟目录暂时不可读，请返回上级目录或重试。"), url: url, statusCode: 503)
        }
        let limit = path == "Animation/Season 01" ? 2 : 500
        return try response(FileBrowserDirectoryResponse(
          rootId: "fixture-media", path: path, items: Array(items.dropFirst(offset).prefix(limit)),
          offset: offset, limit: limit, total: items.count, hasMore: offset + limit < items.count
        ), url: url)
      default:
        throw URLError(.unsupportedURL)
      }
    }
  }

  private struct Failure: Encodable { var detail: String }

  private static func response<Value: Encodable>(
    _ value: Value, url: URL, statusCode: Int = 200
  ) throws -> (Data, URLResponse) {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
      throw URLError(.badServerResponse)
    }
    return (try encoder.encode(value), response)
  }

  private static func item(_ path: String, directory: Bool) -> FileBrowserItem {
    let components = path.split(separator: "/")
    return FileBrowserItem(
      id: path, rootId: "fixture-media", path: path, parentPath: components.dropLast().joined(separator: "/"),
      name: components.last.map(String.init) ?? path, kind: directory ? "directory" : "video",
      isDirectory: directory, isSymbolicLink: false, isHidden: false, isExpandable: directory,
      sizeBytes: directory ? nil : 1_024, modifiedAt: nil
    )
  }
}
#endif

@main
struct KisetsuMobileApp: App {
  @StateObject private var store: AppStore

  init() {
    let environment = ProcessInfo.processInfo.environment
    let defaults: UserDefaults
    #if DEBUG
    let runningTests = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    defaults = MobileDebugConfiguration.usesFixtures(environment: environment) || runningTests
      ? (UserDefaults(suiteName: "Kisetsu.Mobile.Fixture") ?? .standard) : .standard
    #else
    defaults = .standard
    #endif
    #if DEBUG
    if let backendURL = MobileDebugConfiguration.forcedBackendURL(
      environment: environment
    ) {
      defaults.set(backendURL, forKey: "backendURL")
      defaults.set(true, forKey: "mobileBackendConfigured")
    }
    #endif
    let appStore = AppStore(backendUserDefaults: defaults)
    #if DEBUG
    if runningTests {
      appStore.fixtureClient = APIClient(baseURL: "https://kisetsu-fixture.invalid") { _ in throw URLError(.unsupportedURL) }
    }
    if MobileDebugConfiguration.usesFixtures(environment: environment) {
      if let raw = environment["KISETSU_MOBILE_ORGANIZE_FIXTURE_URL"],
         let url = try? BackendEndpoint.normalizedURL(raw), url.host == "127.0.0.1", url.port != nil {
        appStore.fixtureClient = APIClient(baseURL: url.absoluteString)
      } else {
        appStore.fixtureClient = MobileAutoRefreshFixture(
          latency: .milliseconds(400),
          failStart: environment["KISETSU_MOBILE_AUTO_REFRESH_FAILURE"] == "1"
        ).client()
      }
      defaults.set("http://127.0.0.1:8000", forKey: "backendURL")
      defaults.set(true, forKey: "mobileBackendConfigured")
      appStore.sites = [
        SiteInfo(
          id: "fixture",
          name: "fixture",
          displayName: "脱敏模拟站点",
          baseUrl: nil,
          primaryUrl: nil,
          mirrors: [],
          activeBaseUrl: nil,
          enabled: true,
          supportsSearch: true,
          supportsRss: true
        )
      ]
      appStore.sitesLoaded = true
      appStore.selectedSiteIDs = ["fixture"]
      appStore.searchKeyword = "PT 优惠示例"
      appStore.searchResults = MobileDebugFixtureData.searchResults
      appStore.visibleSearchResults = MobileDebugFixtureData.searchResults
      appStore.selectedSearchFansubs = []
      appStore.selectedSearchResolutions = []
      appStore.searchEpisodeFilter = ""
      appStore.searchShowUnrecognizedEpisodes = false
      appStore.searchShowBatchOnly = false
      appStore.builtinEpisodeParseRules = MobileDebugFixtureData.builtinEpisodeRules
      appStore.globalEpisodeParseRules = MobileDebugFixtureData.customEpisodeRules
      appStore.lastGlobalEpisodeRuleTestResponse = MobileDebugFixtureData.episodeRuleTestResponse
      appStore.qBittorrentGlobalLimits = MobileDebugFixtureData.qbittorrentLimits
      appStore.transmissionGlobalLimits = MobileDebugFixtureData.transmissionLimits
      appStore.organizeTargets = MobileDebugFixtureData.organizeTargets
      if let detail = MobileDebugFixtureData.subscriptionDetail {
        appStore.subscriptions = MobileDebugFixtureData.subscriptions
        appStore.selectedSubscriptionDetail = detail
        appStore.overview = MobileDebugFixtureData.overview
        if MobileDebugConfiguration.initialTab(environment: environment) == "overview" {
          appStore.overview = OverviewDebugFixtures.overview(subscriptions: appStore.subscriptions)
        }
        appStore.history = MobileDebugFixtureData.history
        appStore.organizeHistory = MobileDebugFixtureData.organizeHistory
        appStore.organizeFailedCount = MobileDebugFixtureData.organizeHistory.filter { $0.status == "error" }.count
        appStore.mikanProjectSeason = MobileDebugFixtureData.mikanSeason
        appStore.mikanProjectResources = [
          "fixture-mikan-monday": MobileDebugFixtureData.mikanResources
        ]
      }
    }
    #endif
    _store = StateObject(wrappedValue: appStore)
  }

  var body: some Scene {
    WindowGroup {
      MobileRootView()
        .environmentObject(store)
    }
  }
}

enum MobileDebugConfiguration {
  static let backendEnvironmentKey = "KISETSU_MOBILE_BACKEND_URL"
  static let fixtureEnvironmentKey = "KISETSU_MOBILE_USE_FIXTURES"
  static let initialTabEnvironmentKey = "KISETSU_MOBILE_INITIAL_TAB"
  static let initialMoreDestinationEnvironmentKey = "KISETSU_MOBILE_INITIAL_MORE_DESTINATION"
  static let initialPlaylistDetailEnvironmentKey = "KISETSU_MOBILE_INITIAL_PLAYLIST_DETAIL"
  static let initialTaskSectionEnvironmentKey = "KISETSU_MOBILE_INITIAL_TASK_SECTION"
  static let initialSubscriptionDetailEnvironmentKey = "KISETSU_MOBILE_INITIAL_SUBSCRIPTION_DETAIL"
  static let fixtureTaskActionEnvironmentKey = "KISETSU_MOBILE_FIXTURE_TASK_ACTION"
  static let fixtureStatusEnvironmentKey = "KISETSU_MOBILE_FIXTURE_STATUS"
  static let fixtureDisableHeroRotationEnvironmentKey = "KISETSU_MOBILE_FIXTURE_DISABLE_HERO_ROTATION"
  static let fixtureSearchDownloadOutcomeEnvironmentKey = "KISETSU_MOBILE_FIXTURE_SEARCH_DOWNLOAD_OUTCOME"

  private static func value(
    _ key: String,
    legacyKey: String,
    environment: [String: String]
  ) -> String? {
    environment[key] ?? environment[legacyKey]
  }

  static func forcedBackendURL(environment: [String: String]) -> String? {
    guard let rawValue = value(
      backendEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_BACKEND_URL",
      environment: environment
    ),
          let normalized = try? BackendEndpoint.normalizedString(rawValue) else { return nil }
    return normalized
  }

  static func usesFixtures(environment: [String: String]) -> Bool {
    ["1", "true", "yes"].contains(
      value(
        fixtureEnvironmentKey,
        legacyKey: "ANIMEPILOT_MOBILE_USE_FIXTURES",
        environment: environment
      )?.lowercased()
    )
  }

  static var usesFixturesAtRuntime: Bool {
    usesFixtures(environment: ProcessInfo.processInfo.environment)
  }

  enum SearchDownloadOutcome: String {
    case success
    case failure
    case timeout
  }

  static func fixtureSearchDownloadOutcome(environment: [String: String]) -> SearchDownloadOutcome {
    SearchDownloadOutcome(rawValue: environment[fixtureSearchDownloadOutcomeEnvironmentKey] ?? "") ?? .success
  }

  static func shouldLoadNetwork(environment: [String: String]) -> Bool {
    !usesFixtures(environment: environment)
  }

  static var shouldLoadNetworkAtRuntime: Bool {
    shouldLoadNetwork(environment: ProcessInfo.processInfo.environment)
  }

  static func initialTab(environment: [String: String]) -> String? {
    value(
      initialTabEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_INITIAL_TAB",
      environment: environment
    )
  }

  static func initialMoreDestination(environment: [String: String]) -> String? {
    value(
      initialMoreDestinationEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_INITIAL_MORE_DESTINATION",
      environment: environment
    )
  }

  static func initialPlaylistDetail(environment: [String: String]) -> String? {
    value(
      initialPlaylistDetailEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_INITIAL_PLAYLIST_DETAIL",
      environment: environment
    )
  }

  static func initialTaskSection(environment: [String: String]) -> String? {
    value(
      initialTaskSectionEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_INITIAL_TASK_SECTION",
      environment: environment
    )
  }

  static func initialSubscriptionDetail(environment: [String: String]) -> String? {
    value(
      initialSubscriptionDetailEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_INITIAL_SUBSCRIPTION_DETAIL",
      environment: environment
    )
  }

  static func fixtureTaskAction(environment: [String: String]) -> String? {
    value(
      fixtureTaskActionEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_FIXTURE_TASK_ACTION",
      environment: environment
    )
  }

  static func fixtureStatus(environment: [String: String]) -> OperationStatus? {
    guard let value = value(
      fixtureStatusEnvironmentKey,
      legacyKey: "ANIMEPILOT_MOBILE_FIXTURE_STATUS",
      environment: environment
    )?.lowercased(),
          let phase = OperationPhase(rawValue: value),
          phase != .idle else { return nil }
    return OperationStatus(
      phase: phase,
      title: phase == .failed ? "模拟操作失败" : "模拟状态已更新",
      detail: phase == .failed ? "这是脱敏 Fixture，不包含真实服务器数据。" : "动画状态来自本地脱敏 Fixture。",
      updatedAt: Date()
    )
  }

  static func disablesFixtureHeroRotation(environment: [String: String]) -> Bool {
    usesFixtures(environment: environment)
      && ["1", "true", "yes"].contains(
        value(
          fixtureDisableHeroRotationEnvironmentKey,
          legacyKey: "ANIMEPILOT_MOBILE_FIXTURE_DISABLE_HERO_ROTATION",
          environment: environment
        )?.lowercased()
      )
  }
}

#if DEBUG
enum MobileDebugFixtureData {
  static let qbittorrentLimits = QbittorrentGlobalLimits(
    downloadLimit: 20 * 1_048_576,
    uploadLimit: 5 * 1_048_576
  )
  static let transmissionLimits = QbittorrentGlobalLimits(
    downloadLimit: 12 * 1_048_576,
    uploadLimit: 3 * 1_048_576
  )

  static let builtinEpisodeRules = [
    EpisodeParseRule(
      id: "fixture-builtin-episode",
      name: "EP 单集格式",
      pattern: #"(?:EP|E)(?<episode>\d{1,3})"#,
      enabled: true,
      priority: 0,
      episodeGroup: "episode",
      startGroup: "start",
      endGroup: "end",
      finalGroup: "final",
      ruleType: "builtin",
      exampleTitle: "Fixture Anime EP03"
    )
  ]

  static let customEpisodeRules = [
    EpisodeParseRule(
      id: "fixture-custom-range",
      name: "星号合集格式",
      pattern: #"★(?<start>\d{1,3})~(?<end>\d{1,3})(?<final>\(完\))?★"#,
      enabled: true,
      priority: 0,
      episodeGroup: "episode",
      startGroup: "start",
      endGroup: "end",
      finalGroup: "final",
      sampleTitle: "Fixture Anime★01~12(完)★"
    )
  ]

  static let episodeRuleTestResponse = EpisodeRuleTestResponse(
    ok: true,
    parsedTitle: ParsedAnimeTitle(
      originalTitle: "Fixture Anime★01~12(完)★",
      episodeStart: 1,
      episodeEnd: 12,
      isBatch: true,
      isFinal: true,
      displayEpisodeLabel: "合集 1-12",
      parseRuleName: "星号合集格式",
      confidence: 1,
      needsConfirmation: false
    ),
    message: "已识别合集第 1-12 集"
  )

  static let searchResults: [SearchResult] = {
    let json = """
    [
      {
        "id": "fixture-free",
        "title": "示例动画 S01E03 1080p WEB-DL",
        "subtitle": "脱敏模拟 PT 资源",
        "publishedAt": "2026-08-22T12:00:00+08:00",
        "size": "1.40 GB",
        "sizeBytes": 1503238554,
        "source": "FixturePT",
        "isFree": true,
        "discountLabel": "FREE",
        "freeRemaining": "6小时",
        "freeUntil": "2026-08-22T18:00:00+08:00",
        "seeders": 128,
        "leechers": 9,
        "downloads": 306,
        "magnetUrl": "magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=fixture-free",
        "parsedFansub": "示例字幕组",
        "parsedEpisode": 3,
        "parsedResolution": "1080p",
        "parsedDisplayEpisodeLabel": "第 3 集"
      },
      {
        "id": "fixture-2xfree",
        "title": "示例动画 S01E04 2160p HEVC",
        "subtitle": "脱敏模拟双倍上传免费资源",
        "publishedAt": "2026-08-22T11:30:00+08:00",
        "size": "3.20 GB",
        "sizeBytes": 3435973837,
        "source": "FixturePT",
        "isFree": true,
        "discountLabel": "2xFREE",
        "seeders": 64,
        "leechers": 5,
        "downloads": 120,
        "downloadUrl": "https://fixture.invalid/download/fixture-2xfree.torrent",
        "parsedFansub": "示例字幕组",
        "parsedEpisode": 4,
        "parsedResolution": "2160p",
        "parsedDisplayEpisodeLabel": "第 4 集"
      },
      {
        "id": "fixture-half",
        "title": "示例动画 S01E05 1080p AVC",
        "subtitle": "脱敏模拟半价资源",
        "publishedAt": "2026-08-22T10:15:00+08:00",
        "size": "980 MB",
        "sizeBytes": 1027604480,
        "source": "FixturePT",
        "isFree": false,
        "discountLabel": "50%",
        "seeders": 23,
        "leechers": 2,
        "downloads": 48,
        "parsedEpisode": 5,
        "parsedResolution": "1080p",
        "parsedDisplayEpisodeLabel": "第 5 集"
      }
    ]
    """
    return (try? JSONDecoder().decode([SearchResult].self, from: Data(json.utf8))) ?? []
  }()

  static let organizeTargets = [
    OrganizeTarget(
      id: 990001,
      name: "脱敏媒体库",
      path: "/fixture/library",
      mediaType: "tv",
      isDefault: true,
      enabled: true,
      createdAt: "2026-08-22T00:00:00Z",
      updatedAt: nil
    )
  ]

  static let subscriptionDetail: SubscriptionDetail? = {
    let json = """
    {
      "subscription": {
        "id": 900001,
        "name": "脱敏订阅示例",
        "keyword": "Fixture Anime",
        "sourceType": "keyword",
        "sites": ["fixture"],
        "aliases": ["Fixture Alias", "示例别名"],
        "rssUrls": [],
        "regexEnabled": false,
        "includeKeywords": [],
        "excludeKeywords": [],
        "filterOrder": "include_first",
        "resolution": "1080p",
        "resolutionMode": "preset",
        "resolutionPreset": "1080p",
        "minSizeBytes": 536870912,
        "season": 1,
        "episodeStart": 1,
        "episodeOffset": 0,
        "episodeParseRules": [],
        "totalEpisodes": 12,
        "totalEpisodesSource": "manual",
        "enabled": true,
        "autoDownload": true,
        "autoOrganize": true,
        "postOrganizeAction": "default",
        "tags": ["fixture"],
        "createdAt": "2026-08-22T00:00:00Z",
        "matchedCount": 2,
        "queuedCount": 0,
        "skippedCount": 0,
        "errorCount": 0,
        "episodeCount": 12,
        "downloadedCount": 1,
        "organizedCount": 1
      },
      "metadataHierarchy": [
        {
          "source": "fixture",
          "sourceLabel": "Fixture Metadata",
          "externalId": "fixture-900001",
          "title": "脱敏订阅示例",
          "originalTitle": "Fixture Anime",
          "aliases": ["示例别名"],
          "summary": "仅用于界面验收的脱敏番组资料。",
          "airDate": "2026-01-01",
          "totalEpisodes": 12,
          "rating": 7.8,
          "tags": ["战斗", "玄幻", "国漫", "WEB", "2026"],
          "seasonNumber": 1,
          "episodeCount": 12,
          "externalIds": {},
          "seasons": []
        }
      ],
      "matches": [
        {
          "id": 990001,
          "subscriptionId": 900001,
          "fingerprint": "fixture-subscription-resource",
          "result": {
            "id": "fixture-subscription-resource",
            "title": "[示例字幕组] Fixture Anime S01E02 1080p WEB-DL",
            "size": "1.40 GB",
            "source": "fixture"
          },
          "parsedTitle": {
            "originalTitle": "[示例字幕组] Fixture Anime S01E02 1080p WEB-DL",
            "episode": 2,
            "episodeNumber": 2,
            "episodeStart": 2,
            "episodeEnd": 2,
            "isBatch": false,
            "displayEpisodeLabel": "第 2 集",
            "season": 1,
            "seasonNumber": 1,
            "fansub": "示例字幕组",
            "resolution": "1080p",
            "confidence": 1,
            "needsConfirmation": false
          },
          "status": "downloaded",
          "firstSeenAt": "2026-08-22T00:00:00Z",
          "lastSeenAt": "2026-08-22T00:05:00Z",
          "logicalEpisodeStart": 2,
          "logicalEpisodeEnd": 2,
          "episodeOffsetApplied": 0,
          "episodeMappingLabel": "第 2 集"
        }
      ],
      "history": [
        {
          "id": 990001,
          "fingerprint": "fixture-subscription-resource",
          "title": "[示例字幕组] Fixture Anime S01E02 1080p WEB-DL",
          "source": "fixture",
          "downloaderType": "qbittorrent",
          "subscriptionId": 900001,
          "status": "completed",
          "organizeStatus": "pending",
          "taskStatus": "completed",
          "derivedStatus": "等待整理",
          "organizeAvailable": true,
          "displayEpisodeLabel": "第 2 集",
          "episodeStart": 2,
          "episodeEnd": 2,
          "seasonEpisodeStart": 2,
          "seasonEpisodeEnd": 2,
          "isBatch": false,
          "isMultiEpisode": false,
          "createdAt": "2026-08-22T00:05:00Z"
        }
      ],
      "episodeStatuses": [
        {
          "seasonNumber": 1,
          "episodeNumber": 1,
          "displayTitle": "第 01 集",
          "metadataSource": "fixture",
          "matchedResources": [],
          "downloadStatus": "已下载",
          "organizeStatus": "已整理",
          "autoOrganizeStatus": "已整理",
          "derivedStatus": "已整理",
          "organizeAvailable": false,
          "selected": false
        },
        {
          "seasonNumber": 1,
          "episodeNumber": 2,
          "displayTitle": "第 02 集",
          "metadataSource": "fixture",
          "matchedResources": [
            {
              "matchId": 990001,
              "rawTitle": "[示例字幕组] Fixture Anime S01E02 1080p WEB-DL",
              "site": "fixture",
              "fansubGroup": "示例字幕组",
              "resolution": "1080p",
              "resourceType": "single_episode",
              "displayEpisodeLabel": "第 2 集",
              "episodeStart": 2,
              "episodeEnd": 2,
              "seasonEpisodeStart": 2,
              "seasonEpisodeEnd": 2,
              "logicalEpisodeStart": 2,
              "logicalEpisodeEnd": 2,
              "episodeOffsetApplied": 0,
              "episodeMappingLabel": "第 2 集",
              "isBatch": false,
              "isMultiEpisode": false,
              "size": "1.40 GB",
              "downloadRecordId": 990001,
              "status": "downloaded",
              "downloadStatus": "已下载",
              "organizeStatus": "待整理",
              "derivedStatus": "等待整理"
            }
          ],
          "downloadStatus": "已下载",
          "organizeStatus": "未整理",
          "autoOrganizeStatus": "等待整理",
          "derivedStatus": "等待整理",
          "organizeAvailable": true,
          "selected": false
        }
      ],
      "autoOrganizeStatus": "等待下载",
      "matchedCount": 2,
      "queuedCount": 0,
      "skippedCount": 0,
      "errorCount": 0,
      "coverage": {
        "totalEpisodes": 12,
        "catalogTotalEpisodes": 12,
        "targetTotalEpisodes": 12,
        "skippedBeforeStart": 0,
        "downloadedCount": 1,
        "organizedCount": 1,
        "downloadedRanges": ["1"],
        "organizedRanges": ["1"],
        "hasBatchDownload": false,
        "hasBatchOrganized": false
      }
    }
    """
    guard var detail = try? JSONDecoder().decode(SubscriptionDetail.self, from: Data(json.utf8)) else {
      return nil
    }
    detail.subscription.episodeParseRules = customEpisodeRules
    detail.subscription.includeKeywords = ["(简体, 1080p)", "WEB-DL"]
    detail.subscription.excludeKeywords = ["(先行, CAM)"]
    return detail
  }()

  static let organizePreview = OrganizePreviewItem(
    previewId: 990001,
    downloadRecordId: 990001,
    sourcePath: "/fixture/downloads/Fixture Anime S01E02.mkv",
    libraryRoot: "/fixture/library",
    showDirectory: "Fixture Anime (2026)",
    seasonDirectory: "Season 01",
    filename: "Fixture Anime - S01E02.mkv",
    destinationPreview: "/fixture/library/Fixture Anime (2026)/Season 01/Fixture Anime - S01E02.mkv",
    willMove: false,
    canApply: true,
    blockReason: nil,
    warnings: [],
    isBatch: false,
    batchMode: nil,
    singleFileMode: "single_episode",
    episodeStart: 2,
    episodeEnd: 2,
    fileMappings: nil,
    subtitleMappings: nil
  )

  static let subscriptions: [Subscription] = {
    guard var first = subscriptionDetail?.subscription else { return [] }
    first.posterPalette = PosterPalette(
      primary: "#D84D72",
      secondary: "#F0A2B8",
      accent: "#FF6B93",
      background: "#F7CBD7",
      textContrast: "#1C1C1E"
    )
    first.episodeStart = 3
    first.fansub = "示例字幕组 A"
    first.summary = "仅用于界面验收的脱敏番组资料。"
    first.latestOrganizedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400))

    var second = first
    second.id = 900002
    second.name = "脱敏订阅二"
    second.keyword = "Fixture Anime Two"
    second.sourceType = "mikan_bangumi"
    second.sourceUrl = "https://mikan.example/Home/Bangumi/fixture"
    second.mikanBangumiUrl = second.sourceUrl
    second.episodeStart = 1
    second.fansub = "示例字幕组 B 与超长联合字幕组名称"
    second.downloadedCount = 8
    second.organizedCount = 6
    second.latestOrganizedAt = nil
    second.posterPalette = PosterPalette(
      primary: "#2E7D6F",
      secondary: "#79B7AA",
      accent: "#3F9C89",
      background: "#B8DDD5",
      textContrast: "#1C1C1E"
    )

    var third = first
    third.id = 900003
    third.name = "脱敏订阅三"
    third.keyword = "Fixture Anime Three"
    third.sourceType = "rss"
    third.rssUrls = ["https://rss.example/fixture.xml"]
    third.sites = []
    third.fansub = nil
    third.autoDownload = false
    third.downloadedCount = 4
    third.organizedCount = 2
    third.posterPalette = PosterPalette(
      primary: "#7758A6",
      secondary: "#B19ACC",
      accent: "#8B6DB7",
      background: "#D8CBE8",
      textContrast: "#1C1C1E"
    )
    return [first, second, third]
  }()

  static let mikanAnime: [MikanProjectAnime] = [
    MikanProjectAnime(
      bangumiId: "fixture-mikan-monday",
      title: "脱敏 Mikan 动画",
      originalTitle: "Fixture Mikan Anime",
      synopsis: "用于移动端界面验收的脱敏番组。",
      posterUrl: nil,
      posterOriginalUrl: nil,
      posterLocalUrl: nil,
      posterPalette: subscriptions.first?.posterPalette,
      detailUrl: nil,
      updateDate: "2026-08-22",
      airDate: "2026-07-06",
      broadcastDay: "周一",
      broadcastStart: "23:00",
      totalEpisodes: 12,
      officialUrl: nil,
      bangumiUrl: nil,
      bangumiSubjectId: "fixture-subject-1",
      section: .monday,
      subscribed: true,
      isGrayscale: false,
      statusText: nil,
      resourceCount: 3
    ),
    MikanProjectAnime(
      bangumiId: "fixture-mikan-movie",
      title: "脱敏剧场版",
      originalTitle: "Fixture Movie",
      synopsis: "用于验证剧场版分页的脱敏番组。",
      posterUrl: nil,
      posterOriginalUrl: nil,
      posterLocalUrl: nil,
      posterPalette: subscriptions.last?.posterPalette,
      detailUrl: nil,
      updateDate: "2026-08-20",
      airDate: nil,
      broadcastDay: nil,
      broadcastStart: nil,
      totalEpisodes: 1,
      officialUrl: nil,
      bangumiUrl: nil,
      bangumiSubjectId: "fixture-subject-movie",
      section: .movie,
      subscribed: false,
      isGrayscale: false,
      statusText: "剧场版",
      resourceCount: 1
    )
  ]

  static let mikanSeason = MikanProjectSeasonResponse(
    cacheVersion: 1,
    seasonTitle: "2026 夏季番组",
    year: 2026,
    season: "夏",
    cachedAt: "2026-08-22T12:00:00Z",
    lastRefreshStartedAt: nil,
    settings: MikanProjectSettings(),
    sections: [
      MikanProjectSection(id: .monday, name: "周一", shortName: "一", items: [mikanAnime[0]]),
      MikanProjectSection(id: .movie, name: "剧场版", shortName: "剧场版", items: [mikanAnime[1]])
    ],
    warnings: []
  )

  static let mikanResources = MikanProjectResourcesResponse(
    anime: mikanAnime[0],
    groups: [
      MikanProjectResourceGroup(
        fansubId: "fixture-fansub-a",
        fansub: "示例字幕组 A",
        resources: [searchResults[0], searchResults[2]]
      ),
      MikanProjectResourceGroup(
        fansubId: "fixture-fansub-b",
        fansub: "示例字幕组 B",
        resources: [searchResults[1]]
      )
    ],
    warnings: []
  )

  static let history: [DownloadHistory] = decode([DownloadHistory].self, json: """
  [
    {
      "id": 7001,
      "fingerprint": "fixture-history-1",
      "title": "脱敏动画 S01E03 1080p",
      "source": "FixturePT",
      "downloadUrl": null,
      "qbittorrentHash": "fixture-hash-1",
      "downloaderType": "qBittorrent",
      "remoteTaskId": "fixture-task-1",
      "torrentName": "脱敏动画 S01E03",
      "savePath": "fixture-downloads",
      "subscriptionId": 900001,
      "status": "downloading",
      "organizeStatus": "pending",
      "taskStatus": "downloading",
      "derivedStatus": "下载中",
      "derivedStatusDetail": "Fixture 进度",
      "organizeAvailable": false,
      "organizeBlockReason": null,
      "resourceType": "single",
      "displayEpisodeLabel": "第 03 集",
      "episodeStart": 3,
      "episodeEnd": 3,
      "absoluteEpisodeStart": null,
      "absoluteEpisodeEnd": null,
      "seasonEpisodeStart": 3,
      "seasonEpisodeEnd": 3,
      "isBatch": false,
      "isMultiEpisode": false,
      "createdAt": "2026-08-22T11:00:00Z",
      "qbittorrent": {
        "downloadRecordId": 7001,
        "subscriptionId": 900001,
        "episodeNumber": 3,
        "matched": true,
        "matchConfidence": 0.98,
        "matchReason": "Fixture",
        "hash": "fixture-hash-1",
        "name": "脱敏动画 S01E03",
        "state": "downloading",
        "stateLabel": "下载中",
        "progress": 0.62,
        "progressPercent": 62,
        "downloaded": 665845760,
        "totalSize": 1073741824,
        "downloadSpeed": 5242880,
        "uploadSpeed": 131072,
        "eta": 120,
        "ratio": 0.12,
        "seedingTime": 0,
        "numSeeds": 8,
        "numComplete": 24,
        "numIncomplete": 3,
        "numLeechs": 3,
        "lastSeenAt": "2026-08-22T12:00:00Z",
        "seedingStopCondition": null,
        "postSeedingAction": null,
        "seedingTargetSeconds": null,
        "seedingRemainingSeconds": null,
        "seedingTargetRatio": null,
        "seedingTargetReached": null,
        "message": "Fixture 任务"
      }
    },
    {
      "id": 7002,
      "fingerprint": "fixture-history-2",
      "title": "脱敏动画二 S01E08 2160p",
      "source": "FixturePT",
      "downloadUrl": null,
      "qbittorrentHash": null,
      "downloaderType": "qBittorrent",
      "remoteTaskId": null,
      "torrentName": null,
      "savePath": "fixture-downloads",
      "subscriptionId": 900002,
      "status": "completed",
      "organizeStatus": "organized",
      "taskStatus": "completed",
      "derivedStatus": "已整理",
      "derivedStatusDetail": null,
      "organizeAvailable": false,
      "organizeBlockReason": null,
      "resourceType": "single",
      "displayEpisodeLabel": "第 08 集",
      "episodeStart": 8,
      "episodeEnd": 8,
      "absoluteEpisodeStart": null,
      "absoluteEpisodeEnd": null,
      "seasonEpisodeStart": 8,
      "seasonEpisodeEnd": 8,
      "isBatch": false,
      "isMultiEpisode": false,
      "createdAt": "2026-08-21T10:00:00Z",
      "qbittorrent": null
    },
    {
      "id": 7003,
      "fingerprint": "fixture-history-manual",
      "title": "脱敏手动下载 S01E06 1080p",
      "source": "manual",
      "downloadUrl": "fixture://readd-disabled",
      "qbittorrentHash": "fixture-hash-manual",
      "downloaderType": "qBittorrent",
      "remoteTaskId": "fixture-task-manual",
      "torrentName": "脱敏手动下载 S01E06",
      "savePath": "fixture-downloads",
      "subscriptionId": null,
      "status": "completed",
      "organizeStatus": "未整理",
      "taskStatus": "已完成",
      "derivedStatus": "等待整理",
      "derivedStatusDetail": "下载完成，可手动整理",
      "organizeAvailable": true,
      "organizeBlockReason": null,
      "resourceType": "single_episode",
      "displayEpisodeLabel": "第 06 集",
      "episodeStart": 6,
      "episodeEnd": 6,
      "absoluteEpisodeStart": null,
      "absoluteEpisodeEnd": null,
      "seasonEpisodeStart": 6,
      "seasonEpisodeEnd": 6,
      "isBatch": false,
      "isMultiEpisode": false,
      "createdAt": "2026-08-22T12:30:00Z",
      "qbittorrent": {
        "downloadRecordId": 7003,
        "subscriptionId": null,
        "episodeNumber": 6,
        "matched": true,
        "progress": 1,
        "progressPercent": 100,
        "downloaded": 1073741824,
        "totalSize": 1073741824,
        "downloadSpeed": 0,
        "uploadSpeed": 0,
        "ratio": 0,
        "seedingTime": 0,
        "message": "Fixture 已完成任务"
      }
    }
  ]
  """) ?? []

  static let organizeHistory: [OrganizeHistoryRecord] = decode([OrganizeHistoryRecord].self, json: """
  [
    {
      "id": 8001,
      "sourcePath": "fixture-source",
      "destinationPath": "fixture-destination",
      "status": "success",
      "message": "Fixture 整理成功",
      "preview": {
        "previewId": 8001,
        "downloadRecordId": 7002,
        "organizeTargetId": null,
        "sourcePath": "fixture-source",
        "libraryRoot": "fixture-library",
        "showDirectory": "脱敏动画二",
        "seasonDirectory": "Season 01",
        "filename": "脱敏动画二 - S01E08.mkv",
        "destinationPreview": "fixture-destination",
        "willMove": true,
        "canApply": true,
        "blockReason": null,
        "warnings": [],
        "isBatch": false,
        "batchMode": "single_file",
        "singleFileMode": "single",
        "episodeStart": 8,
        "episodeEnd": 8,
        "fileMappings": [],
        "subtitleMappings": []
      },
      "qbittorrentTaskDeleted": false,
      "deleteFilesFromQbittorrent": false,
      "cleanupAttempted": false,
      "cleanupStatus": null,
      "cleanupPath": null,
      "cleanupMessage": null,
      "subscriptionId": 900002,
      "subscriptionSeason": 1,
      "resourceExplicitSeason": 1,
      "effectiveSeason": 1,
      "seasonSource": "fixture",
      "manualOverride": false,
      "overrideReason": null,
      "createdAt": "2026-08-21T10:30:00Z"
    },
    {
      "id": 8002,
      "sourcePath": "fixture-failed-source",
      "destinationPath": "fixture-failed-destination",
      "status": "error",
      "message": "Fixture 整理失败",
      "preview": {
        "previewId": 8002,
        "downloadRecordId": 7003,
        "organizeTargetId": null,
        "sourcePath": "fixture-failed-source",
        "libraryRoot": "fixture-library",
        "showDirectory": "脱敏动画三",
        "seasonDirectory": "Season 01",
        "filename": "脱敏动画三 - S01E09.mkv",
        "destinationPreview": "fixture-failed-destination",
        "willMove": true,
        "canApply": false,
        "blockReason": "Fixture 源文件不可用",
        "warnings": [],
        "isBatch": false,
        "batchMode": "single_file",
        "singleFileMode": "single",
        "episodeStart": 9,
        "episodeEnd": 9,
        "fileMappings": [],
        "subtitleMappings": []
      },
      "qbittorrentTaskDeleted": false,
      "deleteFilesFromQbittorrent": false,
      "cleanupAttempted": false,
      "cleanupStatus": null,
      "cleanupPath": null,
      "cleanupMessage": null,
      "subscriptionId": 900003,
      "subscriptionSeason": 1,
      "resourceExplicitSeason": 1,
      "effectiveSeason": 1,
      "seasonSource": "fixture",
      "manualOverride": false,
      "overrideReason": null,
      "createdAt": "2026-08-21T11:00:00Z"
    }
  ]
  """) ?? []

  static let playlistQuarters = [
    PlaylistQuarterOption(year: 2026, month: 1, count: 2),
    PlaylistQuarterOption(year: 2026, month: 4, count: 1)
  ]

  static let playlistQuarter = PlaylistQuarterResponse(
    year: 2026,
    month: 1,
    title: "2026 年 1 月番组",
    items: [
      PlaylistQuarterItem(
        key: "fixture-playlist-1",
        title: "脱敏番组一",
        originalTitle: "Fixture Playlist One",
        aliases: [],
        mediaType: "tv",
        begin: "2026-01-05",
        broadcast: "R/2026-01-05T15:00:00Z/P7D",
        bangumiId: "fixture-playlist-bangumi-1",
        externalIds: [:],
        links: [
          PlaylistSiteLink(site: "official", title: "官方网站", kind: "info", url: "https://fixture.example/info/official"),
          PlaylistSiteLink(site: "bangumi", title: "番组计划", kind: "info", url: "https://fixture.example/info/bangumi"),
          PlaylistSiteLink(site: "stream", title: "示例配信平台", kind: "onair", url: "https://fixture.example/onair/one"),
          PlaylistSiteLink(site: "mikan", title: "蜜柑计划", kind: "resource", url: "https://fixture.example/resource/mikan"),
          PlaylistSiteLink(site: "moe", title: "萌番组", kind: "resource", url: "https://fixture.example/resource/moe")
        ],
        posterUrl: nil,
        pairing: PlexPairing(itemKey: "fixture-playlist-1", plexRatingKey: "fixture-plex-1", title: "脱敏番组一", year: 2026, source: "automatic", score: 0.98, reason: "Fixture 自动匹配", valid: true, updatedAt: "2026-08-22T12:00:00Z"),
        matchState: "matched",
        matchReason: "Fixture 自动匹配"
      ),
      PlaylistQuarterItem(
        key: "fixture-playlist-2",
        title: "脱敏番组二",
        originalTitle: "Fixture Playlist Two",
        aliases: [],
        mediaType: "tv",
        begin: "2026-01-06",
        broadcast: "R/2026-01-06T14:30:00Z/P7D",
        bangumiId: "fixture-playlist-bangumi-2",
        externalIds: [:],
        links: [],
        posterUrl: nil,
        pairing: nil,
        matchState: "unmatched",
        matchReason: "Fixture 待手动配对"
      )
    ],
    cachedAt: "2026-08-22T12:00:00Z",
    sourceVersion: "fixture",
    stale: false,
    warning: nil,
    attribution: "Fixture"
  )

  static let playlists = PlaylistDebugFixtures.playlists

  static let playlistHierarchy = PlexShowHierarchy(
    show: PlexShow(
      ratingKey: "fixture-plex-1",
      title: "脱敏番组一",
      originalTitle: "Fixture Playlist One",
      year: 2026,
      libraryId: "fixture-library",
      libraryTitle: "Fixture Library",
      guids: [],
      seasonCount: 1
    ),
    seasons: [
      PlexSeason(
        ratingKey: "fixture-season-1",
        title: "Season 1",
        seasonNumber: 1,
        episodes: (1...3).map { number in
          PlexEpisode(
            ratingKey: "fixture-plex-episode-\(number)",
            title: "第 \(number) 集",
            seasonNumber: 1,
            episodeNumber: number,
            durationMs: 1800000,
            playable: true
          )
        }
      )
    ]
  )

  static let playlistDetail = PlaylistDebugFixtures.detail(for: playlists[0].ratingKey)

  private static func decode<T: Decodable>(_ type: T.Type, json: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(json.utf8))
  }

  static let overview = OverviewResponse(
    downloadingItems: [],
    pendingOrganizeItems: [
      decode(OverviewItem.self, json: """
      {
        "id": "fixture-organize-7003",
        "title": "脱敏手动下载 S01E06",
        "subtitle": "第 06 集 · 手动下载",
        "detail": "下载完成，可手动整理",
        "status": "等待整理",
        "severity": "info",
        "systemImage": "folder.badge.gearshape",
        "createdAt": "2026-08-22T12:30:00Z",
        "target": {
          "targetType": "organize_preview",
          "targetId": "7003",
          "subscriptionId": null,
          "action": "organize"
        }
      }
      """)!
    ],
    issues: [],
    recentCompleted: [],
    subscriptionSummary: OverviewSubscriptionSummary(
      total: 3,
      enabled: 3,
      refreshing: 0,
      failed: 0,
      latestRefreshSummary: nil,
      latestError: nil
    )
  )
}
#endif
