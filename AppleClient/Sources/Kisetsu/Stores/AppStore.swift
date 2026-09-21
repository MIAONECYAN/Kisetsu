import Foundation

enum AppStoreError: LocalizedError {
  case userFacing(String)

  var errorDescription: String? {
    switch self {
    case .userFacing(let message):
      message
    }
  }
}

enum SearchResolutionFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
  case p720
  case p1080
  case p2160
  case other
  case unrecognized

  var id: String { rawValue }

  var title: String {
    switch self {
    case .p720: "720p"
    case .p1080: "1080p"
    case .p2160: "2160p / 4K"
    case .other: "其他"
    case .unrecognized: "未识别"
    }
  }

  static func category(for structuredResolution: String?) -> Self {
    guard let value = structuredResolution?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "×", with: "x")
      .replacingOccurrences(of: " ", with: ""),
      !value.isEmpty else {
      return .unrecognized
    }
    switch value {
    case "720p", "1280x720": return .p720
    case "1080p", "1920x1080": return .p1080
    case "2160p", "3840x2160", "4096x2160", "4k": return .p2160
    default: return .other
    }
  }
}

enum SearchEpisodeFilterParser {
  static func normalizedValue(from value: String) -> String? {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
    guard !normalized.isEmpty else { return "" }

    let candidate = normalized.hasPrefix(":") ? String(normalized.dropFirst()) : normalized
    guard let range = range(from: candidate) else { return nil }
    if range.lowerBound == range.upperBound {
      return String(range.lowerBound)
    }
    return "\(range.lowerBound)-\(range.upperBound)"
  }

  static func range(from value: String) -> ClosedRange<Int>? {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
    let candidate = normalized.hasPrefix(":") ? String(normalized.dropFirst()) : normalized
    if let number = Int(candidate), number > 0 {
      return number...number
    }
    for separator in ["-", "~", "～"] where candidate.contains(separator) {
      let parts = candidate.split(separator: Character(separator), maxSplits: 1).compactMap { Int($0) }
      if parts.count == 2, parts[0] > 0, parts[1] >= parts[0] {
        return parts[0]...parts[1]
      }
    }
    return nil
  }
}

private struct AIProviderDraft {
  var baseURL: String
  var model: String
  var apiKeyInput: String
  var apiKeyConfigured: Bool
  var apiKeyMasked: String?
}

@MainActor
final class AppStore: ObservableObject {
  static let defaultBackendURL = "http://127.0.0.1:8000"

  private let backendUserDefaults: UserDefaults
  @Published private(set) var backendURL: String
  @Published var backendURLDraft: String
  @Published var healthText = "未知"
  @Published var backendConnectionDetail = "尚未检测。若站点管理为空或提示无法连接，请先启动后端。"
  @Published var backendLastCheckedAt: Date?
  @Published var sites: [SiteInfo] = []
  @Published var sitesLoaded = false
  @Published var selectedSiteIDs: Set<String> {
    didSet { backendUserDefaults.set(Array(selectedSiteIDs).sorted(), forKey: "selectedSiteIDs") }
  }
  @Published var selectedSearchSiteIDs: Set<String> {
    didSet {
      backendUserDefaults.set(Array(selectedSearchSiteIDs).sorted(), forKey: "selectedSearchSiteIDs")
      hasStoredSearchSiteSelection = true
    }
  }
  @Published var qbittorrent = QbittorrentConfig()
  @Published var qbittorrentVersionText = "未检测"
  @Published var qbittorrentConnectionText = "未测试"
  @Published var qbittorrentConnectionSucceeded = false
  @Published var qbittorrentLastTestedAt: Date?
  @Published var transmission = TransmissionConfig()
  @Published var transmissionVersionText = "未检测"
  @Published var transmissionConnectionText = "未测试"
  @Published var transmissionConnectionSucceeded = false
  @Published var transmissionLastTestedAt: Date?
  @Published var downloaderRouting = DownloaderRoutingSettings()
  @Published var downloaderStatuses: [DownloaderStatus] = []
  @Published var metadataSettings = MetadataSettingsResponse(tmdbConfigured: false, tmdbApiKeyConfigured: false, tmdbApiKeyMasked: nil, message: "TMDB API Key 未配置")
  @Published var tmdbAPIKeyInput = ""
  @Published var tmdbTestText = "未检测"
  @Published var notificationSettings = NotificationSettingsResponse(
    enabled: false,
    bark: BarkNotificationSettingsResponse(enabled: false, serverUrl: "https://api.day.app", hasDeviceKey: false, maskedDeviceKey: nil, group: "Kisetsu", sound: nil, icon: nil, level: "active", url: nil, autoCopy: false),
    events: NotificationEventSettings(),
    showFullPaths: false,
    message: "通知未启用"
  )
  @Published var notificationsEnabled = false
  @Published var barkEnabled = false
  @Published var barkServerURL = "https://api.day.app"
  @Published var barkDeviceKeyInput = ""
  @Published var barkGroup = "Kisetsu"
  @Published var barkSound = ""
  @Published var barkIcon = ""
  @Published var barkLevel = "active"
  @Published var barkURL = ""
  @Published var barkAutoCopy = false
  @Published var notifySubscription = true
  @Published var notifyDownload = true
  @Published var notifyOrganize = true
  @Published var notificationTestText = "未检测"
  @Published var aiSettings = AISettingsResponse(enabled: false, provider: "none", baseUrl: nil, model: nil, apiKeyConfigured: false, apiKeyMasked: nil, useAiForSmartSubscription: false, configured: false, message: "未配置 AI，可在 设置 → AI 辅助分析 中配置")
  @Published var aiEnabled = false
  @Published var aiProvider = "none"
  @Published var aiBaseURL = ""
  @Published var aiModel = ""
  @Published var aiAPIKeyInput = ""
  @Published var useAIForSmartSubscription = false
  @Published var aiTestText = "未检测"
  @Published var aiModels: [AIModelInfo] = []
  @Published var aiModelListText = "未获取"
  @Published var lastAIAnalysis: AITitleAnalysisResponse?
  private var aiProviderDrafts: [String: AIProviderDraft] = [:]
  @Published var lastSmartPrefill: SmartSubscriptionPrefillResponse?
  @Published var organizePolicy = OrganizePolicySettings(
    autoOrganizeByDefault: true,
    postOrganizeAction: "remove_task_keep_files",
    deleteTaskAfterOrganize: true,
    deleteFilesAfterOrganize: false,
    keepSeeding: false,
    seedingStopRatio: nil,
    seedingStopMinutes: nil,
    seedingStopMode: "any",
    postSeedingAction: "pause",
    cleanEmptyDownloadDirs: true
  )
  @Published var searchSettings = SearchSettings(siteTimeoutSeconds: 15)
  @Published var mikanProjectSettings = MikanProjectSettings()
  @Published var mikanProjectSeason: MikanProjectSeasonResponse?
  @Published private(set) var mikanProjectSeasonLoading = false
  @Published private(set) var mikanProjectSeasonError: String?
  @Published var mikanProjectResources: [String: MikanProjectResourcesResponse] = [:]
  @Published var mikanProjectResourceLoadingIDs: Set<String> = []
  @Published var mikanProjectHideSubscribed = false
  @Published var searchDeduplicate: Bool {
    didSet { backendUserDefaults.set(searchDeduplicate, forKey: "searchDeduplicate") }
  }
  @Published var searchPageSize = 30
  @Published var searchPaginationEnabled: Bool {
    didSet { backendUserDefaults.set(searchPaginationEnabled, forKey: "searchPaginationEnabled") }
  }
  @Published private(set) var searchCurrentPage = 1
  @Published var searchSummaryText = ""
  @Published var searchDiagnostics: SearchDiagnostics?
  @Published var siteMirrorDrafts: [String: String] = [:]
  @Published var organizeTargets: [OrganizeTarget] = []
  @Published private(set) var organizeTargetsLoaded = false
  private var organizeTargetsLoadTask: Task<Bool, Never>?
  @Published var editingOrganizeTargetID: Int?
  @Published var organizeTargetName = ""
  @Published var organizeTargetPath = ""
  @Published var organizeTargetMediaType = "anime"
  @Published var organizeTargetIsDefault = false
  @Published var organizeTargetEnabled = true
  @Published var lastOrganizeTargetValidation: OrganizeTargetValidateResponse?
  @Published var searchKeyword = ""
  @Published var searchResults: [SearchResult] = []
  @Published var visibleSearchResults: [SearchResult] = []
  @Published var searchFiltering = false
  @Published var searchFilterSummaryText = ""
  @Published var selectedSearchFansubs: Set<String> = [] {
    didSet { scheduleSearchFilterUpdate() }
  }
  @Published var searchEpisodeFilter = "" {
    didSet { scheduleSearchFilterUpdate() }
  }
  @Published var searchShowUnrecognizedEpisodes = false {
    didSet { scheduleSearchFilterUpdate() }
  }
  @Published var searchShowBatchOnly = false {
    didSet { scheduleSearchFilterUpdate() }
  }
  @Published var selectedSearchResolutions: Set<SearchResolutionFilter> = [] {
    didSet { scheduleSearchFilterUpdate() }
  }
  @Published var searchWarnings: [String] = []
  @Published var lastWarningCount = 0
  @Published var lastSubscriptionSuggestion: SubscriptionSuggestionResponse?
  @Published private(set) var smartSubscriptionPreparingResultID: String?
  @Published private(set) var smartSubscriptionFansubOptions: [String] = []
  @Published private(set) var isSmartSubscriptionExistingMatch = false
  @Published var subscriptions: [Subscription] = []
  @Published var subscriptionListFilter: SubscriptionListFilter = .all
  @Published var refreshQueueStates: [Int: String] = [:]
  @Published var refreshQueueCurrentID: Int?
  @Published var refreshQueueProgressText = ""
  @Published var refreshQueueRunning = false
  @Published var editingSubscriptionID: Int?
  @Published private(set) var editingSubscriptionVersion: String?
  @Published var subscriptionName = ""
  @Published var subscriptionSourceType = "keyword"
  @Published var subscriptionIdentityKey: String?
  @Published var subscriptionKeyword = ""
  @Published var subscriptionSourceURL = ""
  @Published var subscriptionAliases = ""
  @Published var subscriptionRSSURLs = ""
  @Published var subscriptionRegex = ""
  @Published var subscriptionRegexEnabled = false
  @Published var subscriptionEpisodeFilter = ""
  @Published var subscriptionIncludeKeywords = ""
  @Published var subscriptionExcludeKeywords = ""
  @Published var subscriptionFilterOrder = "include_first"
  @Published var subscriptionFansub = ""
  @Published var subscriptionResolution = ""
  @Published var subscriptionResolutionCustom = ""
  @Published var subscriptionMinSize = ""
  @Published var subscriptionMinSizeUnit = SubscriptionSizeUnit.gigabytes
  @Published var subscriptionMaxSize = ""
  @Published var subscriptionMaxSizeUnit = SubscriptionSizeUnit.gigabytes
  @Published var subscriptionSeason = ""
  @Published var subscriptionEpisodeStart = "1"
  @Published var subscriptionEpisodeOffset = ""
  @Published var subscriptionUseCustomEpisodeRules = false
  @Published var subscriptionEpisodeParseRules: [EpisodeParseRule] = []
  @Published var subscriptionEpisodeRuleTestTitle = ""
  @Published var lastEpisodeRuleTestResponse: EpisodeRuleTestResponse?
  @Published var builtinEpisodeParseRules: [EpisodeParseRule] = []
  @Published var globalEpisodeParseRules: [EpisodeParseRule] = []
  @Published var globalEpisodeRuleTestTitle = ""
  @Published var lastGlobalEpisodeRuleTestResponse: EpisodeRuleTestResponse?
  @Published var subscriptionTotalEpisodes = ""
  @Published private(set) var subscriptionTotalEpisodesSource: String?
  private var subscriptionTotalEpisodesBaseline: Int?
  private var subscriptionMetadataEpisodeCount: Int?
  @Published var subscriptionSavePath = ""
  @Published var subscriptionCategory = ""
  @Published var subscriptionTags = ""
  @Published var subscriptionEnabled = true
  @Published var subscriptionAutoDownload = true
  @Published var subscriptionOrganizeTargetID: Int?
  @Published var subscriptionAutoOrganize = false
  @Published var subscriptionPostOrganizeAction = "default"
  @Published var subscriptionDeleteTaskAfterOrganize = true
  @Published var subscriptionDeleteFilesAfterOrganize = false
  @Published var subscriptionKeepSeeding = false
  @Published var subscriptionSeedingPolicyMode = "inherit"
  @Published var subscriptionSeedingTimeEnabled = false
  @Published var subscriptionSeedingHours = ""
  @Published var subscriptionSeedingRatioEnabled = false
  @Published var subscriptionSeedingRatioPercent = ""
  @Published var subscriptionSeedingStopMode = "any"
  @Published var subscriptionPostSeedingAction = "pause"
  @Published var lastRefreshResponse: RefreshResponse?
  @Published var lastSubscriptionTestMatchResponse: SubscriptionTestMatchResponse?
  @Published var lastRefreshAllResponse: RefreshAllResponse?
  @Published var showingRefreshAllSummary = false
  @Published var selectedSubscriptionDetail: SubscriptionDetail?
  @Published var lastSubscriptionDownloadResponse: SubscriptionDownloadResponse?
  @Published var lastSubscriptionOrganizeResponse: SubscriptionOrganizeResponse?
  @Published var subscriptionMatches: [SubscriptionMatch] = []
  @Published var selectedMatchSubscriptionID: Int?
  @Published var schedulerStatus: SchedulerStatus?
  @Published var requestedTaskSection: String?
  @Published var schedulerIntervalSeconds = 1800
  @Published var brushSettings = BrushSettings()
  @Published var qBittorrentGlobalLimits = QbittorrentGlobalLimits()
  @Published var transmissionGlobalLimits = QbittorrentGlobalLimits()
  @Published var brushStatus: BrushStatus?
  @Published var brushTasks: [BrushTask] = []
  @Published var brushRuns: [BrushRun] = []
  @Published var brushCapabilities: [BrushCapabilities] = []
  @Published var brushSiteAccounts: [BrushSiteAccount] = []
  @Published var showArchivedBrushTasks = false
  @Published var history: [DownloadHistory] = []
  @Published var historyManagementIDs: Set<Int> = []
  @Published var lastHistoryManageResponse: DownloadHistoryManageResponse?
  @Published var lastHistoryClearResponse: HistoryClearResponse?
  @Published var lastResetSubscriptionResponse: ResetSubscriptionResponse?
  @Published var selectedHistorySubscriptionID: Int?
  private var silentHistoryRefreshInFlight = false
  private var silentBrushRefreshInFlight = false
  @Published var metadataQuery = ""
  @Published var metadataCandidates: [MetadataCandidate] = []
  @Published var metadataWarnings: [String] = []
  @Published var metadataRecommendedCandidateID: String?
  @Published var metadataSuggestedMapping: PlexSeasonMapping?
  @Published var metadataMergeSummary: String?
  @Published var showingMetadataReview = false
  @Published var pendingMetadataRecognitionSubscriptionID: Int?
  private var pendingMetadataRecognitionBackendURL: String?
  @Published var metadataBindings: [MetadataBindingRecord] = []
  @Published var metadataTargetType = "resource"
  @Published var metadataTargetID = "manual"
  @Published var parsedTitle: ParsedAnimeTitle?
  @Published var mapping = PlexSeasonMapping(
    subjectKey: "manual",
    showName: "",
    showYear: nil,
    seasonNumber: 1,
    episodeOffset: 0,
    specialEpisodeNumbers: [:]
  )
  @Published var plexMappings: [PlexMappingRecord] = []
  @Published var sourcePath = ""
  @Published var libraryRoot: String {
    didSet { UserDefaults.standard.set(libraryRoot, forKey: "libraryRoot") }
  }
  @Published var originalFilename = ""
  @Published var episodeTitle = ""
  @Published var organizePreview: OrganizePreviewItem?
  @Published var showingBatchOrganizeSheet = false
  @Published var showingManualHistoryOrganizeSheet = false
  @Published var manualOrganizeHistoryItem: DownloadHistory?
  @Published var manualOrganizeSelectedCandidateID: String?
  @Published var manualOrganizeOriginalTitle = ""
  @Published var manualOrganizeYear = ""
  @Published var manualOrganizeEpisodeStart = ""
  @Published var manualOrganizeEpisodeEnd = ""
  @Published var manualOrganizeIsBatch = false
  @Published private(set) var manualOrganizeRequiresMultipleFiles = false
  @Published var manualOrganizeTargetID: Int?
  @Published private(set) var manualOrganizeOperation = ManualOrganizeOperationState()
  @Published var manualOrganizeMediaType = "anime"
  @Published private(set) var isApplyingOrganizePreview = false
  @Published var organizePreviewHistory: [OrganizePreviewRecord] = []
  @Published var organizeHistory: [OrganizeHistoryRecord] = []
  @Published var organizeFailedCount = 0
  @Published var overview: OverviewResponse?
  @Published var lastOrganizeApplyResponse: OrganizeApplyResponse?

  private var subscriptionDownloaderSavePath: String? {
    downloaderRouting.subscriptionDownloader == "transmission" ? transmission.defaultSavePath : qbittorrent.defaultSavePath
  }

  private var subscriptionDownloaderCategory: String? {
    downloaderRouting.subscriptionDownloader == "transmission" ? nil : qbittorrent.defaultCategory
  }

  private var subscriptionDownloaderTags: [String] {
    downloaderRouting.subscriptionDownloader == "transmission" ? transmission.defaultLabels : qbittorrent.defaultTags
  }
  @Published var lastOrganizeHistoryClearResponse: HistoryClearResponse?
  @Published var lastFailedOrganizeHistoryDeleteResponse: OrganizeFailedHistoryDeleteResponse?
  @Published var logs: [String] = []
  @Published var operationStatus: OperationStatus = .idle
  @Published var isLoading = false
  @Published private(set) var isBootstrapping = false
  @Published var activeOperationLabel: String?
  @Published var isTestingAllDownloaders = false
  @Published private(set) var metadataBindingCandidateID: String?

  private var operationSequence = LatestOperationSequence()
  private var subscriptionLoadSequence = LatestOperationSequence()
  private var overviewLoadSequence = LatestOperationSequence()
  private var metadataBindSequence = LatestOperationSequence()
  private var manualOrganizeSequence = LatestOperationSequence()
  #if DEBUG
  var fixtureClient: APIClient?
  #endif
  private var metadataBindingSubmissionGate = MetadataBindingSubmissionGate()
  private var activeOperationLabels: [UInt64: String] = [:]
  private let mikanProjectSeasonLoad = PersistentSingleFlight()
  private let hadStoredSiteSelection: Bool
  private var hasStoredSearchSiteSelection: Bool

  var enabledSites: [SiteInfo] {
    sites.filter { $0.enabled ?? true }
  }

  var enabledSiteIDs: Set<String> {
    Set(enabledSites.map(\.id))
  }

  var contentSites: [SiteInfo] {
    enabledSites.filter { $0.brushOnly != true }
  }

  var contentSiteIDs: Set<String> {
    Set(contentSites.map(\.id))
  }

  var searchSites: [SiteInfo] {
    contentSites.filter(\.supportsSearch)
  }

  var searchSiteIDs: Set<String> {
    Set(searchSites.map(\.id))
  }

  var validSelectedSearchSiteIDs: Set<String> {
    selectedSearchSiteIDs.intersection(searchSiteIDs)
  }

  var searchSiteSelectionSummary: String {
    let selected = searchSites.filter { validSelectedSearchSiteIDs.contains($0.id) }
    if selected.isEmpty { return "未选择站点" }
    if selected.count == 1 { return selected[0].label }
    return "\(selected.count) 个站点"
  }

  var searchResolutionCounts: [SearchResolutionFilter: Int] {
    Self.searchResolutionCounts(in: searchResults)
  }

  var searchFansubCounts: [String: Int] {
    Self.searchFansubCounts(in: searchResults)
  }

  var searchHasActiveFilters: Bool {
    !selectedSearchFansubs.isEmpty
      || !searchEpisodeFilter.isEmpty
      || searchShowUnrecognizedEpisodes
      || searchShowBatchOnly
      || !selectedSearchResolutions.isEmpty
  }

  var subscriptionSiteOptions: [SiteInfo] {
    siteOptions(includeSelectedLegacy: editingSubscriptionID != nil)
  }

  var subscriptionEditorTitle: String {
    return editingSubscriptionID == nil ? "新建订阅" : "编辑订阅"
  }

  var subscriptionPrimaryActionTitle: String {
    if isSmartSubscriptionExistingMatch { return "更新订阅" }
    return editingSubscriptionID == nil ? "创建订阅" : "保存订阅"
  }

  func legacySiteHint(for site: SiteInfo) -> String? {
    guard editingSubscriptionID != nil, selectedSiteIDs.contains(site.id) else { return nil }
    if sites.contains(where: { $0.id == site.id }) {
      if site.brushOnly == true { return "仅刷流，旧订阅保留" }
      return site.enabled == false ? "已停用，旧订阅保留" : nil
    }
    return "已移除，旧订阅保留"
  }

  private func siteOptions(includeSelectedLegacy: Bool) -> [SiteInfo] {
    var options = contentSites
    guard includeSelectedLegacy else { return options }
    var knownIDs = Set(options.map(\.id))
    for siteID in selectedSiteIDs.sorted() where !knownIDs.contains(siteID) {
      if let site = sites.first(where: { $0.id == siteID }) {
        options.append(site)
      } else {
        let label = siteLabel(for: siteID)
        options.append(
          SiteInfo(
            id: siteID,
            name: label,
            displayName: label,
            baseUrl: nil,
            primaryUrl: nil,
            mirrors: [],
            activeBaseUrl: nil,
            enabled: false,
            supportsSearch: true,
            supportsRss: true
          )
        )
      }
      knownIDs.insert(siteID)
    }
    return options
  }

  private var searchFilterTask: Task<Void, Never>?

  init(backendUserDefaults: UserDefaults = .standard) {
    self.backendUserDefaults = backendUserDefaults
    let storedSiteIDs = backendUserDefaults.stringArray(forKey: "selectedSiteIDs")
    hadStoredSiteSelection = storedSiteIDs != nil
    selectedSiteIDs = Set(storedSiteIDs ?? [])
    let storedSearchSiteIDs = backendUserDefaults.stringArray(forKey: "selectedSearchSiteIDs")
    hasStoredSearchSiteSelection = storedSearchSiteIDs != nil
    selectedSearchSiteIDs = Set(storedSearchSiteIDs ?? storedSiteIDs ?? [])
    let storedBackendURL = backendUserDefaults.string(forKey: "backendURL") ?? Self.defaultBackendURL
    let normalizedBackendURL = (try? BackendEndpoint.normalizedString(storedBackendURL)) ?? Self.defaultBackendURL
    backendURL = normalizedBackendURL
    backendURLDraft = normalizedBackendURL
    backendUserDefaults.set(normalizedBackendURL, forKey: "backendURL")
    #if os(macOS)
      let defaultLibraryRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Anime Library", isDirectory: true)
        .path
    #else
      let defaultLibraryRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Anime Library", isDirectory: true)
        .path
    #endif
    libraryRoot = UserDefaults.standard.string(forKey: "libraryRoot") ?? defaultLibraryRoot
    if backendUserDefaults.object(forKey: "searchDeduplicate") == nil {
      searchDeduplicate = true
    } else {
      searchDeduplicate = backendUserDefaults.bool(forKey: "searchDeduplicate")
    }
    searchPaginationEnabled = backendUserDefaults.object(forKey: "searchPaginationEnabled") == nil
      ? false
      : backendUserDefaults.bool(forKey: "searchPaginationEnabled")
  }

  var client: APIClient {
    #if DEBUG
    if let fixtureClient { return fixtureClient }
    #endif
    return APIClient(baseURL: backendURL)
  }

  func loadOverview(silent: Bool = false) async {
    let requestID = overviewLoadSequence.begin()
    let endpoint = backendURL
    let requestClient = client
    if silent {
      do {
        let result = try await requestClient.overview()
        guard backendURL == endpoint, overviewLoadSequence.accepts(requestID) else { return }
        overview = result
      } catch {
        guard backendURL == endpoint, overviewLoadSequence.accepts(requestID) else { return }
        appendLog("刷新概览失败：\(error.localizedDescription)")
      }
      return
    }
    await run("加载概览", successDetail: { self.overviewSummaryText }) {
      let result = try await requestClient.overview()
      guard backendURL == endpoint, overviewLoadSequence.accepts(requestID) else { return }
      overview = result
    }
  }

  private var overviewSummaryText: String {
    guard let overview else { return "概览已更新" }
    let issues = overview.issues.count
    let pending = overview.pendingOrganizeItems.count
    if issues == 0 && pending == 0 {
      return "一切正常"
    }
    return "需要处理 \(issues) 个，待整理 \(pending) 个"
  }

  func bootstrap() async {
    guard !isBootstrapping else { return }
    isBootstrapping = true
    defer { isBootstrapping = false }

    await checkHealth()
    await loadSites()
    await loadDownloaderSettings()
    await loadSettings()
    await loadEpisodeRuleSettings()
    await loadOrganizeTargets()
    await loadSubscriptions()
    await loadSchedulerStatus()
    await loadBrush(silent: true)
    await loadHistory(silent: true)
    await loadMetadataBindings()
    await loadPlexMappings()
    await loadOrganizePreviews()
    await loadOrganizeHistory()
    await loadOverview()
  }

  func checkHealth() async {
    backendLastCheckedAt = Date()
    let normalizedURL: String
    do {
      normalizedURL = try BackendEndpoint.normalizedString(backendURLDraft)
    } catch {
      healthText = "后端地址无效"
      backendConnectionDetail = error.localizedDescription
      setStatus(.failed, title: "检测后端失败", detail: error.localizedDescription)
      return
    }
    let candidateClient = APIClient(baseURL: normalizedURL)

    let succeeded = await run(
      "检测后端",
      loadingDetail: "正在请求 \(normalizedURL)/health",
      successTitle: "后端连接正常",
      successDetail: { self.healthText }
    ) {
      let health = try await candidateClient.health()
      let nextHealthText = try BackendHealthPresentation.statusText(health: health, connectedURL: normalizedURL)
      let databaseText = health.databaseStatus == "ok" ? "数据库正常" : "数据库异常"
      let qbText = health.qbittorrentConfigured == true ? "qBittorrent 已配置" : "qBittorrent 未配置"
      let transmissionText = health.transmissionConfigured == true ? "Transmission 已配置" : "Transmission 未配置"
      let pidText = health.pid.map { "PID \($0)" } ?? "PID 未知"
      try commitConnectedBackendURL(normalizedURL)
      healthText = nextHealthText
      backendConnectionDetail = "\(databaseText) · \(qbText) · \(transmissionText) · \(pidText)"
    }
    if !succeeded {
      healthText = "后端连接失败"
      backendConnectionDetail = operationStatus.detail
    }
  }

  func commitConnectedBackendURL(_ rawValue: String) throws {
    let normalizedURL = try BackendEndpoint.normalizedString(rawValue)
    if normalizedURL != backendURL {
      subscriptionListFilter = .all
      schedulerStatus = nil
      pendingMetadataRecognitionSubscriptionID = nil
      pendingMetadataRecognitionBackendURL = nil
    }
    backendURL = normalizedURL
    _ = overviewLoadSequence.begin()
    overview = nil
    backendURLDraft = normalizedURL
    backendUserDefaults.set(normalizedURL, forKey: "backendURL")
  }

  func resetBackendURLToDefault() {
    _ = overviewLoadSequence.begin()
    if backendURL != Self.defaultBackendURL {
      subscriptionListFilter = .all
      schedulerStatus = nil
      pendingMetadataRecognitionSubscriptionID = nil
      pendingMetadataRecognitionBackendURL = nil
    }
    backendURL = Self.defaultBackendURL
    overview = nil
    backendURLDraft = Self.defaultBackendURL
    backendUserDefaults.set(Self.defaultBackendURL, forKey: "backendURL")
    healthText = "已恢复默认后端地址"
    backendConnectionDetail = "默认地址已设为 127.0.0.1:8000。若仍无法连接，请在项目目录运行 ./script/start_backend.sh。"
    backendLastCheckedAt = Date()
  }

  func loadSites() async {
    await run("加载站点", successDetail: { "已加载 \(self.sites.count) 个站点" }) {
      sites = try await client.sites()
      sitesLoaded = true
      let availableIDs = contentSiteIDs
      if !hadStoredSiteSelection || selectedSiteIDs.isEmpty {
        selectedSiteIDs = availableIDs
      } else {
        let validSelection = selectedSiteIDs.intersection(availableIDs)
        selectedSiteIDs = validSelection.isEmpty ? availableIDs : validSelection
      }
      reconcileSearchSiteSelection()
    }
  }

  func loadQbittorrentConfig() async {
    await run("读取 qBittorrent 配置") {
      qbittorrent = try await client.loadQbittorrentConfig()
      qBittorrentGlobalLimits = (try? await client.qBittorrentGlobalLimits()) ?? qBittorrentGlobalLimits
    }
  }

  func loadDownloaderSettings() async {
    await run("读取下载器设置") {
      async let qbConfig = client.loadQbittorrentConfig()
      async let transmissionConfig = client.loadTransmissionConfig()
      async let routingResponse = client.downloaderRouting()
      qbittorrent = try await qbConfig
      transmission = try await transmissionConfig
      let routing = try await routingResponse
      downloaderRouting = DownloaderRoutingSettings(
        subscriptionDownloader: routing.subscriptionDownloader,
        brushDownloader: routing.brushDownloader,
        manualDownloader: routing.manualDownloader
      )
      downloaderStatuses = routing.statuses
      qBittorrentGlobalLimits = (try? await client.qBittorrentGlobalLimits()) ?? qBittorrentGlobalLimits
      transmissionGlobalLimits = (try? await client.transmissionGlobalLimits()) ?? transmissionGlobalLimits
      applyDownloaderStatuses()
    }
  }

  private func applyDownloaderStatuses() {
    if let status = downloaderStatuses.first(where: { $0.downloader == "qbittorrent" }) {
      qbittorrentConnectionSucceeded = status.verified
      qbittorrentConnectionText = status.message
      qbittorrentVersionText = status.version ?? "未检测"
      qbittorrentLastTestedAt = status.checkedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    if let status = downloaderStatuses.first(where: { $0.downloader == "transmission" }) {
      transmissionConnectionSucceeded = status.verified
      transmissionConnectionText = status.message
      transmissionVersionText = status.version ?? "未检测"
      transmissionLastTestedAt = status.checkedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
  }

  func loadQBittorrentGlobalLimits() async {
    await run("读取 qBittorrent 全局限速") {
      qBittorrentGlobalLimits = try await client.qBittorrentGlobalLimits()
    }
  }

  func saveQBittorrentGlobalLimits(_ limits: QbittorrentGlobalLimits) async {
    await run("保存 qBittorrent 全局限速", successTitle: "全局限速已更新") {
      qBittorrentGlobalLimits = try await client.saveQBittorrentGlobalLimits(limits)
      appendLog("qBittorrent 全局上传、下载限速已更新。")
    }
  }

  func loadTransmissionGlobalLimits() async {
    await run("读取 Transmission 全局限速") {
      transmissionGlobalLimits = try await client.transmissionGlobalLimits()
    }
  }

  func saveTransmissionGlobalLimits(_ limits: QbittorrentGlobalLimits) async {
    await run("保存 Transmission 全局限速", successTitle: "Transmission 全局限速已更新") {
      transmissionGlobalLimits = try await client.saveTransmissionGlobalLimits(limits)
      appendLog("Transmission 全局上传、下载限速已更新。")
    }
  }

  func saveQbittorrentConfig() async {
    await run("保存 qBittorrent 配置", successTitle: "qBittorrent 配置已保存") {
      qbittorrent = try await client.saveQbittorrentConfig(qbittorrent)
      qbittorrentConnectionSucceeded = false
      qbittorrentConnectionText = "已配置，尚未测试"
      qbittorrentVersionText = "未检测"
      qbittorrentLastTestedAt = nil
      updateDownloaderStatus(
        downloader: "qbittorrent",
        configured: true,
        verified: false,
        version: nil,
        checkedAt: nil,
        message: qbittorrentConnectionText
      )
      appendLog("qBittorrent 配置已保存。")
    }
  }

  func saveTransmissionConfig() async {
    await run("保存 Transmission 配置", successTitle: "Transmission 配置已保存") {
      transmission = try await client.saveTransmissionConfig(transmission)
      transmissionConnectionSucceeded = false
      transmissionConnectionText = "已配置，尚未测试"
      transmissionVersionText = "未检测"
      transmissionLastTestedAt = nil
      updateDownloaderStatus(
        downloader: "transmission",
        configured: true,
        verified: false,
        version: nil,
        checkedAt: nil,
        message: transmissionConnectionText
      )
      appendLog("Transmission 配置已保存。")
    }
  }

  func saveDownloaderRouting() async {
    await run("保存下载器用途", successTitle: "下载器用途已保存") {
      let response = try await client.saveDownloaderRouting(downloaderRouting)
      downloaderStatuses = response.statuses
      applyDownloaderStatuses()
    }
  }

  func testQbittorrent() async {
    await run(
      "测试 qBittorrent",
      loadingDetail: "正在连接 \(qbittorrent.baseUrl)",
      successTitle: "qBittorrent 连接成功",
      successDetail: { "版本：\(self.qbittorrentVersionText)" }
    ) {
      if !(await performQbittorrentConnectionTest()) {
        throw AppStoreError.userFacing(qbittorrentConnectionText)
      }
    }
  }

  func testTransmission() async {
    await run(
      "测试 Transmission",
      loadingDetail: "正在连接 \(transmission.baseUrl)",
      successTitle: "Transmission 连接成功",
      successDetail: { "版本：\(self.transmissionVersionText)" }
    ) {
      if !(await performTransmissionConnectionTest()) {
        throw AppStoreError.userFacing(transmissionConnectionText)
      }
    }
  }

  func testAllDownloaders() async {
    guard !isTestingAllDownloaders else { return }
    let qbConfigured = downloaderStatuses.first { $0.downloader == "qbittorrent" }?.configured == true
    let transmissionConfigured = downloaderStatuses.first { $0.downloader == "transmission" }?.configured == true
    let configuredCount = [qbConfigured, transmissionConfigured].filter { $0 }.count
    guard configuredCount > 0 else {
      setStatus(.empty, title: "尚未配置下载器", detail: "请先完成至少一个下载器的配置。")
      return
    }

    let operationID = operationSequence.begin()
    isTestingAllDownloaders = true
    beginOperation(operationID, label: "测试全部下载器", detail: "正在依次检查已配置的下载器。")
    defer {
      isTestingAllDownloaders = false
      endOperation(operationID)
    }

    var successCount = 0
    if qbConfigured, await performQbittorrentConnectionTest() {
      successCount += 1
    }
    if transmissionConfigured, await performTransmissionConnectionTest() {
      successCount += 1
    }
    let failedCount = configuredCount - successCount
    guard operationSequence.accepts(operationID) else { return }
    if failedCount == 0 {
      setStatus(.success, title: "下载器连接正常", detail: "已测试 \(successCount) 个下载器。")
    } else {
      setStatus(
        .failed,
        title: "下载器连接测试已完成",
        detail: "\(successCount) 个成功，\(failedCount) 个失败。"
      )
    }
  }

  private func performQbittorrentConnectionTest() async -> Bool {
    qbittorrentConnectionText = "正在测试"
    qbittorrentConnectionSucceeded = false
    do {
      let response = try await client.testQbittorrent(qbittorrent)
      qbittorrentLastTestedAt = Date()
      qbittorrentConnectionText = response.message
      guard response.ok else {
        updateDownloaderStatus(
          downloader: "qbittorrent",
          configured: true,
          verified: false,
          version: nil,
          checkedAt: qbittorrentLastTestedAt,
          message: qbittorrentConnectionText
        )
        appendLog(response.message)
        return false
      }
      qbittorrentVersionText = response.version ?? "未知"
      qbittorrentConnectionSucceeded = true
      updateDownloaderStatus(
        downloader: "qbittorrent",
        configured: true,
        verified: true,
        version: qbittorrentVersionText,
        checkedAt: qbittorrentLastTestedAt,
        message: qbittorrentConnectionText
      )
      appendLog("\(response.message)：\(qbittorrentVersionText)")
      return true
    } catch {
      qbittorrentLastTestedAt = Date()
      qbittorrentConnectionText = error.localizedDescription
      updateDownloaderStatus(
        downloader: "qbittorrent",
        configured: true,
        verified: false,
        version: nil,
        checkedAt: qbittorrentLastTestedAt,
        message: qbittorrentConnectionText
      )
      appendLog("qBittorrent 连接失败：\(error.localizedDescription)")
      return false
    }
  }

  private func performTransmissionConnectionTest() async -> Bool {
    transmissionConnectionText = "正在测试"
    transmissionConnectionSucceeded = false
    do {
      let response = try await client.testTransmission(transmission)
      transmissionLastTestedAt = Date()
      transmissionConnectionText = response.message
      guard response.ok else {
        updateDownloaderStatus(
          downloader: "transmission",
          configured: true,
          verified: false,
          version: nil,
          checkedAt: transmissionLastTestedAt,
          message: transmissionConnectionText
        )
        appendLog(response.message)
        return false
      }
      transmissionVersionText = response.version ?? "未知"
      transmissionConnectionSucceeded = true
      updateDownloaderStatus(
        downloader: "transmission",
        configured: true,
        verified: true,
        version: transmissionVersionText,
        checkedAt: transmissionLastTestedAt,
        message: transmissionConnectionText
      )
      appendLog("\(response.message)：\(transmissionVersionText)")
      return true
    } catch {
      transmissionLastTestedAt = Date()
      transmissionConnectionText = error.localizedDescription
      updateDownloaderStatus(
        downloader: "transmission",
        configured: true,
        verified: false,
        version: nil,
        checkedAt: transmissionLastTestedAt,
        message: transmissionConnectionText
      )
      appendLog("Transmission 连接失败：\(error.localizedDescription)")
      return false
    }
  }

  private func updateDownloaderStatus(
    downloader: String,
    configured: Bool,
    verified: Bool,
    version: String?,
    checkedAt: Date?,
    message: String
  ) {
    let status = DownloaderStatus(
      downloader: downloader,
      configured: configured,
      verified: verified,
      version: version,
      checkedAt: checkedAt.map { ISO8601DateFormatter().string(from: $0) },
      message: message
    )
    if let index = downloaderStatuses.firstIndex(where: { $0.downloader == downloader }) {
      downloaderStatuses[index] = status
    } else {
      downloaderStatuses.append(status)
    }
  }

  func loadSettings() async {
    await run("读取应用设置") {
      let settings = try await client.settings()
      metadataSettings = settings.metadata
      notificationSettings = try await client.notificationSettings()
      aiSettings = try await client.aiSettings()
      searchSettings = try await client.searchSettings()
      syncNotificationFormFromSettings()
      syncAIFormFromSettings()
      organizePolicy = settings.organizePolicy
      normalizeOrganizePolicy()
      subscriptionAutoOrganize = organizePolicy.autoOrganizeByDefault
      subscriptionDeleteTaskAfterOrganize = organizePolicy.deleteTaskAfterOrganize
      subscriptionDeleteFilesAfterOrganize = organizePolicy.deleteFilesAfterOrganize
      subscriptionKeepSeeding = organizePolicy.keepSeeding
    }
  }

  func saveSearchSettings() async {
    searchSettings.siteTimeoutSeconds = min(60, max(3, searchSettings.siteTimeoutSeconds))
    await run("保存搜索设置", successTitle: "搜索设置已保存") {
      searchSettings = try await client.saveSearchSettings(searchSettings)
      appendLog("搜索设置已保存：单站点超时 \(Int(searchSettings.siteTimeoutSeconds)) 秒。")
    }
  }

  func loadMikanProjectSeason(silent: Bool = false) async {
    let startsRequest = !mikanProjectSeasonLoad.isRunning
    if startsRequest {
      mikanProjectSeasonLoading = true
      mikanProjectSeasonError = nil
    }

    let requestClient = client
    await mikanProjectSeasonLoad.run { [weak self] in
      guard let self else { return }
      await self.performMikanProjectSeasonRequest(
        silent: silent,
        fetch: { try await requestClient.mikanProjectSeason() }
      )
    }
    if !mikanProjectSeasonLoad.isRunning {
      mikanProjectSeasonLoading = false
    }
  }

  func startMikanProjectSeasonLoad(silent: Bool = false) {
    Task { [weak self] in
      await self?.loadMikanProjectSeason(silent: silent)
    }
  }

  func refreshMikanProjectSeason() async {
    let startsRequest = !mikanProjectSeasonLoad.isRunning
    if startsRequest {
      mikanProjectSeasonLoading = true
      mikanProjectSeasonError = nil
    }

    let requestClient = client
    await mikanProjectSeasonLoad.run { [weak self] in
      guard let self else { return }
      await self.performMikanProjectSeasonRequest(
        silent: false,
        fetch: { try await requestClient.refreshMikanProjectSeason() }
      )
    }
    if !mikanProjectSeasonLoad.isRunning {
      mikanProjectSeasonLoading = false
    }
  }

  func startMikanProjectSeasonRefresh() {
    Task { [weak self] in
      await self?.refreshMikanProjectSeason()
    }
  }

  private func performMikanProjectSeasonRequest(
    silent: Bool,
    fetch: @escaping @MainActor @Sendable () async throws -> MikanProjectSeasonResponse
  ) async {
    do {
      let response = try await fetch()
      mikanProjectSeason = response
      mikanProjectSettings = response.settings
      mikanProjectSeasonError = nil
      if !silent {
        response.warnings.forEach { appendLog($0) }
      }
    } catch where APIClient.isCancellation(error) {
      return
    } catch {
      let message = error.localizedDescription
      mikanProjectSeasonError = message
      appendLog("加载 Mikan Project 失败：\(message)")
    }
  }

  func saveMikanProjectSettings() async {
    mikanProjectSettings.refreshIntervalHours = min(168, max(1, mikanProjectSettings.refreshIntervalHours))
    await run("保存 Mikan Project 设置", successTitle: "刷新设置已保存") {
      mikanProjectSettings = try await client.saveMikanProjectSettings(mikanProjectSettings)
    }
  }

  func loadMikanProjectResources(for anime: MikanProjectAnime) async {
    mikanProjectResourceLoadingIDs.insert(anime.bangumiId)
    defer { mikanProjectResourceLoadingIDs.remove(anime.bangumiId) }
    do {
      let response = try await client.mikanProjectResources(bangumiID: anime.bangumiId)
      mikanProjectResources[anime.bangumiId] = response
      response.warnings.forEach { appendLog($0) }
    } catch where APIClient.isCancellation(error) {
      return
    } catch {
      setStatus(.failed, title: "资源加载失败", detail: error.localizedDescription)
      appendLog("Mikan Project 资源加载失败：\(error.localizedDescription)")
    }
  }

  @discardableResult
  func saveMetadataSettings() async -> Bool {
    let key = tmdbAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    let succeeded = await run("保存 TMDB API Key", successTitle: "TMDB API Key 已保存") {
      metadataSettings = try await client.saveMetadataSettings(tmdbApiKey: key.isEmpty ? nil : key)
      if !key.isEmpty {
        tmdbAPIKeyInput = ""
      }
      appendLog(metadataSettings.message)
    }
    return succeeded
  }

  @discardableResult
  func clearTMDBSettings() async -> Bool {
    let succeeded = await run("清除 TMDB API Key", successTitle: "TMDB API Key 已清除") {
      metadataSettings = try await client.clearTMDBSettings()
      tmdbAPIKeyInput = ""
      tmdbTestText = "未检测"
    }
    return succeeded
  }

  func testTMDBSettings() async {
    let key = tmdbAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    await run("测试 TMDB", successTitle: "TMDB 检测完成", successDetail: { self.tmdbTestText }) {
      let response = try await client.testTMDB(tmdbApiKey: key.isEmpty ? nil : key)
      if !response.ok {
        throw AppStoreError.userFacing(response.message)
      }
      tmdbTestText = response.message
      appendLog(response.message)
    }
  }

  @discardableResult
  func saveNotificationSettings() async -> Bool {
    let hadInputKey = !barkDeviceKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let succeeded = await run("保存通知设置", successTitle: "通知设置已保存", successDetail: { self.notificationSettings.message }) {
      do {
        notificationSettings = try await client.saveNotificationSettings(currentNotificationSettingsPayload(clearKey: false))
        if hadInputKey {
          barkDeviceKeyInput = ""
        }
        syncNotificationFormFromSettings()
        appendLog(notificationSettings.message)
      } catch APIClientError.server(let status, _) where status == 404 {
        appendLog("保存通知设置失败：PUT api/settings/notifications 返回 404。")
        throw AppStoreError.userFacing("保存通知设置失败：接口不存在（404），请确认后端已更新并重启。")
      } catch {
        throw AppStoreError.userFacing("保存通知设置失败：\(error.localizedDescription)")
      }
    }
    return succeeded
  }

  @discardableResult
  func clearBarkDeviceKey() async -> Bool {
    let succeeded = await run("清除 Bark Device Key", successTitle: "Bark Device Key 已清除") {
      notificationSettings = try await client.saveNotificationSettings(currentNotificationSettingsPayload(clearKey: true))
      barkDeviceKeyInput = ""
      notificationTestText = "未检测"
      syncNotificationFormFromSettings()
    }
    return succeeded
  }

  func testNotificationSettings() async {
    await run("发送测试通知", successTitle: "测试通知已发送", successDetail: { self.notificationTestText }) {
      let response: NotificationTestResponse
      do {
        response = try await client.testNotification(NotificationTestRequest(provider: "bark", title: nil, body: nil))
      } catch APIClientError.server(let status, _) where status == 404 {
        throw AppStoreError.userFacing("测试通知失败：接口不存在（404），请确认后端已更新并重启。")
      }
      notificationTestText = response.message
      if !response.ok {
        throw AppStoreError.userFacing(response.message)
      }
      appendLog(response.message)
    }
  }

  @discardableResult
  func saveAISettings() async -> Bool {
    let hadInputKey = !aiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let succeeded = await run("保存 AI 辅助分析设置", successTitle: "AI 辅助分析设置已保存", successDetail: { self.aiSettings.message }) {
      aiSettings = try await client.saveAISettings(currentAISettingsPayload())
      syncAIFormFromSettings()
      if hadInputKey {
        aiAPIKeyInput = ""
      }
      appendLog(aiSettings.message)
    }
    return succeeded
  }

  func testAISettings() async {
    await run("测试 AI 辅助分析", successTitle: "AI 检测完成", successDetail: { self.aiTestText }) {
      let response = try await client.testAISettings(currentAISettingsPayload())
      if !response.ok {
        aiTestText = response.message
        throw AppStoreError.userFacing(response.message)
      }
      aiTestText = response.message
      appendLog(response.message)
    }
  }

  func switchAIProvider(from previousProvider: String, to provider: String) {
    guard previousProvider != provider else { return }
    if previousProvider != "none" {
      let previousProfile = aiSettings.providerProfiles?[previousProvider]
      aiProviderDrafts[previousProvider] = AIProviderDraft(
        baseURL: aiBaseURL,
        model: aiModel,
        apiKeyInput: aiAPIKeyInput,
        apiKeyConfigured: aiSettings.provider == previousProvider
          ? aiSettings.apiKeyConfigured
          : previousProfile?.apiKeyConfigured ?? false,
        apiKeyMasked: aiSettings.provider == previousProvider
          ? aiSettings.apiKeyMasked
          : previousProfile?.apiKeyMasked
      )
    }

    if provider == "none" {
      aiEnabled = false
      useAIForSmartSubscription = false
      aiBaseURL = ""
      aiModel = ""
      aiAPIKeyInput = ""
      aiModels = []
      aiSettings.provider = provider
      aiSettings.baseUrl = nil
      aiSettings.model = nil
      aiSettings.apiKeyConfigured = false
      aiSettings.apiKeyMasked = nil
      aiSettings.configured = false
      aiSettings.message = "未配置 AI，可在 设置 → AI 辅助分析 中配置"
      return
    }

    let savedProfile = aiSettings.providerProfiles?[provider]
    let draft = aiProviderDrafts[provider] ?? AIProviderDraft(
      baseURL: savedProfile?.baseUrl ?? AIProviderCatalog.defaultBaseURL(for: provider),
      model: savedProfile?.model ?? AIProviderCatalog.defaultModel(for: provider),
      apiKeyInput: "",
      apiKeyConfigured: savedProfile?.apiKeyConfigured ?? false,
      apiKeyMasked: savedProfile?.apiKeyMasked
    )
    aiProviderDrafts[provider] = draft
    aiBaseURL = draft.baseURL
    aiModel = draft.model
    aiAPIKeyInput = draft.apiKeyInput
    aiModels = []
    aiModelListText = "未获取"
    aiSettings.provider = provider
    aiSettings.baseUrl = nilIfEmpty(draft.baseURL)
    aiSettings.model = nilIfEmpty(draft.model)
    aiSettings.apiKeyConfigured = draft.apiKeyConfigured
    aiSettings.apiKeyMasked = draft.apiKeyMasked
    aiSettings.configured = aiEnabled
      && draft.apiKeyConfigured
      && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    aiSettings.message = aiSettings.configured
      ? "\(AIProviderCatalog.title(for: provider)) 已配置"
      : "请配置 \(AIProviderCatalog.title(for: provider))"
    if !aiSettings.configured {
      useAIForSmartSubscription = false
    }
  }

  func loadAIModels() async {
    await run("获取 AI 模型列表", successTitle: "AI 模型列表已更新", successDetail: { self.aiModelListText }) {
      let key = aiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
      let response = try await client.listAIModels(
        AIModelListRequest(
          provider: aiProvider,
          baseUrl: aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
          apiKey: key.isEmpty ? nil : key,
          selectedModel: aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      )
      aiModels = response.models
      aiModelListText = response.message
      if let selected = response.selectedModel, !selected.isEmpty {
        aiModel = selected
      }
      if !response.ok {
        throw AppStoreError.userFacing(response.message)
      }
    }
  }

  func analyzeTitleWithAI(_ title: String, suggestedRule: Bool = false) async -> AITitleAnalysisResponse? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      setStatus(.empty, title: "无法分析标题", detail: "请先输入资源标题。")
      return nil
    }
    guard aiSettings.configured else {
      let response = AITitleAnalysisResponse(
        ok: false,
        message: "未配置 AI，可在 设置 → AI 辅助分析 中配置",
        rawTitle: trimmed,
        fansub: nil,
        animeTitle: nil,
        animeTitleOriginal: nil,
        animeTitleAliases: [],
        episodeNumber: nil,
        episodeStart: nil,
        episodeEnd: nil,
        isBatch: false,
        isFinal: nil,
        finalConfidence: 0,
        resolution: nil,
        subtitleLanguage: nil,
        sourceTags: [],
        formatTags: [],
        releaseGroup: nil,
        confidence: 0,
        reason: nil,
        suggestedRegex: nil,
        warnings: [],
        requiresConfirmation: true
      )
      lastAIAnalysis = response
      setStatus(.empty, title: "未配置 AI", detail: response.message)
      return response
    }
    var output: AITitleAnalysisResponse?
    let operation = suggestedRule ? "AI 生成规则草稿" : "AI 解析标题"
    let successTitle = suggestedRule ? "AI 规则草稿已生成" : "AI 标题解析完成"
    let succeeded = await run(operation, successTitle: successTitle, successDetail: { self.lastAIAnalysis?.message ?? "" }) {
      let request = AITitleAnalyzeRequest(title: trimmed, subscriptionName: nil, aliases: [], site: nil, localParse: nil)
      output = try await (suggestedRule ? client.suggestEpisodeRuleAI(request) : client.analyzeTitleAI(request))
      lastAIAnalysis = output
      if let output, !output.ok {
        let detail = output.warnings.first.map { "：\($0)" } ?? ""
        throw AppStoreError.userFacing("\(output.message)\(detail)")
      }
    }
    return succeeded ? output : lastAIAnalysis
  }

  private func currentAISettingsPayload() -> AISettings {
    let key = aiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    return AISettings(
      enabled: aiEnabled,
      provider: aiProvider,
      baseUrl: aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : aiModel.trimmingCharacters(in: .whitespacesAndNewlines),
      apiKey: key.isEmpty ? nil : key,
      useAiForSmartSubscription: useAIForSmartSubscription,
      clearApiKey: false
    )
  }

  private func currentNotificationSettingsPayload(clearKey: Bool) -> NotificationSettings {
    let key = barkDeviceKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    return NotificationSettings(
      enabled: notificationsEnabled,
      bark: BarkNotificationSettings(
        enabled: barkEnabled,
        serverUrl: barkServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "https://api.day.app" : barkServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
        deviceKey: key.isEmpty ? nil : key,
        clearDeviceKey: clearKey,
        group: barkGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Kisetsu" : barkGroup.trimmingCharacters(in: .whitespacesAndNewlines),
        sound: nilIfEmpty(barkSound),
        icon: nilIfEmpty(barkIcon),
        level: barkLevel,
        url: nilIfEmpty(barkURL),
        autoCopy: barkAutoCopy
      ),
      events: NotificationEventSettings(subscription: notifySubscription, download: notifyDownload, organize: notifyOrganize),
      showFullPaths: false
    )
  }

  private func syncNotificationFormFromSettings() {
    notificationsEnabled = notificationSettings.enabled
    barkEnabled = notificationSettings.bark.enabled
    barkServerURL = notificationSettings.bark.serverUrl
    barkGroup = notificationSettings.bark.group
    barkSound = notificationSettings.bark.sound ?? ""
    barkIcon = notificationSettings.bark.icon ?? ""
    barkLevel = notificationSettings.bark.level
    barkURL = notificationSettings.bark.url ?? ""
    barkAutoCopy = notificationSettings.bark.autoCopy
    notifySubscription = notificationSettings.events.subscription
    notifyDownload = notificationSettings.events.download
    notifyOrganize = notificationSettings.events.organize
  }

  @discardableResult
  func clearAIAPIKey() async -> Bool {
    let succeeded = await run("清除 AI API Key", successTitle: "AI API Key 已清除") {
      let payload = AISettings(
        enabled: aiEnabled,
        provider: aiProvider,
        baseUrl: aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
        model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : aiModel.trimmingCharacters(in: .whitespacesAndNewlines),
        apiKey: nil,
        useAiForSmartSubscription: false,
        clearApiKey: true
      )
      aiSettings = try await client.saveAISettings(payload)
      aiAPIKeyInput = ""
      syncAIFormFromSettings()
    }
    return succeeded
  }

  private func syncAIFormFromSettings() {
    aiProviderDrafts = (aiSettings.providerProfiles ?? [:]).mapValues { profile in
      AIProviderDraft(
        baseURL: profile.baseUrl ?? "",
        model: profile.model ?? "",
        apiKeyInput: "",
        apiKeyConfigured: profile.apiKeyConfigured,
        apiKeyMasked: profile.apiKeyMasked
      )
    }
    aiEnabled = aiSettings.enabled
    aiProvider = aiSettings.provider
    aiBaseURL = aiSettings.baseUrl ?? AIProviderCatalog.defaultBaseURL(for: aiSettings.provider)
    aiModel = aiSettings.model ?? AIProviderCatalog.defaultModel(for: aiSettings.provider)
    useAIForSmartSubscription = aiSettings.useAiForSmartSubscription
  }

  func saveOrganizePolicy() async {
    normalizeOrganizePolicy()
    await run("保存整理策略", successTitle: "整理策略已保存") {
      organizePolicy = try await client.saveOrganizePolicy(organizePolicy)
      normalizeOrganizePolicy()
      subscriptionAutoOrganize = organizePolicy.autoOrganizeByDefault
      subscriptionDeleteTaskAfterOrganize = organizePolicy.deleteTaskAfterOrganize
      subscriptionDeleteFilesAfterOrganize = organizePolicy.deleteFilesAfterOrganize
      subscriptionKeepSeeding = organizePolicy.keepSeeding
      appendLog("整理策略已保存。")
    }
  }

  func loadEpisodeRuleSettings() async {
    await run("读取集数识别规则") {
      let response = try await client.episodeRuleSettings()
      builtinEpisodeParseRules = response.builtinRules.sorted { $0.priority < $1.priority }
      globalEpisodeParseRules = response.userRules.sorted { $0.priority < $1.priority }
    }
  }

  func saveGlobalEpisodeRules() async {
    await run("保存全局集数规则", successTitle: "集数规则已保存", successDetail: { "\(self.globalEpisodeParseRules.count) 条自定义规则" }) {
      let response = try await client.saveEpisodeRuleSettings(normalizedGlobalEpisodeParseRules())
      builtinEpisodeParseRules = response.builtinRules.sorted { $0.priority < $1.priority }
      globalEpisodeParseRules = response.userRules.sorted { $0.priority < $1.priority }
      appendLog("全局集数识别规则已保存。")
    }
  }

  func addGlobalEpisodeParseRule(template: String) {
    globalEpisodeParseRules.append(makeEpisodeParseRule(template: template, priority: globalEpisodeParseRules.count))
  }

  func removeGlobalEpisodeParseRule(_ rule: EpisodeParseRule) {
    globalEpisodeParseRules.removeAll { $0.id == rule.id }
    globalEpisodeParseRules = normalizedGlobalEpisodeParseRules()
  }

  func moveGlobalEpisodeParseRule(_ rule: EpisodeParseRule, direction: Int) {
    guard let index = globalEpisodeParseRules.firstIndex(where: { $0.id == rule.id }) else { return }
    let target = index + direction
    guard globalEpisodeParseRules.indices.contains(target) else { return }
    globalEpisodeParseRules.swapAt(index, target)
    globalEpisodeParseRules = normalizedGlobalEpisodeParseRules()
  }

  @discardableResult
  func testGlobalEpisodeParseRules() async -> Bool {
    let title = globalEpisodeRuleTestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      setStatus(.empty, title: "无法测试集数识别", detail: "请先粘贴一个资源标题。")
      return false
    }
    return await run("测试全局集数识别", successTitle: "集数识别完成", successDetail: { self.lastGlobalEpisodeRuleTestResponse?.message ?? "" }) {
      lastGlobalEpisodeRuleTestResponse = try await client.testGlobalEpisodeRules(
        title: title,
        episodeParseRules: normalizedGlobalEpisodeParseRules()
      )
    }
  }

  @discardableResult
  func addSiteTemplate(_ siteID: String) async -> Bool {
    let normalizedID = siteID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return await run("添加资源站点", successTitle: "站点已启用", successDetail: { normalizedID.uppercased() }) {
      let updated = try await client.createSite(siteID: normalizedID)
      updateSite(updated)
      appendLog("资源站点已启用：\(updated.label)。")
    }
  }

  @discardableResult
  func saveSite(_ site: SiteInfo) async -> Bool {
    guard let payload = siteSettingsPayload(for: site, failureTitle: "无法保存资源站点") else {
      return false
    }
    let succeeded = await run("保存资源站点", successTitle: "站点设置已保存", successDetail: { site.label }) {
      let updated = try await client.saveSiteSettings(siteID: site.id, settings: payload)
      updateSite(updated)
      appendLog("资源站点已保存：\(updated.label)。")
    }
    return succeeded
  }

  private func siteSettingsPayload(for site: SiteInfo, failureTitle: String) -> SiteSettingsUpdate? {
    return SiteSettingsUpdate(
      displayName: site.displayName,
      primaryUrl: site.primaryUrl ?? site.baseUrl,
      mirrors: site.mirrors,
      activeBaseUrl: site.activeBaseUrl ?? site.baseUrl,
      enabled: site.enabled ?? true,
      brushOnly: site.brushOnly ?? false,
      apiKey: nilIfEmpty(site.apiKey ?? ""),
      clearApiKey: site.clearApiKey ?? false,
      cookie: nilIfEmpty(site.cookie ?? ""),
      clearCookie: site.clearCookie ?? false,
      passkey: nilIfEmpty(site.passkey ?? ""),
      clearPasskey: site.clearPasskey ?? false,
      authorization: nilIfEmpty(site.authorization ?? ""),
      clearAuthorization: site.clearAuthorization ?? false,
      userAgent: nilIfEmpty(site.userAgent ?? ""),
      timeoutSeconds: site.timeoutSeconds,
      rssUrl: nilIfEmpty(site.rssUrl ?? ""),
      clearRssUrl: site.clearRssUrl ?? false,
      requestHeaders: nil,
      clearRequestHeaders: site.clearRequestHeaders ?? false
    )
  }

  @discardableResult
  func deleteSite(_ site: SiteInfo) async -> Bool {
    let succeeded = await run("移除资源站点", successTitle: "站点已移除", successDetail: { site.label }) {
      sites = try await client.deleteSite(siteID: site.id)
      reconcileSelectedSites()
      reconcileSearchSiteSelection()
      appendLog("资源站点已移除：\(site.label)。")
    }
    return succeeded
  }

  @discardableResult
  func addSiteMirror(_ site: SiteInfo) async -> Bool {
    let value = siteMirrorDrafts[site.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      setStatus(.empty, title: "无法添加镜像", detail: "请先填写镜像地址。")
      return false
    }
    guard isValidSiteURL(value) else {
      setStatus(.failed, title: "无法添加镜像", detail: "镜像地址格式不正确，请填写以 http:// 或 https:// 开头的完整地址。")
      return false
    }
    let succeeded = await run("添加站点镜像", successTitle: "镜像已添加", successDetail: { value }) {
      let updated = try await client.addSiteMirror(siteID: site.id, url: value)
      updateSite(updated)
      siteMirrorDrafts[site.id] = ""
      appendLog("已添加镜像：\(updated.label) \(value)。")
    }
    return succeeded
  }

  @discardableResult
  func deleteSiteMirror(_ site: SiteInfo, index: Int) async -> Bool {
    let succeeded = await run("删除站点镜像", successTitle: "镜像已删除") {
      let updated = try await client.deleteSiteMirror(siteID: site.id, index: index)
      updateSite(updated)
    }
    return succeeded
  }

  @discardableResult
  func selectSiteMirror(_ site: SiteInfo, url: String) async -> Bool {
    let succeeded = await run("切换站点镜像", successTitle: "当前使用的域名已更新", successDetail: { url }) {
      let updated = try await client.selectSiteMirror(siteID: site.id, url: url)
      updateSite(updated)
      appendLog("已切换 \(updated.label) 到 \(url)。")
    }
    return succeeded
  }

  func testSiteDomain(siteID: String, url: String) async throws -> SiteDomainTestResponse {
    try await client.testSiteDomain(siteID: siteID, url: url)
  }

  func previewSiteRSS(site: SiteInfo, keyword: String? = nil, category: String? = nil, page: Int = 1, pageSize: Int = 25) async throws -> RssTestResponse {
    guard let payload = siteSettingsPayload(for: site, failureTitle: "无法预览 RSS") else {
      throw AppStoreError.userFacing("站点设置格式不正确。")
    }
    return try await client.previewSiteRSS(siteID: site.id, url: site.rssUrl ?? "", settings: payload, keyword: nilIfEmpty(keyword ?? ""), category: nilIfEmpty(category ?? ""), page: page, pageSize: pageSize)
  }

  func backendResourceURL(_ value: String?) -> URL? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    if let absolute = URL(string: value), absolute.scheme != nil {
      return absolute
    }
    let root = backendURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = value.hasPrefix("/") ? String(value.dropFirst()) : value
    return URL(string: "\(root)/\(path)")
  }

  private func isValidSiteURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host?.isEmpty == false else {
      return false
    }
    return true
  }

  private func updateSite(_ site: SiteInfo) {
    if let index = sites.firstIndex(where: { $0.id == site.id }) {
      sites[index] = site
    } else {
      sites.append(site)
    }
    reconcileSelectedSites()
    reconcileSearchSiteSelection()
  }

  private func reconcileSelectedSites() {
    guard editingSubscriptionID == nil else { return }
    let availableIDs = contentSiteIDs
    selectedSiteIDs = selectedSiteIDs.intersection(availableIDs)
    if selectedSiteIDs.isEmpty {
      selectedSiteIDs = availableIDs
    }
  }

  func reconcileSearchSiteSelection() {
    let availableIDs = searchSiteIDs
    let validSelection = selectedSearchSiteIDs.intersection(availableIDs)
    if hasStoredSearchSiteSelection {
      selectedSearchSiteIDs = validSelection
    } else {
      selectedSearchSiteIDs = validSelection.isEmpty ? availableIDs : validSelection
    }
  }

  func selectAllSearchSites() {
    selectedSearchSiteIDs = searchSiteIDs
  }

  func clearSearchSites() {
    selectedSearchSiteIDs = []
  }

  func setSearchSite(_ siteID: String, selected: Bool) {
    guard searchSiteIDs.contains(siteID) else { return }
    if selected {
      selectedSearchSiteIDs.insert(siteID)
    } else {
      selectedSearchSiteIDs.remove(siteID)
    }
  }

  func setOrganizePolicyAction(_ action: String) {
    organizePolicy.postOrganizeAction = action
    applyOrganizePolicyAction(action, to: &organizePolicy)
  }

  func organizePolicyDescription(_ action: String) -> String {
    switch action {
    case "keep_seeding":
      return "继续做种：文件整理后，原下载器任务保留"
    case "remove_task_keep_files":
      return "移除任务：整理后从原下载器列表移除，但保留文件"
    case "remove_task_delete_files":
      return "移除任务和原文件：适合整理使用移动操作后清理残留"
    case "manual":
      return "手动处理：整理完成后不自动修改原下载器"
    default:
      return "使用全局默认整理策略"
    }
  }

  var subscriptionGlobalSeedingSummary: String {
    seedingPolicySummary(
      ratio: organizePolicy.seedingStopRatio,
      minutes: organizePolicy.seedingStopMinutes,
      mode: organizePolicy.seedingStopMode ?? "any",
      postAction: organizePolicy.postSeedingAction ?? "pause"
    )
  }

  var subscriptionCustomSeedingSummary: String {
    seedingPolicySummary(
      ratio: subscriptionSeedingRatioValue,
      minutes: subscriptionSeedingMinutesValue,
      mode: subscriptionSeedingStopMode,
      postAction: subscriptionPostSeedingAction
    )
  }

  var subscriptionSeedingValidationMessage: String? {
    guard subscriptionPostOrganizeAction == "keep_seeding", subscriptionSeedingPolicyMode == "custom" else {
      return nil
    }
    if subscriptionSeedingTimeEnabled && subscriptionSeedingMinutesValue == nil {
      return "请输入大于 0 的目标做种时间。"
    }
    if subscriptionSeedingRatioEnabled && subscriptionSeedingRatioValue == nil {
      return "请输入大于 0 的目标分享率。"
    }
    if !subscriptionSeedingTimeEnabled && !subscriptionSeedingRatioEnabled {
      return "当前订阅的自定义做种规则至少需要启用一个目标。"
    }
    return nil
  }

  var subscriptionIncludeKeywordValidationMessage: String? {
    SubscriptionKeywordExpression.validationMessage(subscriptionIncludeKeywords)
  }

  var subscriptionExcludeKeywordValidationMessage: String? {
    SubscriptionKeywordExpression.validationMessage(subscriptionExcludeKeywords)
  }

  var subscriptionSizeValidationMessage: String? {
    subscriptionSizeFilterDraft.validationMessage
  }

  var subscriptionSizeFilterDraft: SubscriptionSizeFilterDraft {
    SubscriptionSizeFilterDraft(
      minimumText: subscriptionMinSize,
      minimumUnit: subscriptionMinSizeUnit,
      maximumText: subscriptionMaxSize,
      maximumUnit: subscriptionMaxSizeUnit
    )
  }

  func setSubscriptionMinSizeUnit(_ unit: SubscriptionSizeUnit) {
    subscriptionMinSize = SubscriptionSizeFilterDraft.convertedText(
      subscriptionMinSize,
      from: subscriptionMinSizeUnit,
      to: unit
    )
    subscriptionMinSizeUnit = unit
  }

  func setSubscriptionMaxSizeUnit(_ unit: SubscriptionSizeUnit) {
    subscriptionMaxSize = SubscriptionSizeFilterDraft.convertedText(
      subscriptionMaxSize,
      from: subscriptionMaxSizeUnit,
      to: unit
    )
    subscriptionMaxSizeUnit = unit
  }

  private var subscriptionSeedingMinutesValue: Int? {
    guard subscriptionPostOrganizeAction == "keep_seeding",
          subscriptionSeedingPolicyMode == "custom",
          subscriptionSeedingTimeEnabled,
          let hours = Double(subscriptionSeedingHours.trimmingCharacters(in: .whitespacesAndNewlines)),
          hours.isFinite, hours > 0 else { return nil }
    return max(1, Int((hours * 60).rounded()))
  }

  private var subscriptionSeedingRatioValue: Double? {
    guard subscriptionPostOrganizeAction == "keep_seeding",
          subscriptionSeedingPolicyMode == "custom",
          subscriptionSeedingRatioEnabled,
          let percent = Double(subscriptionSeedingRatioPercent.trimmingCharacters(in: .whitespacesAndNewlines)),
          percent.isFinite, percent > 0 else { return nil }
    return percent / 100
  }

  private func applySubscriptionSeedingDraft(
    mode: String?,
    ratio: Double?,
    minutes: Int?,
    stopMode: String?,
    postAction: String?
  ) {
    subscriptionSeedingPolicyMode = mode == "custom" || ratio != nil || minutes != nil ? "custom" : "inherit"
    subscriptionSeedingTimeEnabled = minutes != nil
    subscriptionSeedingHours = minutes.map { compactNumber(Double($0) / 60) } ?? ""
    subscriptionSeedingRatioEnabled = ratio != nil
    subscriptionSeedingRatioPercent = ratio.map { compactNumber($0 * 100) } ?? ""
    subscriptionSeedingStopMode = stopMode ?? "any"
    subscriptionPostSeedingAction = postAction ?? "pause"
  }

  private func seedingPolicySummary(ratio: Double?, minutes: Int?, mode: String, postAction: String) -> String {
    var targets: [String] = []
    if let minutes {
      targets.append("做种 \(compactNumber(Double(minutes) / 60)) 小时")
    }
    if let ratio {
      targets.append("分享率达到 \(compactNumber(ratio * 100))%")
    }
    guard !targets.isEmpty else { return "持续做种，不自动处理" }
    let condition = targets.joined(separator: mode == "all" ? "且" : "或")
    return "\(condition)，达标后\(postSeedingActionLabel(postAction))"
  }

  private func postSeedingActionLabel(_ action: String) -> String {
    switch action {
    case "remove_task_keep_files": return "移除任务并保留文件"
    case "remove_task_delete_files": return "移除任务和下载数据"
    case "manual": return "等待手动处理"
    default: return "暂停任务"
    }
  }

  private func compactNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
  }

  private func normalizeOrganizePolicy() {
    let action = organizePolicy.postOrganizeAction ?? actionFromOrganizeFlags(organizePolicy)
    organizePolicy.postOrganizeAction = action
    if organizePolicy.seedingStopMode == nil {
      organizePolicy.seedingStopMode = "any"
    }
    if organizePolicy.postSeedingAction == nil {
      organizePolicy.postSeedingAction = "pause"
    }
    if organizePolicy.cleanEmptyDownloadDirs == nil {
      organizePolicy.cleanEmptyDownloadDirs = true
    }
    applyOrganizePolicyAction(action, to: &organizePolicy)
  }

  private func actionFromOrganizeFlags(_ policy: OrganizePolicySettings) -> String {
    if policy.keepSeeding {
      return "keep_seeding"
    }
    if policy.deleteTaskAfterOrganize && policy.deleteFilesAfterOrganize {
      return "remove_task_delete_files"
    }
    if policy.deleteTaskAfterOrganize {
      return "remove_task_keep_files"
    }
    return "manual"
  }

  private func applyOrganizePolicyAction(_ action: String, to policy: inout OrganizePolicySettings) {
    switch action {
    case "keep_seeding":
      policy.keepSeeding = true
      policy.deleteTaskAfterOrganize = false
      policy.deleteFilesAfterOrganize = false
    case "remove_task_delete_files":
      policy.keepSeeding = false
      policy.deleteTaskAfterOrganize = true
      policy.deleteFilesAfterOrganize = true
    case "manual":
      policy.keepSeeding = false
      policy.deleteTaskAfterOrganize = false
      policy.deleteFilesAfterOrganize = false
    default:
      policy.keepSeeding = false
      policy.deleteTaskAfterOrganize = true
      policy.deleteFilesAfterOrganize = false
      policy.postOrganizeAction = "remove_task_keep_files"
    }
  }

  var defaultOrganizeTarget: OrganizeTarget? {
    organizeTargets.first(where: { $0.enabled && $0.isDefault }) ??
      organizeTargets.first(where: \.enabled)
  }

  var previewOrganizeTarget: OrganizeTarget? {
    if let targetID = selectedSubscriptionDetail?.subscription.organizeTargetId,
       let target = organizeTargets.first(where: { $0.id == targetID && $0.enabled }) {
      return target
    }
    return defaultOrganizeTarget
  }

  @discardableResult
  func loadOrganizeTargets() async -> Bool {
    await run("加载整理目标", successDetail: { "\(self.organizeTargets.count) 个整理目标" }) {
      organizeTargets = try await client.organizeTargets()
      organizeTargetsLoaded = true
      if subscriptionOrganizeTargetID == nil {
        subscriptionOrganizeTargetID = defaultOrganizeTarget?.id
      }
    }
  }

  func ensureOrganizeTargetsLoaded() async -> Bool {
    if organizeTargetsLoaded || !organizeTargets.isEmpty {
      organizeTargetsLoaded = true
      return true
    }
    if let organizeTargetsLoadTask {
      return await organizeTargetsLoadTask.value
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      return await self.loadOrganizeTargets()
    }
    organizeTargetsLoadTask = task
    let succeeded = await task.value
    organizeTargetsLoadTask = nil
    return succeeded
  }

  @discardableResult
  func saveOrganizeTargetForm() async -> Bool {
    let name = organizeTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = organizeTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      setStatus(.empty, title: "无法保存整理目标", detail: "请填写显示名称。")
      return false
    }
    guard !path.isEmpty else {
      setStatus(.empty, title: "无法保存整理目标", detail: "请填写实际路径。")
      return false
    }
    let mediaType = organizeTargetMediaType.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload = OrganizeTargetCreate(
      name: name,
      path: path,
      mediaType: mediaType.isEmpty ? "anime" : mediaType,
      isDefault: organizeTargetIsDefault,
      enabled: organizeTargetEnabled
    )
    if let id = editingOrganizeTargetID {
      return await run("更新整理目标", successTitle: "整理目标已更新", successDetail: { name }) {
        _ = try await client.updateOrganizeTarget(id: id, payload)
        resetOrganizeTargetForm()
        await loadOrganizeTargets()
      }
    } else {
      return await run("添加整理目标", successTitle: "整理目标已添加", successDetail: { name }) {
        _ = try await client.createOrganizeTarget(payload)
        resetOrganizeTargetForm()
        await loadOrganizeTargets()
      }
    }
  }

  func editOrganizeTarget(_ target: OrganizeTarget) {
    editingOrganizeTargetID = target.id
    organizeTargetName = target.name
    organizeTargetPath = target.path
    organizeTargetMediaType = target.mediaType
    organizeTargetIsDefault = target.isDefault
    organizeTargetEnabled = target.enabled
    lastOrganizeTargetValidation = nil
    setStatus(.success, title: "正在编辑整理目标", detail: target.name)
  }

  func cancelOrganizeTargetEditing() {
    resetOrganizeTargetForm()
  }

  func deleteOrganizeTarget(_ target: OrganizeTarget) async {
    await run("删除整理目标", loadingDetail: target.name, successTitle: "整理目标已删除") {
      _ = try await client.deleteOrganizeTarget(id: target.id)
      if editingOrganizeTargetID == target.id {
        resetOrganizeTargetForm()
      }
      await loadOrganizeTargets()
    }
  }

  func setDefaultOrganizeTarget(_ target: OrganizeTarget) async {
    await run("设为默认整理目标", loadingDetail: target.name, successTitle: "默认整理目标已更新", successDetail: { target.name }) {
      _ = try await client.setDefaultOrganizeTarget(id: target.id)
      await loadOrganizeTargets()
    }
  }

  func validateOrganizeTarget(_ target: OrganizeTarget) async {
    await run("检查整理目标路径", loadingDetail: target.path, successTitle: "路径检查完成", successDetail: { self.lastOrganizeTargetValidation?.message ?? target.name }) {
      lastOrganizeTargetValidation = try await client.validateOrganizeTarget(id: target.id)
      appendLog(lastOrganizeTargetValidation?.message ?? "路径检查完成。")
    }
  }

  var searchCanGoToPreviousPage: Bool {
    searchPaginationEnabled && searchCurrentPage > 1 && !isLoading
  }

  var searchCanGoToNextPage: Bool {
    searchPaginationEnabled
      && !isLoading
      && (searchDiagnostics?.siteDiagnostics.contains { $0.hasMore } == true)
  }

  var searchPaginationSummaryText: String {
    guard searchPaginationEnabled, searchDiagnostics != nil else { return "" }
    return "第 \(searchCurrentPage) 页"
  }

  func resetSearchPagination() {
    searchCurrentPage = 1
    searchSummaryText = ""
    searchDiagnostics = nil
  }

  func performSearch() async {
    let page = searchPaginationEnabled ? 1 : nil
    await performSearch(page: page)
  }

  func performPreviousSearchPage() async {
    guard searchCanGoToPreviousPage else { return }
    await performSearch(page: searchCurrentPage - 1)
  }

  func performNextSearchPage() async {
    guard searchCanGoToNextPage else { return }
    await performSearch(page: searchCurrentPage + 1)
  }

  private func performSearch(page: Int?) async {
    guard !isLoading else { return }
    let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else {
      setStatus(.empty, title: "请输入搜索关键词", detail: "搜索条件为空，未发送请求。")
      return
    }
    let requestedSiteIDs = validSelectedSearchSiteIDs
    guard !requestedSiteIDs.isEmpty else {
      setStatus(.empty, title: "请选择搜索站点", detail: "至少勾选一个站点后再搜索。")
      return
    }
    let requestedPage = searchPaginationEnabled ? max(1, page ?? 1) : nil
    let endpoint = backendURL
    let requestClient = client
    let succeeded = await run(
      "搜索资源",
      loadingDetail: requestedPage.map { "正在搜索第 \($0) 页，每个站点仅请求一页：\(keyword)" }
        ?? "正在搜索，已自动控制请求速度以保护站点：\(keyword)",
      successTitle: "搜索完成",
      successDetail: { self.searchSummaryText.isEmpty ? "找到 \(self.searchResults.count) 条结果，警告 \(self.lastWarningCount) 条" : self.searchSummaryText }
    ) {
      let response = try await requestClient.search(
        keyword: keyword,
        sites: Array(requestedSiteIDs).sorted(),
        deduplicate: searchDeduplicate,
        pageSize: searchPageSize,
        page: requestedPage,
        maxPages: requestedPage == nil ? nil : 1,
        timeoutSeconds: searchSettings.siteTimeoutSeconds
      )
      guard self.backendURL == endpoint,
            self.searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines) == keyword
      else {
        throw CancellationError()
      }
      if requestedPage != nil,
         response.results.isEmpty,
         let failedSite = response.diagnostics?.siteDiagnostics.first(where: { $0.error != nil }) {
        searchWarnings = response.warnings
        searchDiagnostics = response.diagnostics
        lastWarningCount = response.warnings.count
        response.warnings.forEach { appendLog($0) }
        throw AppStoreError.userFacing(failedSite.error ?? "站点请求失败，请稍后重试。")
      }
      searchResults = response.results
      selectedSearchFansubs = []
      searchEpisodeFilter = ""
      searchShowUnrecognizedEpisodes = false
      searchShowBatchOnly = false
      selectedSearchResolutions = []
      applySearchFiltersNow(logPerformance: false)
      searchWarnings = response.warnings
      searchDiagnostics = response.diagnostics
      searchSummaryText = searchSummary(from: response, page: requestedPage)
      lastWarningCount = response.warnings.count
      response.warnings.forEach { appendLog($0) }
      appendLog(searchSummaryText)
    }
    if succeeded, let requestedPage {
      searchCurrentPage = requestedPage
    }
  }

  func clearSearch() {
    searchKeyword = ""
    searchResults = []
    visibleSearchResults = []
    searchFilterTask?.cancel()
    searchFiltering = false
    searchFilterSummaryText = ""
    selectedSearchFansubs = []
    searchEpisodeFilter = ""
    searchShowUnrecognizedEpisodes = false
    searchShowBatchOnly = false
    selectedSearchResolutions = []
    searchWarnings = []
    searchSummaryText = ""
    searchDiagnostics = nil
    searchCurrentPage = 1
    lastWarningCount = 0
    setStatus(.idle, title: "已清空搜索条件", detail: "搜索关键词和结果列表已清空。")
    appendLog("已清空搜索条件。")
  }

  private func searchSummary(from response: SearchResponse, page: Int?) -> String {
    let raw = response.rawCount ?? response.totalFetched ?? response.results.count
    let displayed = response.displayCount ?? response.results.count
    let pages = response.pagesFetched ?? response.diagnostics?.pagesFetched ?? 0
    var parts: [String]
    if let page {
      parts = ["第 \(page) 页", "每个站点最多抓取 1 页", "找到 \(raw) 条结果"]
    } else {
      parts = [
        response.reachedInternalSafetyLimit == true || response.diagnostics?.reachedInternalSafetyLimit == true
          ? "结果较多，已停止在安全上限"
          : "已搜索全部可访问结果",
        "抓取 \(pages) 页",
        "找到 \(raw) 条结果",
      ]
    }
    if searchDeduplicate {
      parts.append("已去重，显示 \(displayed) 条")
      if let removed = response.deduplicatedCount, removed > 0 {
        parts.append("合并 \(removed) 条重复")
      }
    } else {
      parts.append("未去重，显示 \(displayed) 条原始结果")
    }
    return parts.joined(separator: "，")
  }

  private func scheduleSearchFilterUpdate() {
    searchFilterTask?.cancel()
    guard !searchResults.isEmpty else {
      visibleSearchResults = []
      searchFiltering = false
      searchFilterSummaryText = ""
      return
    }
    searchFiltering = true
    let allResults = searchResults
    let fansubs = selectedSearchFansubs
    let episodeText = searchEpisodeFilter
    let showUnrecognized = searchShowUnrecognizedEpisodes
    let showBatchOnly = searchShowBatchOnly
    let resolutions = selectedSearchResolutions
    searchFilterTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      let started = Date()
      let visible = Self.filteredSearchResults(
        allResults,
        selectedFansubs: fansubs,
        episodeFilter: episodeText,
        showUnrecognized: showUnrecognized,
        showBatchOnly: showBatchOnly,
        selectedResolutions: resolutions
      )
      let elapsed = Date().timeIntervalSince(started)
      await MainActor.run {
        guard let self, !Task.isCancelled else { return }
        self.visibleSearchResults = visible
        self.searchFiltering = false
        self.searchFilterSummaryText = String(format: "显示 %d / %d 条，筛选耗时 %.0f ms", visible.count, allResults.count, elapsed * 1000)
        self.appendLog(self.searchFilterSummaryText)
      }
    }
  }

  private func applySearchFiltersNow(logPerformance: Bool = true) {
    searchFilterTask?.cancel()
    let started = Date()
    let visible = Self.filteredSearchResults(
      searchResults,
      selectedFansubs: selectedSearchFansubs,
      episodeFilter: searchEpisodeFilter,
      showUnrecognized: searchShowUnrecognizedEpisodes,
      showBatchOnly: searchShowBatchOnly,
      selectedResolutions: selectedSearchResolutions
    )
    visibleSearchResults = visible
    searchFiltering = false
    let elapsed = Date().timeIntervalSince(started)
    searchFilterSummaryText = String(format: "显示 %d / %d 条，筛选耗时 %.0f ms", visible.count, searchResults.count, elapsed * 1000)
    if logPerformance {
      appendLog(searchFilterSummaryText)
    }
  }

  static func filteredSearchResults(
    _ results: [SearchResult],
    selectedFansubs: Set<String>,
    episodeFilter: String,
    showUnrecognized: Bool,
    showBatchOnly: Bool,
    selectedResolutions: Set<SearchResolutionFilter> = []
  ) -> [SearchResult] {
    let filter = episodeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = filter.isEmpty ? nil : SearchEpisodeFilterParser.range(from: filter)
    return results.filter { result in
      if !selectedFansubs.isEmpty {
        guard let fansub = result.parsedFansub, selectedFansubs.contains(fansub) else {
          return false
        }
      }
      if showBatchOnly && !result.isCollectionResource {
        return false
      }
      if !selectedResolutions.isEmpty,
         !selectedResolutions.contains(SearchResolutionFilter.category(for: result.parsedResolution)) {
        return false
      }
      if showUnrecognized {
        return (result.parsedResourceType ?? "unknown") == "unknown"
      }
      if !filter.isEmpty {
        guard let range else { return false }
        return matchesEpisode(result, range)
      }
      return true
    }
  }

  static func searchResolutionCounts(in results: [SearchResult]) -> [SearchResolutionFilter: Int] {
    results.reduce(into: [:]) { counts, result in
      counts[SearchResolutionFilter.category(for: result.parsedResolution), default: 0] += 1
    }
  }

  static func searchFansubCounts(in results: [SearchResult]) -> [String: Int] {
    results.reduce(into: [:]) { counts, result in
      guard let fansub = result.parsedFansub?.trimmingCharacters(in: .whitespacesAndNewlines),
            !fansub.isEmpty else { return }
      counts[fansub, default: 0] += 1
    }
  }

  private static func matchesEpisode(_ result: SearchResult, _ range: ClosedRange<Int>) -> Bool {
    if let start = result.parsedEpisodeStart, let end = result.parsedEpisodeEnd {
      return range.overlaps(start...max(start, end))
    }
    if let episode = result.parsedEpisode {
      return range.contains(episode)
    }
    if let start = result.parsedEpisodeStart {
      return range.contains(start)
    }
    return false
  }

  func createSubscription(from result: SearchResult? = nil) async {
    let keyword = (result?.title ?? searchKeyword).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else {
      setStatus(.empty, title: "无法创建订阅", detail: "关键词为空，请先输入关键词或选择一个搜索结果。")
      return
    }
    guard !selectedSiteIDs.isEmpty else {
      setStatus(.empty, title: "无法创建订阅", detail: "请至少选择一个订阅来源站点。")
      return
    }
    let subscription = SubscriptionCreate(
      name: keyword,
      keyword: keyword,
      sourceType: "keyword",
      sites: Array(selectedSiteIDs).sorted(),
      sourceUrl: nil,
      mikanBangumiUrl: nil,
      aliases: [],
      rssUrls: [],
      regex: nil,
      regexEnabled: false,
      episodeFilter: nil,
      includeKeywords: [],
      excludeKeywords: [],
      filterOrder: "include_first",
      fansub: nil,
      resolution: nil,
      resolutionMode: "any",
      resolutionPreset: nil,
      resolutionCustom: nil,
      season: nil,
      episode: nil,
      episodeStart: nil,
      episodeOffset: 0,
      batchResourcePolicy: "show_only",
      episodeParseRules: [],
      totalEpisodes: nil,
      totalEpisodesSource: nil,
      metadataEpisodeCount: nil,
      enabled: true,
      autoDownload: true,
      organizeTargetId: defaultOrganizeTarget?.id,
      autoOrganize: organizePolicy.autoOrganizeByDefault && defaultOrganizeTarget != nil,
      postOrganizeAction: nil,
      deleteTaskAfterOrganize: nil,
      deleteFilesAfterOrganize: nil,
      keepSeeding: nil,
      seedingPolicyMode: "inherit",
      savePath: subscriptionDownloaderSavePath,
      category: subscriptionDownloaderCategory,
      tags: subscriptionDownloaderTags
    )
    await run("创建订阅", successTitle: "订阅已创建", successDetail: { keyword }) {
      _ = try await client.createSubscription(subscription)
      await loadSubscriptions()
    }
  }

  func suggestSubscription(from result: SearchResult, sitesOverride: [String]? = nil) async -> SubscriptionSuggestionResponse? {
    guard smartSubscriptionPreparingResultID == nil else { return nil }
    let suggestionSiteIDs: Set<String>
    if let sitesOverride {
      suggestionSiteIDs = Set(sitesOverride).intersection(contentSiteIDs)
    } else {
      suggestionSiteIDs = selectedSiteIDs.intersection(contentSiteIDs)
    }
    guard !suggestionSiteIDs.isEmpty else {
      setStatus(.empty, title: "无法生成订阅建议", detail: "请至少选择一个订阅来源站点。")
      return nil
    }
    smartSubscriptionPreparingResultID = result.id
    defer { smartSubscriptionPreparingResultID = nil }
    var output: SubscriptionSuggestionResponse?
    await run(
      "检查智能订阅",
      loadingDetail: "正在检查订阅列表并生成建议：\(result.title)",
      successTitle: "智能订阅已就绪",
      successDetail: { self.lastSubscriptionSuggestion?.message ?? "请确认订阅信息" }
    ) {
      let prefill = try await client.smartSubscriptionPrefill(
        result: result,
        sites: Array(suggestionSiteIDs).sorted(),
        organizeTargetID: defaultOrganizeTarget?.id,
        savePath: subscriptionDownloaderSavePath,
        category: subscriptionDownloaderCategory,
        tags: subscriptionDownloaderTags,
        useAI: nil
      )
      let response = prefill.asSuggestionResponse
      if !response.ok || response.suggestion == nil {
        throw AppStoreError.userFacing(response.message)
      }
      lastSmartPrefill = prefill
      lastSubscriptionSuggestion = response
      response.warnings.forEach { appendLog($0) }
      appendLog(response.message)
      output = response
    }
    return output
  }

  func prepareSubscriptionForm(
    from response: SubscriptionSuggestionResponse,
    suggestion: SubscriptionCreate,
    result: SearchResult,
    mikanBangumiURL: String? = nil,
    availableFansubs: [String] = []
  ) {
    let discoveredFansubs = mergedSmartSubscriptionFansubs(
      availableFansubs.map(Optional.some),
      [
        result.mikanGroupName,
        result.parsedFansub,
        suggestion.fansub,
        response.matchedSubscription?.fansub,
      ]
    )
    if let existing = response.matchedSubscription {
      let smartPrefill = lastSmartPrefill
      editSubscription(existing)
      lastSmartPrefill = smartPrefill
      subscriptionIdentityKey = response.identityKey ?? suggestion.identityKey ?? existing.identityKey
      editingSubscriptionVersion = existing.updatedAt ?? existing.createdAt
      smartSubscriptionFansubOptions = discoveredFansubs
      applySmartRecognitionSuggestion(
        suggestion,
        result: result,
        mikanBangumiURL: mikanBangumiURL
      )
      isSmartSubscriptionExistingMatch = true
      lastSubscriptionSuggestion = response
      appendLog("智能订阅已匹配现有订阅 #\(existing.id)，已载入编辑表单。")
      return
    }
    editingSubscriptionID = nil
    editingSubscriptionVersion = nil
    subscriptionIdentityKey = response.identityKey ?? suggestion.identityKey
    smartSubscriptionFansubOptions = discoveredFansubs
    isSmartSubscriptionExistingMatch = false
    subscriptionName = suggestion.name
    subscriptionKeyword = suggestion.keyword
    let explicitMikanBangumiURL = mikanBangumiURL?.trimmingCharacters(in: .whitespacesAndNewlines)
    let suggestedSourceURL = explicitMikanBangumiURL?.isEmpty == false ? explicitMikanBangumiURL : (suggestion.mikanBangumiUrl ?? suggestion.sourceUrl)
    if let suggestedSourceURL, !suggestedSourceURL.isEmpty {
      subscriptionSourceURL = suggestedSourceURL
    } else if result.source == "mikan", let detailUrl = result.detailUrl, detailUrl.contains("/Home/Bangumi/") {
      subscriptionSourceURL = detailUrl
    } else {
      subscriptionSourceURL = ""
    }
    if subscriptionSourceURL.contains("/Home/Bangumi/") || suggestion.sourceType == "mikan_bangumi" {
      subscriptionSourceType = "mikan_bangumi"
    } else {
      subscriptionSourceType = Self.validSubscriptionSourceType(suggestion.sourceType)
    }
    subscriptionAliases = suggestion.aliases.joined(separator: ", ")
    let suggestedSiteIDs = Set(suggestion.sites).intersection(contentSiteIDs)
    selectedSiteIDs = suggestedSiteIDs.isEmpty ? contentSiteIDs : suggestedSiteIDs
    subscriptionRSSURLs = suggestion.rssUrls.joined(separator: "\n")
    subscriptionRegex = suggestion.regex ?? ""
    subscriptionRegexEnabled = suggestion.regexEnabled
    subscriptionEpisodeFilter = suggestion.episodeFilter ?? ""
    subscriptionIncludeKeywords = suggestion.includeKeywords.joined(separator: ", ")
    subscriptionExcludeKeywords = suggestion.excludeKeywords.joined(separator: ", ")
    subscriptionFilterOrder = suggestion.filterOrder
    subscriptionFansub = suggestion.fansub ?? ""
    subscriptionMinSize = ""
    subscriptionMinSizeUnit = .gigabytes
    subscriptionMaxSize = ""
    subscriptionMaxSizeUnit = .gigabytes
    applySmartSuggestionResolution(
      suggestion,
      fallback: result.parsedResolution,
      clearWhenMissing: true
    )
    subscriptionSeason = suggestion.season.map(String.init) ?? ""
    subscriptionEpisodeStart = "1"
    subscriptionEpisodeOffset = String(suggestion.episodeOffset)
    subscriptionEpisodeParseRules = suggestion.episodeParseRules
    subscriptionUseCustomEpisodeRules = !suggestion.episodeParseRules.isEmpty
    subscriptionEpisodeRuleTestTitle = result.title
    lastEpisodeRuleTestResponse = nil
    subscriptionTotalEpisodes = suggestion.totalEpisodes.map(String.init) ?? ""
    subscriptionTotalEpisodesSource = suggestion.totalEpisodesSource
    subscriptionTotalEpisodesBaseline = suggestion.totalEpisodes
    subscriptionMetadataEpisodeCount = suggestion.metadataEpisodeCount
    subscriptionSavePath = suggestion.savePath ?? ""
    subscriptionCategory = suggestion.category ?? ""
    subscriptionTags = suggestion.tags.joined(separator: ", ")
    subscriptionEnabled = suggestion.enabled
    applyNewSubscriptionBehaviorDefaults()
    subscriptionOrganizeTargetID = suggestion.organizeTargetId ?? defaultOrganizeTarget?.id
    subscriptionAutoOrganize = suggestion.autoOrganize
    lastSubscriptionSuggestion = response
    if let duplicateName = response.duplicateSubscriptionName {
      appendLog("智能订阅提示：可能已存在订阅 \(duplicateName)。")
    }
    if lastSmartPrefill?.source == "ai" {
      appendLog("AI 已根据标题填充部分订阅字段，保存前仍可修改。")
    } else {
      appendLog("已把智能订阅建议填入统一订阅表单。")
    }
  }

  private func applySmartRecognitionSuggestion(
    _ suggestion: SubscriptionCreate,
    result: SearchResult,
    mikanBangumiURL: String?
  ) {
    if let name = nonEmptySmartSuggestionValue(suggestion.name) {
      subscriptionName = name
    }
    if let keyword = nonEmptySmartSuggestionValue(suggestion.keyword) {
      subscriptionKeyword = keyword
    }
    if !suggestion.aliases.isEmpty {
      subscriptionAliases = suggestion.aliases.joined(separator: ", ")
    }

    let explicitMikanURL = nonEmptySmartSuggestionValue(mikanBangumiURL)
    let resultMikanURL = result.detailUrl.flatMap { value in
      value.contains("/Home/Bangumi/") ? nonEmptySmartSuggestionValue(value) : nil
    }
    let suggestedSourceURL = explicitMikanURL
      ?? nonEmptySmartSuggestionValue(suggestion.mikanBangumiUrl)
      ?? nonEmptySmartSuggestionValue(suggestion.sourceUrl)
      ?? resultMikanURL
    if let suggestedSourceURL {
      subscriptionSourceURL = suggestedSourceURL
    }
    if suggestedSourceURL?.contains("/Home/Bangumi/") == true || suggestion.sourceType == "mikan_bangumi" {
      subscriptionSourceType = "mikan_bangumi"
    } else if nonEmptySmartSuggestionValue(suggestion.sourceType) != nil {
      subscriptionSourceType = Self.validSubscriptionSourceType(suggestion.sourceType)
    }

    let latestFansub = nonEmptySmartSuggestionValue(result.mikanGroupName)
      ?? nonEmptySmartSuggestionValue(result.parsedFansub)
      ?? nonEmptySmartSuggestionValue(suggestion.fansub)
    if let latestFansub {
      subscriptionFansub = latestFansub
    }
    if let includeKeywords = authoritativeSmartPrefillIncludeKeywords() {
      subscriptionIncludeKeywords = includeKeywords.joined(separator: ", ")
    }
    applySmartSuggestionResolution(suggestion, fallback: result.parsedResolution)

    if let season = suggestion.season {
      subscriptionSeason = String(season)
    }
    // A zero offset is the backend's generic default, so it cannot safely replace a user's configured offset.
    if suggestion.episodeOffset != 0 {
      subscriptionEpisodeOffset = String(suggestion.episodeOffset)
    }
    if !suggestion.episodeParseRules.isEmpty {
      subscriptionEpisodeParseRules = suggestion.episodeParseRules.sorted { $0.priority < $1.priority }
      subscriptionUseCustomEpisodeRules = true
    }
    subscriptionEpisodeRuleTestTitle = result.title
    lastEpisodeRuleTestResponse = nil

    let authoritativeEpisodeSources = Set(["bangumi", "mikan", "tmdb"])
    if let totalEpisodes = suggestion.totalEpisodes,
       totalEpisodes > 0,
       let source = nonEmptySmartSuggestionValue(suggestion.totalEpisodesSource)?.lowercased(),
       authoritativeEpisodeSources.contains(source) {
      subscriptionTotalEpisodes = String(totalEpisodes)
      subscriptionTotalEpisodesSource = source
      subscriptionTotalEpisodesBaseline = totalEpisodes
      subscriptionMetadataEpisodeCount = suggestion.metadataEpisodeCount
    }
  }

  private func applySmartSuggestionResolution(
    _ suggestion: SubscriptionCreate,
    fallback: String?,
    clearWhenMissing: Bool = false
  ) {
    let legacyResolution = nonEmptySmartSuggestionValue(suggestion.resolution)
      ?? nonEmptySmartSuggestionValue(fallback)
    if suggestion.resolutionMode == "custom",
       let customResolution = nonEmptySmartSuggestionValue(suggestion.resolutionCustom) ?? legacyResolution {
      subscriptionResolution = "custom"
      subscriptionResolutionCustom = customResolution
    } else if let suggestedResolution = nonEmptySmartSuggestionValue(suggestion.resolutionPreset) ?? legacyResolution,
              let presetResolution = smartResolutionPreset(suggestedResolution) {
      subscriptionResolution = presetResolution
      subscriptionResolutionCustom = ""
    } else if let legacyResolution {
      subscriptionResolution = "custom"
      subscriptionResolutionCustom = legacyResolution
    } else if clearWhenMissing {
      subscriptionResolution = ""
      subscriptionResolutionCustom = ""
    }
  }

  private func smartResolutionPreset(_ value: String) -> String? {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "×", with: "x")
      .replacingOccurrences(of: " ", with: "")
    switch normalized {
    case "720p", "1280x720":
      return "720p"
    case "1080p", "1920x1080":
      return "1080p"
    case "2160p", "3840x2160", "4096x2160", "4k":
      return "2160p"
    default:
      return nil
    }
  }

  private func nonEmptySmartSuggestionValue(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func authoritativeSmartPrefillIncludeKeywords() -> [String]? {
    guard let prefill = lastSmartPrefill,
          prefill.ok,
          let formDefaults = prefill.formDefaults,
          ["ai", "local", "mixed"].contains(prefill.source.lowercased()) else {
      return nil
    }
    return formDefaults.includeKeywords
  }

  func smartSubscriptionFansubs(for result: SearchResult, among results: [SearchResult]) -> [String] {
    let mikanID = result.mikanBangumiId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTitle = result.normalizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let related = results.filter { candidate in
      if let mikanID, !mikanID.isEmpty {
        return candidate.mikanBangumiId?.trimmingCharacters(in: .whitespacesAndNewlines) == mikanID
      }
      if let normalizedTitle, !normalizedTitle.isEmpty {
        return candidate.normalizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
      }
      return candidate.id == result.id
    }
    return mergedSmartSubscriptionFansubs(
      related.flatMap { [$0.mikanGroupName, $0.parsedFansub] }
    )
  }

  private func mergedSmartSubscriptionFansubs(_ groups: [String?]...) -> [String] {
    var seen: Set<String> = []
    var values: [String] = []
    for value in groups.flatMap({ $0 }) {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      if seen.insert(key).inserted {
        values.append(trimmed)
      }
    }
    return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  func createSuggestedSubscription(_ payload: SubscriptionCreate) async -> Bool {
    await run("创建订阅", successTitle: "订阅已创建", successDetail: { payload.name }) {
      _ = try await client.createSubscription(payload)
      lastSubscriptionSuggestion = nil
      lastSmartPrefill = nil
      await loadSubscriptions()
      appendLog("已根据智能建议创建订阅：\(payload.name)。")
    }
  }

  func searchKeywordAsResult() -> SearchResult? {
    let title = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    return SearchResult(
      id: "manual:\(title)",
      title: title,
      publishedAt: nil,
      size: nil,
      downloadUrl: nil,
      magnetUrl: nil,
      source: selectedSiteIDs.sorted().first ?? "manual",
      detailUrl: nil,
      page: nil
    )
  }

  func siteLabel(for siteID: String) -> String {
    let normalized = siteID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty || normalized == "rss" {
      return "RSS"
    }
    let canonical = Self.canonicalSiteID(normalized)
    if let configured = sites.first(where: { Self.canonicalSiteID($0.id.lowercased()) == canonical }) {
      let displayName = configured.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let displayName, !displayName.isEmpty {
        return displayName
      }
      let name = configured.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty {
        return name
      }
    }
    return Self.defaultSiteLabels[canonical] ?? siteID
  }

  private static func canonicalSiteID(_ value: String) -> String {
    switch value.replacingOccurrences(of: "_", with: "-") {
    case "m-team", "m-team.cc", "kp.m-team.cc": "mteam"
    case "open.cd", "open-cd": "opencd"
    default: value
    }
  }

  private static let defaultSiteLabels: [String: String] = [
    "mteam": "M-Team",
    "opencd": "OpenCD",
    "hddolby": "HDDolby",
    "soulvoice": "SoulVoice",
    "mikan": "Mikan",
  ]

  func prepareNewSubscription() {
    resetSubscriptionForm(keepingKeyword: searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @discardableResult
  func createSubscriptionFromForm() async -> Bool {
    await saveSubscriptionForm()
  }

  @discardableResult
  func saveSubscriptionForm() async -> Bool {
    let keyword = effectiveSubscriptionKeyword()
    guard !keyword.isEmpty else {
      setStatus(.empty, title: "无法保存订阅", detail: subscriptionSourceType == "rss" ? "请填写订阅名称或关键词。" : "关键词为空，请填写订阅关键词。")
      return false
    }
    guard !selectedSiteIDs.isEmpty else {
      setStatus(.empty, title: "无法保存订阅", detail: "请至少选择一个订阅来源站点。")
      return false
    }
    guard validSubscriptionEpisodeStart() != nil else {
      setStatus(.failed, title: "无法保存订阅", detail: "起始集数必须大于等于 1")
      return false
    }
    if let seedingError = subscriptionSeedingValidationMessage {
      setStatus(.failed, title: "无法保存订阅", detail: seedingError)
      return false
    }
    if let keywordError = subscriptionIncludeKeywordValidationMessage ?? subscriptionExcludeKeywordValidationMessage {
      setStatus(.failed, title: "无法保存订阅", detail: keywordError)
      return false
    }
    let payload: SubscriptionCreate
    do {
      payload = try subscriptionPayloadFromForm(keyword: keyword)
    } catch {
      setStatus(.failed, title: "无法保存订阅", detail: error.localizedDescription)
      return false
    }
    if let id = editingSubscriptionID {
      return await run("更新订阅", successTitle: "订阅已更新", successDetail: { payload.name }) {
        let updated = try await client.updateSubscription(
          id: id,
          payload,
          expectedUpdatedAt: editingSubscriptionVersion
        )
        try validateSubscriptionSizePersistence(payload: payload, persisted: updated)
        await loadSubscriptions()
      }
    } else {
      let endpoint = backendURL
      let requestClient = client
      return await run("创建订阅", successTitle: "订阅已创建", successDetail: { payload.name }) {
        let created = try await requestClient.createSubscription(payload)
        guard self.backendURL == endpoint else { throw CancellationError() }
        try validateSubscriptionSizePersistence(payload: payload, persisted: created)
        if initialMetadataQuery(for: created) != nil {
          pendingMetadataRecognitionSubscriptionID = created.id
          pendingMetadataRecognitionBackendURL = endpoint
        } else {
          setStatus(.success, title: "订阅已创建", detail: "订阅已创建。补充番名后可识别番剧信息。")
        }
        await loadSubscriptions()
      }
    }
  }

  private func validateSubscriptionSizePersistence(
    payload: SubscriptionCreate,
    persisted: Subscription
  ) throws {
    if let message = SubscriptionSizeFilterDraft.persistenceValidationMessage(
      requestedMinimum: payload.minSizeBytes,
      requestedMaximum: payload.maxSizeBytes,
      persistedMinimum: persisted.minSizeBytes,
      persistedMaximum: persisted.maxSizeBytes
    ) {
      throw AppStoreError.userFacing(message)
    }
  }

  func editSubscription(_ subscription: Subscription) {
    editingSubscriptionID = subscription.id
    editingSubscriptionVersion = subscription.updatedAt ?? subscription.createdAt
    subscriptionIdentityKey = subscription.identityKey
    isSmartSubscriptionExistingMatch = false
    smartSubscriptionFansubOptions = []
    lastSmartPrefill = nil
    subscriptionName = subscription.name
    subscriptionSourceType = subscription.sourceType ?? inferredSubscriptionSourceType(subscription)
    subscriptionKeyword = subscription.keyword
    subscriptionSourceURL = subscription.mikanBangumiUrl ?? subscription.sourceUrl ?? ""
    subscriptionAliases = subscription.aliases.joined(separator: ", ")
    selectedSiteIDs = Set(subscription.sites)
    subscriptionRSSURLs = subscription.rssUrls.joined(separator: "\n")
    subscriptionRegex = subscription.regex ?? ""
    subscriptionRegexEnabled = subscription.regexEnabled
    subscriptionEpisodeFilter = subscription.episodeFilter ?? ""
    subscriptionIncludeKeywords = subscription.includeKeywords.joined(separator: ", ")
    subscriptionExcludeKeywords = subscription.excludeKeywords.joined(separator: ", ")
    subscriptionFilterOrder = subscription.filterOrder
    subscriptionFansub = subscription.fansub ?? ""
    let minimumSize = SubscriptionSizeFilterDraft.display(bytes: subscription.minSizeBytes)
    subscriptionMinSize = minimumSize.text
    subscriptionMinSizeUnit = minimumSize.unit
    let maximumSize = SubscriptionSizeFilterDraft.display(bytes: subscription.maxSizeBytes)
    subscriptionMaxSize = maximumSize.text
    subscriptionMaxSizeUnit = maximumSize.unit
    let legacyResolution = subscription.resolution ?? ""
    let presetValues = ["720p", "1080p", "2160p"]
    if subscription.resolutionMode == "custom" {
      subscriptionResolution = "custom"
      subscriptionResolutionCustom = subscription.resolutionCustom ?? legacyResolution
    } else if subscription.resolutionMode == "preset" {
      subscriptionResolution = subscription.resolutionPreset ?? legacyResolution
      subscriptionResolutionCustom = ""
    } else if legacyResolution.isEmpty {
      subscriptionResolution = ""
      subscriptionResolutionCustom = ""
    } else if presetValues.contains(where: { $0.caseInsensitiveCompare(legacyResolution) == .orderedSame }) {
      subscriptionResolution = legacyResolution
      subscriptionResolutionCustom = ""
    } else {
      subscriptionResolution = "custom"
      subscriptionResolutionCustom = legacyResolution
    }
    subscriptionSeason = subscription.season.map(String.init) ?? ""
    subscriptionEpisodeStart = String(max(1, subscription.episodeStart ?? 1))
    subscriptionEpisodeOffset = String(subscription.episodeOffset)
    subscriptionEpisodeParseRules = subscription.episodeParseRules.sorted { $0.priority < $1.priority }
    subscriptionUseCustomEpisodeRules = !subscription.episodeParseRules.isEmpty
    subscriptionEpisodeRuleTestTitle = ""
    lastEpisodeRuleTestResponse = nil
    subscriptionTotalEpisodes = subscription.totalEpisodes.map(String.init) ?? ""
    subscriptionTotalEpisodesSource = subscription.totalEpisodesSource
    subscriptionTotalEpisodesBaseline = subscription.totalEpisodes
    subscriptionMetadataEpisodeCount = subscription.metadataEpisodeCount
    subscriptionSavePath = subscription.savePath ?? ""
    subscriptionCategory = subscription.category ?? ""
    subscriptionTags = subscription.tags.joined(separator: ", ")
    subscriptionEnabled = subscription.enabled
    subscriptionAutoDownload = subscription.autoDownload
    subscriptionOrganizeTargetID = subscription.organizeTargetId ?? defaultOrganizeTarget?.id
    subscriptionAutoOrganize = subscription.autoOrganize ?? (subscription.organizeTargetId != nil)
    subscriptionPostOrganizeAction = Self.subscriptionPostOrganizeAction(
      explicitAction: subscription.postOrganizeAction,
      deleteTask: subscription.deleteTaskAfterOrganize,
      deleteFiles: subscription.deleteFilesAfterOrganize,
      keepSeeding: subscription.keepSeeding
    )
    subscriptionDeleteTaskAfterOrganize = subscription.deleteTaskAfterOrganize ?? organizePolicy.deleteTaskAfterOrganize
    subscriptionDeleteFilesAfterOrganize = subscription.deleteFilesAfterOrganize ?? organizePolicy.deleteFilesAfterOrganize
    subscriptionKeepSeeding = subscription.keepSeeding ?? organizePolicy.keepSeeding
    applySubscriptionSeedingDraft(
      mode: subscription.seedingPolicyMode,
      ratio: subscription.seedingStopRatio,
      minutes: subscription.seedingStopMinutes,
      stopMode: subscription.seedingStopMode,
      postAction: subscription.postSeedingAction
    )
    setStatus(.success, title: "正在编辑订阅", detail: subscription.name)
    appendLog("正在编辑订阅：\(subscription.name)。")
  }

  func cancelSubscriptionEditing() {
    resetSubscriptionForm(keepingKeyword: subscriptionKeyword)
  }

  @discardableResult
  func testSubscriptionForm() async -> Bool {
    let keyword = effectiveSubscriptionKeyword()
    guard !keyword.isEmpty else {
      setStatus(.empty, title: "无法测试匹配", detail: subscriptionSourceType == "rss" ? "请填写订阅名称或关键词。" : "请先填写关键词或 Mikan Bangumi URL。")
      return false
    }
    guard !selectedSiteIDs.isEmpty else {
      setStatus(.empty, title: "无法测试匹配", detail: "请至少选择一个订阅来源站点。")
      return false
    }
    guard validSubscriptionEpisodeStart() != nil else {
      setStatus(.failed, title: "无法测试匹配", detail: "起始集数必须大于等于 1")
      return false
    }
    if let seedingError = subscriptionSeedingValidationMessage {
      setStatus(.failed, title: "无法保存订阅", detail: seedingError)
      return false
    }
    if let keywordError = subscriptionIncludeKeywordValidationMessage ?? subscriptionExcludeKeywordValidationMessage {
      setStatus(.failed, title: "无法测试匹配", detail: keywordError)
      return false
    }
    let payload: SubscriptionCreate
    do {
      payload = try subscriptionPayloadFromForm(keyword: keyword)
    } catch {
      setStatus(.failed, title: "无法测试匹配", detail: error.localizedDescription)
      return false
    }
    return await run("测试匹配", successTitle: "测试匹配完成", successDetail: { self.lastSubscriptionTestMatchResponse?.message ?? "" }) {
      lastSubscriptionTestMatchResponse = try await client.testSubscriptionMatch(payload)
    }
  }

  @discardableResult
  func testRSSForm() async -> Bool {
    guard let url = splitLines(subscriptionRSSURLs).first else {
      setStatus(.empty, title: "无法测试 RSS", detail: "请先填写 RSS 地址。")
      return false
    }
    guard let site = selectedSiteIDs.sorted().first else {
      setStatus(.empty, title: "无法测试 RSS", detail: "请至少选择一个站点。")
      return false
    }
    return await run("测试 RSS", successTitle: "RSS 测试完成", successDetail: { self.lastSubscriptionTestMatchResponse?.message ?? "" }) {
      let response = try await client.testRSS(url: url, site: site)
      let sampleTitles = response.results.prefix(3).map(\.title).joined(separator: " / ")
      setStatus(
        response.ok ? .success : .failed,
        title: response.ok ? "RSS 可读取" : "RSS 读取失败",
        detail: sampleTitles.isEmpty ? response.message : "\(response.message)：\(sampleTitles)"
      )
      appendLog("RSS 测试：\(response.message)。")
    }
  }

  func addEpisodeParseRule(template: String) {
    let rule = makeEpisodeParseRule(template: template, priority: subscriptionEpisodeParseRules.count)
    subscriptionUseCustomEpisodeRules = true
    subscriptionEpisodeParseRules.append(rule)
  }

  private func makeEpisodeParseRule(template: String, priority: Int) -> EpisodeParseRule {
    switch template {
    case "star_single":
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "★01★ 格式",
        pattern: #"★(?<episode>\d{1,3})(?:\(完\))?★"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    case "star_range":
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "★01~12(完)★ 合集格式",
        pattern: #"★(?<start>\d{1,3})[~-](?<end>\d{1,3})(?<final>\(完\))?★"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    case "bracket":
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "[01] 方括号格式",
        pattern: #"\[(?<episode>\d{1,3})\]"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    case "bracket_range":
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "[01-12] 方括号合集",
        pattern: #"\[(?<start>\d{1,3})\s*[-~～]\s*(?<end>\d{1,3})\]"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    case "plain_v2":
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "01v2 格式",
        pattern: #"(?<episode>\d{1,3})v\d+"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    case "final":
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "12(完) 格式",
        pattern: #"(?<episode>\d{1,3})(?<final>\(完\)|（完）)"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    default:
      return EpisodeParseRule(
        id: UUID().uuidString,
        name: "第01话 格式",
        pattern: #"第\s*(?<episode>\d{1,3})\s*[话話集]"#,
        enabled: true,
        priority: priority,
        episodeGroup: "episode",
        startGroup: "start",
        endGroup: "end",
        finalGroup: "final"
      )
    }
  }

  func removeEpisodeParseRule(_ rule: EpisodeParseRule) {
    subscriptionEpisodeParseRules.removeAll { $0.id == rule.id }
    subscriptionEpisodeParseRules = normalizedEpisodeParseRules()
  }

  func moveEpisodeParseRule(_ rule: EpisodeParseRule, direction: Int) {
    guard let index = subscriptionEpisodeParseRules.firstIndex(where: { $0.id == rule.id }) else { return }
    let target = index + direction
    guard subscriptionEpisodeParseRules.indices.contains(target) else { return }
    subscriptionEpisodeParseRules.swapAt(index, target)
    subscriptionEpisodeParseRules = normalizedEpisodeParseRules()
  }

  @discardableResult
  func testEpisodeParseRules() async -> Bool {
    let title = subscriptionEpisodeRuleTestTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      setStatus(.empty, title: "无法测试集数识别", detail: "请先粘贴一个资源标题。")
      return false
    }
    let rules = subscriptionUseCustomEpisodeRules ? normalizedEpisodeParseRules() : []
    return await run("测试集数识别", successTitle: "集数识别完成", successDetail: { self.lastEpisodeRuleTestResponse?.message ?? "" }) {
      let parsed = try await client.parseTitle(title, episodeParseRules: rules)
      let message: String
      if parsed.episode == nil {
        message = parsed.parseFailureReason ?? "未识别到集数。"
      } else if parsed.isBatch == true {
        message = "识别为合集 \(parsed.episodeStart ?? parsed.episode ?? 0)-\(parsed.episodeEnd ?? parsed.episode ?? 0)。"
      } else {
        message = "识别为第 \(parsed.episode ?? 0) 集。"
      }
      lastEpisodeRuleTestResponse = EpisodeRuleTestResponse(ok: true, parsedTitle: parsed, message: message)
    }
  }

  func toggleSubscriptionEnabled(_ subscription: Subscription) async {
    var payload = subscriptionPayload(from: subscription)
    payload.enabled.toggle()
    await run(payload.enabled ? "启用订阅" : "停用订阅") {
      _ = try await client.updateSubscription(id: subscription.id, payload)
      if editingSubscriptionID == subscription.id {
        subscriptionEnabled = payload.enabled
      }
      await loadSubscriptions()
    }
  }

  func deleteSubscription(_ subscription: Subscription) async {
    await run("删除订阅", successTitle: "订阅已删除", successDetail: { subscription.name }) {
      _ = try await client.deleteSubscription(id: subscription.id)
      if selectedMatchSubscriptionID == subscription.id {
        selectedSubscriptionDetail = nil
        selectedMatchSubscriptionID = nil
        subscriptionMatches = []
      }
      await loadSubscriptions()
      await loadHistory()
    }
  }

  @discardableResult
  func addDownload(_ result: SearchResult, organizeTargetID: Int? = nil, dryRun: Bool = false) async -> Bool {
    await run("提交下载", successTitle: dryRun ? "已记录未提交下载" : "已提交下载") {
      let response = try await client.addDownload(
        result: result,
        organizeTargetID: organizeTargetID ?? defaultOrganizeTarget?.id,
        dryRun: dryRun
      )
      appendLog(response.message)
      await loadHistory()
    }
  }

  func loadSubscriptions(silent: Bool = false) async {
    let requestID = subscriptionLoadSequence.begin()
    if silent {
      do {
        let loaded = try await client.subscriptions()
        guard subscriptionLoadSequence.accepts(requestID) else { return }
        updateSubscriptions(loaded)
        await loadOverview(silent: true)
      } catch {
        guard subscriptionLoadSequence.accepts(requestID) else { return }
        appendLog("静默更新订阅失败：\(error.localizedDescription)")
      }
      return
    }
    await run("加载订阅", successDetail: { "共 \(self.subscriptions.count) 个订阅" }) {
      let loaded: [Subscription]
      do {
        loaded = try await client.subscriptions()
      } catch {
        guard subscriptionLoadSequence.accepts(requestID) else {
          throw CancellationError()
        }
        throw error
      }
      guard subscriptionLoadSequence.accepts(requestID) else {
        throw CancellationError()
      }
      updateSubscriptions(loaded)
      await loadOverview(silent: true)
      lastRefreshResponse = nil
      lastRefreshAllResponse = nil
      showingRefreshAllSummary = false
      refreshQueueStates = [:]
      refreshQueueCurrentID = nil
      refreshQueueProgressText = ""
      refreshQueueRunning = false
    }
  }

  func refreshSubscription(_ subscription: Subscription) async {
    await run(
      "刷新订阅",
      loadingDetail: subscription.name,
      successTitle: "订阅刷新完成",
      successDetail: { self.lastRefreshResponse?.diagnostics.map { "抓取 \($0.totalFetched)，匹配 \($0.matchedCount)，跳过 \(self.lastRefreshResponse?.skipped.count ?? 0)" } ?? "匹配 \(self.lastRefreshResponse?.matched.count ?? 0)，新增 \(self.lastRefreshResponse?.added.count ?? 0)，跳过 \(self.lastRefreshResponse?.skipped.count ?? 0)" }
    ) {
      let response = try await client.refreshSubscription(id: subscription.id)
      showingRefreshAllSummary = false
      lastRefreshResponse = response
      selectedMatchSubscriptionID = subscription.id
      subscriptionMatches = response.matchRecords
      if let diagnostics = response.diagnostics {
        var sourceSummary = ""
        if (diagnostics.matchedBySubtitle ?? 0) > 0 || (diagnostics.episodeParsedFromSubtitle ?? 0) > 0 {
          sourceSummary = "，副标题番名命中 \(diagnostics.matchedBySubtitle ?? 0)，副标题解析集数 \(diagnostics.episodeParsedFromSubtitle ?? 0)"
        }
        var collectionSummary = ""
        if (diagnostics.excludedByBatchPolicy ?? 0) > 0 || (diagnostics.excludedByEpisodeCoverage ?? 0) > 0 {
          collectionSummary = "，合集策略排除 \(diagnostics.excludedByBatchPolicy ?? 0)，范围未覆盖 \(diagnostics.excludedByEpisodeCoverage ?? 0)"
        }
        appendLog("订阅刷新：抓取 \(diagnostics.totalFetched)，匹配 \(diagnostics.matchedCount)，字幕组过滤 \(diagnostics.excludedByFansub)，包含词过滤 \(diagnostics.excludedByInclude)，排除词过滤 \(diagnostics.excludedByExclude)，分辨率过滤 \(diagnostics.excludedByResolution)，正则过滤 \(diagnostics.excludedByRegex)，集数过滤 \(diagnostics.excludedByEpisodeFilter)\(collectionSummary)\(sourceSummary)，跳过 \(response.skipped.count)。")
      } else {
        appendLog("订阅刷新：匹配 \(response.matched.count)，新增 \(response.added.count)，跳过 \(response.skipped.count)。")
      }
      response.warnings.forEach { appendLog($0) }
      await loadHistory()
      selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscription.id)
      updateSubscriptions(try await client.subscriptions())
    }
  }

  func refreshAllSubscriptions() async {
    let queue = subscriptions.filter(\.enabled)
    let skipped = subscriptions.filter { !$0.enabled }.count
    guard !queue.isEmpty else {
      refreshQueueRunning = false
      refreshQueueStates = Dictionary(uniqueKeysWithValues: subscriptions.filter { !$0.enabled }.map { ($0.id, "skipped") })
      refreshQueueCurrentID = nil
      refreshQueueProgressText = "刷新完成：成功 0，失败 0，跳过 \(skipped)"
      lastRefreshAllResponse = RefreshAllResponse(refreshed: 0, responses: [], warnings: skipped > 0 ? ["停用订阅已跳过。"] : [], skipped: skipped)
      showingRefreshAllSummary = skipped > 0
      setStatus(.empty, title: "没有可刷新的订阅", detail: skipped > 0 ? "停用订阅已跳过。" : "当前没有启用中的订阅。")
      return
    }
    refreshQueueRunning = true
    var states = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, "waiting") })
    for subscription in subscriptions where !subscription.enabled {
      states[subscription.id] = "skipped"
    }
    refreshQueueStates = states
    refreshQueueCurrentID = nil
    refreshQueueProgressText = skipped > 0 ? "准备刷新 \(queue.count) 个订阅，跳过 \(skipped) 个停用订阅" : "准备刷新 \(queue.count) 个订阅"
    let completed = await run("刷新全部订阅", successTitle: "全部订阅刷新完成", successDetail: { self.refreshQueueProgressText }) {
      var responses: [RefreshResponse] = []
      var warnings: [String] = []
      for (index, subscription) in queue.enumerated() {
        refreshQueueCurrentID = subscription.id
        refreshQueueStates[subscription.id] = "running"
        refreshQueueProgressText = "正在刷新 \(index + 1) / \(queue.count)：\(subscription.name)"
        appendLog(refreshQueueProgressText)
        do {
          let response = try await client.refreshSubscription(id: subscription.id)
          responses.append(response)
          refreshQueueStates[subscription.id] = response.warnings.isEmpty ? "done" : "done"
          updateSubscriptions(try await client.subscriptions())
          lastRefreshResponse = response
          selectedMatchSubscriptionID = subscription.id
          subscriptionMatches = response.matchRecords
        } catch {
          refreshQueueStates[subscription.id] = "failed"
          let message = "订阅 \(subscription.name) 刷新失败：\(error.localizedDescription)"
          warnings.append(message)
          appendLog(message)
        }
      }
      let response = RefreshAllResponse(refreshed: responses.count, responses: responses, warnings: warnings, skipped: skipped)
      showingRefreshAllSummary = true
      lastRefreshAllResponse = response
      if let first = response.responses.first {
        lastRefreshResponse = first
        selectedMatchSubscriptionID = first.subscriptionId
        subscriptionMatches = first.matchRecords
        selectedSubscriptionDetail = try await client.subscriptionDetail(id: first.subscriptionId)
      } else {
        lastRefreshResponse = nil
        selectedMatchSubscriptionID = nil
        selectedSubscriptionDetail = nil
        subscriptionMatches = []
      }
      let failed = refreshQueueStates.values.filter { $0 == "failed" }.count
      refreshQueueProgressText = "刷新完成：成功 \(response.refreshed)，失败 \(failed)，跳过 \(response.skipped ?? 0)"
      appendLog(refreshQueueProgressText)
      response.warnings.forEach { appendLog($0) }
      response.responses.flatMap(\.warnings).forEach { appendLog($0) }
      await loadHistory()
      updateSubscriptions(try await client.subscriptions())
      refreshQueueCurrentID = nil
      refreshQueueRunning = false
    }
    if !completed {
      if let current = refreshQueueCurrentID {
        refreshQueueStates[current] = "failed"
      }
      refreshQueueCurrentID = nil
      refreshQueueRunning = false
    }
  }

  func loadMatches(for subscription: Subscription) async {
    await loadSubscriptionDetail(for: subscription)
  }

  func loadSubscriptionDetail(for subscription: Subscription) async {
    await run("加载订阅详情", loadingDetail: subscription.name, successDetail: { "\(self.subscriptionMatches.count) 条匹配记录，\(self.selectedSubscriptionDetail?.history.count ?? 0) 条历史" }) {
      selectedMatchSubscriptionID = subscription.id
      let detail = try await client.subscriptionDetail(id: subscription.id)
      selectedSubscriptionDetail = detail
      subscriptionMatches = detail.matches
      appendLog("已加载 \(subscription.name) 的详情：\(detail.matches.count) 条匹配，\(detail.history.count) 条历史。")
    }
  }

  func refreshSelectedSubscriptionDetail(silent: Bool = false) async {
    let subscriptionID = selectedMatchSubscriptionID ?? selectedSubscriptionDetail?.subscription.id
    guard let subscriptionID else { return }
    if silent {
      do {
        let detail = try await client.subscriptionDetail(id: subscriptionID)
        selectedSubscriptionDetail = detail
        subscriptionMatches = detail.matches
      } catch {
        appendLog("自动刷新订阅详情失败：\(error.localizedDescription)")
      }
      return
    }
    await run("刷新订阅详情", successDetail: { "\(self.subscriptionMatches.count) 条匹配记录，\(self.selectedSubscriptionDetail?.history.count ?? 0) 条历史" }) {
      let detail = try await client.subscriptionDetail(id: subscriptionID)
      selectedSubscriptionDetail = detail
      subscriptionMatches = detail.matches
      appendLog("订阅详情已刷新。")
    }
  }

  func addDownload(_ match: SubscriptionMatch) async {
    await downloadMatch(match)
  }

  func downloadMatch(_ match: SubscriptionMatch, dryRun: Bool = false) async {
    await run("提交订阅匹配下载", loadingDetail: match.result.title, successTitle: dryRun ? "已记录未提交下载" : "匹配条目已提交下载", successDetail: { self.lastSubscriptionDownloadResponse?.message ?? "已更新订阅状态" }) {
      let response = try await client.downloadSubscriptionMatches(
        subscriptionID: match.subscriptionId,
        matchIDs: [match.id],
        dryRun: dryRun
      )
      lastSubscriptionDownloadResponse = response
      response.warnings.forEach { appendLog($0) }
      await loadHistory()
      selectedSubscriptionDetail = try await client.subscriptionDetail(id: match.subscriptionId)
      subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      selectedMatchSubscriptionID = match.subscriptionId
      updateSubscriptions(try await client.subscriptions())
      appendLog(response.message)
    }
  }

  func downloadAllVisibleMatches(dryRun: Bool = false) async {
    guard let subscriptionID = selectedMatchSubscriptionID else {
      setStatus(.empty, title: "无法提交下载", detail: "请先加载一个订阅的匹配记录。")
      return
    }
    guard !subscriptionMatches.isEmpty else {
      setStatus(.empty, title: "无法提交下载", detail: "当前订阅没有可提交的匹配记录。")
      return
    }
    await run("提交全部匹配下载", successTitle: dryRun ? "已记录未提交下载" : "全部匹配已提交下载", successDetail: { self.lastSubscriptionDownloadResponse?.message ?? "已更新订阅状态" }) {
      let response = try await client.downloadSubscriptionMatches(
        subscriptionID: subscriptionID,
        matchIDs: [],
        allMatches: true,
        dryRun: dryRun
      )
      lastSubscriptionDownloadResponse = response
      response.warnings.forEach { appendLog($0) }
      await loadHistory()
      selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscriptionID)
      subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      updateSubscriptions(try await client.subscriptions())
      appendLog(response.message)
    }
  }

  func organizeCurrentSubscriptionAll() async {
    guard let detail = selectedSubscriptionDetail else {
      setStatus(.empty, title: "无法整理", detail: "请先打开一个订阅详情。")
      return
    }
    await run("整理全部已下载剧集", loadingDetail: detail.subscription.name, successTitle: "整理完成", successDetail: { self.lastSubscriptionOrganizeResponse?.message ?? "已更新整理状态" }) {
      let response = try await client.organizeSubscription(
        subscriptionID: detail.subscription.id,
        organizeTargetID: detail.subscription.organizeTargetId,
        deleteTaskAfterSuccess: detail.subscription.deleteTaskAfterOrganize,
        deleteFiles: detail.subscription.deleteFilesAfterOrganize,
        keepSeeding: detail.subscription.keepSeeding,
        confirm: true
      )
      lastSubscriptionOrganizeResponse = response
      response.warnings.forEach { appendLog($0) }
      selectedSubscriptionDetail = try await client.subscriptionDetail(id: detail.subscription.id)
      subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      await loadHistory()
      updateSubscriptions(try await client.subscriptions())
      appendLog(response.message)
    }
  }

  func organizeCurrentSubscriptionEpisodes(_ episodeNumbers: [Int], matchIDs: [Int] = []) async {
    guard let detail = selectedSubscriptionDetail else {
      setStatus(.empty, title: "无法整理", detail: "请先打开一个订阅详情。")
      return
    }
    guard !episodeNumbers.isEmpty || !matchIDs.isEmpty else {
      setStatus(.empty, title: "请选择剧集", detail: "勾选要整理的剧集后再试。")
      return
    }
    await run("整理选中剧集", loadingDetail: detail.subscription.name, successTitle: "整理完成", successDetail: { self.lastSubscriptionOrganizeResponse?.message ?? "已更新整理状态" }) {
      let response = try await client.organizeSubscriptionEpisodes(
        subscriptionID: detail.subscription.id,
        episodeNumbers: episodeNumbers,
        matchIDs: matchIDs,
        organizeTargetID: detail.subscription.organizeTargetId,
        confirm: true
      )
      lastSubscriptionOrganizeResponse = response
      response.warnings.forEach { appendLog($0) }
      selectedSubscriptionDetail = try await client.subscriptionDetail(id: detail.subscription.id)
      subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      await loadHistory()
      updateSubscriptions(try await client.subscriptions())
      appendLog(response.message)
    }
  }

  func matchMetadata(for match: SubscriptionMatch) async {
    metadataTargetType = "resource"
    metadataTargetID = "subscription-match:\(match.id)"
    metadataQuery = match.result.title
    await run("识别番剧信息", loadingDetail: match.result.title, successTitle: "番剧信息识别完成", successDetail: { "\(self.metadataCandidates.count) 个候选" }) {
      let response = try await client.metadataMatch(title: match.result.title)
      originalFilename = match.result.title
      parsedTitle = match.parsedTitle
      applyMetadataResponse(response)
      showingMetadataReview = true
    }
  }

  func matchMetadataForSelectedSubscription() async {
    guard let subscription = selectedSubscriptionDetail?.subscription else {
      setStatus(.empty, title: "无法重新识别", detail: "请先打开一个订阅详情。")
      return
    }
    metadataTargetType = "subscription"
    metadataTargetID = "\(subscription.id)"
    metadataQuery = subscription.name
    await run("重新识别番剧信息", loadingDetail: subscription.name, successTitle: "番剧信息识别完成", successDetail: { "\(self.metadataCandidates.count) 个候选" }) {
      let response = try await client.metadataMatch(title: subscription.name)
      originalFilename = subscription.name
      applyMetadataResponse(response)
      showingMetadataReview = true
    }
  }

  func beginMobileSubscriptionMetadataReview() {
    guard let subscription = selectedSubscriptionDetail?.subscription else { return }
    metadataTargetType = "subscription"
    metadataTargetID = String(subscription.id)
    metadataQuery = subscription.name
    metadataCandidates = []
    metadataWarnings = []
    showingMetadataReview = true
  }

  func runPendingMetadataRecognitionIfNeeded() async {
    guard let subscriptionID = pendingMetadataRecognitionSubscriptionID else { return }
    guard pendingMetadataRecognitionBackendURL == nil || pendingMetadataRecognitionBackendURL == backendURL else {
      pendingMetadataRecognitionSubscriptionID = nil
      pendingMetadataRecognitionBackendURL = nil
      return
    }
    let subscription: Subscription
    if let loaded = subscriptions.first(where: { $0.id == subscriptionID }) {
      subscription = loaded
    } else {
      do {
        subscription = try await client.subscriptionDetail(id: subscriptionID).subscription
      } catch {
        setStatus(.failed, title: "暂不能识别番剧信息", detail: "订阅已创建，但暂时无法读取详情。请稍后重试。")
        appendLog("读取新订阅详情失败：\(error.localizedDescription)")
        return
      }
    }
    pendingMetadataRecognitionSubscriptionID = nil
    pendingMetadataRecognitionBackendURL = nil
    await matchMetadata(for: subscription, initialRecognition: true)
  }

  func matchMetadata(for subscription: Subscription, initialRecognition: Bool = false) async {
    guard let query = initialMetadataQuery(for: subscription) else {
      setStatus(.success, title: "订阅已创建", detail: "订阅已创建。补充番名后可识别番剧信息。")
      return
    }
    metadataTargetType = "subscription"
    metadataTargetID = "\(subscription.id)"
    metadataQuery = query
    let operation = initialRecognition ? "识别番剧信息" : "重新识别番剧信息"
    await run(operation, loadingDetail: query, successTitle: "番剧信息识别完成", successDetail: { "\(self.metadataCandidates.count) 个候选" }, showsLoading: !initialRecognition) {
      let response = try await client.metadataMatch(title: query)
      originalFilename = query
      applyMetadataResponse(response)
      showingMetadataReview = true
    }
  }

  func skipMetadataRecognition() {
    showingMetadataReview = false
    metadataCandidates = []
    metadataWarnings = []
    metadataRecommendedCandidateID = nil
    metadataSuggestedMapping = nil
    metadataMergeSummary = nil
    setStatus(.success, title: "已跳过番剧识别", detail: "订阅仍然创建成功，可稍后重新识别。")
  }

  func previewMatch(_ match: SubscriptionMatch) async {
    guard let detail = selectedSubscriptionDetail else {
      setStatus(.empty, title: "无法生成整理预览", detail: "请先打开订阅详情并选择资源。")
      return
    }
    #if os(macOS)
    if let history = detail.history.first(where: { $0.fingerprint == match.fingerprint }) {
      await previewHistoryItem(history)
      return
    }
    #endif
    let history = detail.history.first { $0.fingerprint == match.fingerprint } ??
      detail.history.first { $0.title == match.result.title || $0.torrentName == match.result.title }
    let target = detail.organizeTarget ?? previewOrganizeTarget
    let mappingForPreview: PlexSeasonMapping
    if let record = detail.plexMappings.first {
      mappingForPreview = record.mapping
    } else if !mapping.showName.isEmpty {
      mappingForPreview = mapping
    } else {
      mappingForPreview = defaultMapping(for: detail)
      appendLog("未找到已保存整理规则，已使用订阅名称生成临时整理规则：\(mappingForPreview.showName)。")
    }
    parsedTitle = match.parsedTitle
    originalFilename = match.result.title
    sourcePath = history == nil ? (sourcePathForMatch(match) ?? "") : ""
    await run("生成合集整理预览", loadingDetail: "正在生成整理预览…", successTitle: "整理预览已生成", successDetail: { self.organizePreview?.destinationPreview ?? "已生成预览" }) {
      appendLog("organize preview api request endpoint=/api/organize/preview download_record_id=\(history?.id.description ?? "nil") source_path=\(sourcePath.isEmpty ? "auto" : sourcePath)")
      organizePreview = try await client.organizePreview(
        OrganizePreviewRequest(
          sourcePath: sourcePath,
          downloadRecordId: history?.id,
          libraryRoot: target?.path ?? libraryRoot,
          organizeTargetId: target?.id,
          originalFilename: match.result.title,
          parsedTitle: match.parsedTitle,
          mapping: mappingForPreview,
          episodeTitle: nil,
          isSpecial: match.parsedTitle.isSpecial == true
        )
      )
      appendLog("organize preview api success files=\(organizePreview?.fileMappings?.count ?? 0) is_batch=\(organizePreview?.isBatch == true)")
      await loadOrganizePreviews()
      showingBatchOrganizeSheet = organizePreview != nil
    }
  }

  func previewResource(_ resource: SubscriptionEpisodeResource) async {
    let resourceTypeText = resource.resourceType ?? "unknown"
    appendLog(
      "organize button clicked resource match_id=\(resource.matchId) download_record_id=\(resource.downloadRecordId.map(String.init) ?? "nil") subscription_id=\(selectedSubscriptionDetail?.subscription.id.description ?? "nil") resource_type=\(resourceTypeText)"
    )
    guard let detail = selectedSubscriptionDetail,
          let match = detail.matches.first(where: { $0.id == resource.matchId }) else {
      setStatus(.empty, title: "无法生成整理预览", detail: "请先打开订阅详情并选择资源。")
      return
    }
    #if os(macOS)
    if let recordID = resource.downloadRecordId,
       let history = detail.history.first(where: { $0.id == recordID }) {
      await previewHistoryItem(history)
      return
    }
    #endif
    let target = detail.organizeTarget ?? previewOrganizeTarget
    let mappingForPreview: PlexSeasonMapping
    if let record = detail.plexMappings.first {
      mappingForPreview = record.mapping
    } else if !mapping.showName.isEmpty {
      mappingForPreview = mapping
    } else {
      mappingForPreview = defaultMapping(for: detail)
      appendLog("未找到已保存整理规则，已使用订阅名称生成临时整理规则：\(mappingForPreview.showName)。")
    }
    parsedTitle = match.parsedTitle
    originalFilename = resource.rawTitle
    sourcePath = resource.downloadRecordId == nil ? (sourcePathForMatch(match) ?? "") : ""
    await run("生成合集整理预览", loadingDetail: "正在生成整理预览…", successTitle: "整理预览已生成", successDetail: { self.organizePreview?.destinationPreview ?? "已生成预览" }) {
      appendLog("organize preview api request endpoint=/api/organize/preview download_record_id=\(resource.downloadRecordId.map(String.init) ?? "nil") source_path=\(sourcePath.isEmpty ? "auto" : sourcePath)")
      organizePreview = try await client.organizePreview(
        OrganizePreviewRequest(
          sourcePath: sourcePath,
          downloadRecordId: resource.downloadRecordId,
          libraryRoot: target?.path ?? libraryRoot,
          organizeTargetId: target?.id,
          originalFilename: resource.rawTitle,
          parsedTitle: match.parsedTitle,
          mapping: mappingForPreview,
          episodeTitle: nil,
          isSpecial: match.parsedTitle.isSpecial == true
        )
      )
      appendLog("organize preview api success files=\(organizePreview?.fileMappings?.count ?? 0) is_batch=\(organizePreview?.isBatch == true)")
      await loadOrganizePreviews()
      showingBatchOrganizeSheet = organizePreview != nil
    }
  }

  private func defaultMapping(for detail: SubscriptionDetail) -> PlexSeasonMapping {
    PlexSeasonMapping(
      subjectKey: "subscription:\(detail.subscription.id)",
      showName: detail.subscription.name,
      showYear: nil,
      seasonNumber: detail.subscription.season ?? 1,
      episodeOffset: detail.subscription.episodeOffset,
      specialEpisodeNumbers: [:]
    )
  }

  func previewHistoryItem(_ item: DownloadHistory) async {
    resetManualHistoryOrganize()
    manualOrganizeHistoryItem = item
    originalFilename = item.torrentName ?? item.title
    metadataTargetType = "resource"
    metadataTargetID = "download-history:\(item.id)"
    metadataQuery = originalFilename
    mapping = PlexSeasonMapping(
      subjectKey: metadataTargetID,
      showName: "",
      showYear: nil,
      seasonNumber: 1,
      episodeOffset: 0,
      specialEpisodeNumbers: [:]
    )
    applyManualOrganizeScope(ManualOrganizeScope.resolve(history: item, parsed: nil))
    showingManualHistoryOrganizeSheet = true
    if organizeTargets.isEmpty {
      await loadOrganizeTargets()
    }
    manualOrganizeTargetID = defaultOrganizeTarget?.id
    await runManualOrganizeOperation(
      "识别手动下载任务",
      failureTitle: "识别番剧信息失败"
    ) { operationID in
      let response = try await client.metadataMatch(title: originalFilename, downloadRecordID: item.id, mediaType: manualOrganizeMediaType)
      guard manualOrganizeSequence.accepts(operationID) else { throw CancellationError() }
      applyMetadataResponse(response)
      configureManualOrganizeFields(response: response)
    }
  }

  #if DEBUG
  func prepareManualHistoryOrganizeFixture(_ item: DownloadHistory) {
    resetManualHistoryOrganize()
    manualOrganizeHistoryItem = item
    originalFilename = item.torrentName ?? item.title
    metadataTargetType = "resource"
    metadataTargetID = "download-history:\(item.id)"
    metadataQuery = "脱敏番组"
    mapping = PlexSeasonMapping(
      subjectKey: metadataTargetID,
      showName: "脱敏番组",
      showYear: 2026,
      seasonNumber: 1,
      episodeOffset: 0,
      specialEpisodeNumbers: [:]
    )
    manualOrganizeOriginalTitle = originalFilename
    applyManualOrganizeScope(ManualOrganizeScope.resolve(history: item, parsed: nil))
    manualOrganizeTargetID = organizeTargets.first(where: \.enabled)?.id
    showingManualHistoryOrganizeSheet = true
  }
  #endif

  func searchManualHistoryMetadata() async {
    await searchManualHistoryMetadata(sources: ["bangumi", "tmdb"], operationLabel: "搜索全部")
  }

  func searchManualHistoryBangumiMetadata() async {
    await searchManualHistoryMetadata(sources: ["bangumi"], operationLabel: "搜索 Bangumi")
  }

  func searchManualHistoryTMDBMetadata() async {
    await searchManualHistoryMetadata(sources: ["tmdb"], operationLabel: "搜索 TMDB")
  }

  private func searchManualHistoryMetadata(sources: [String], operationLabel: String) async {
    let query = metadataQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      publishManualOrganizeFailure(title: "请输入番剧关键词", detail: "可输入中文、日文或英文番名。")
      return
    }
    organizePreview = nil
    await runManualOrganizeOperation(
      operationLabel,
      failureTitle: "\(operationLabel)失败"
    ) { operationID in
      let response = try await client.metadataSearch(query: query, sources: sources, mediaType: manualOrganizeMediaType)
      guard manualOrganizeSequence.accepts(operationID) else { throw CancellationError() }
      guard !response.candidates.isEmpty else {
        throw AppStoreError.userFacing(response.warnings.first ?? "没有找到匹配作品，请换个名称搜索。")
      }
      applyMetadataResponse(response)
      configureManualOrganizeFields(response: response)
    }
  }

  func selectManualHistoryMetadata(_ candidateID: String?) {
    manualOrganizeSelectedCandidateID = candidateID
    organizePreview = nil
    guard let candidateID,
          let candidate = metadataCandidates.first(where: { $0.id == candidateID }) else {
      return
    }
    let selection = ManualMetadataCandidateSelection.resolve(
      candidate: candidate,
      parsed: parsedTitle,
      fallbackSeason: mapping.seasonNumber
    )
    mapping.subjectKey = selection.subjectKey
    mapping.showName = selection.showName
    manualOrganizeOriginalTitle = selection.originalTitle
    manualOrganizeYear = selection.year.map(String.init) ?? ""
    mapping.seasonNumber = selection.seasonNumber
  }

  func changeManualOrganizeMediaType() {
    invalidateManualHistoryOrganizePreview()
    manualOrganizeSelectedCandidateID = nil
    metadataCandidates = []
    metadataWarnings = []
    mapping.subjectKey = metadataTargetID
  }

  func previewManualHistoryOrganize() async {
    guard let item = manualOrganizeHistoryItem else {
      publishManualOrganizeFailure(title: "无法生成整理预览", detail: "当前没有待整理的下载记录。")
      return
    }
    let showName = mapping.showName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !showName.isEmpty else {
      publishManualOrganizeFailure(title: "请确认番剧名称", detail: "番剧名称不能为空。")
      return
    }
    let yearText = manualOrganizeYear.trimmingCharacters(in: .whitespacesAndNewlines)
    let year = yearText.isEmpty ? nil : Int(yearText)
    guard yearText.isEmpty || year != nil else {
      publishManualOrganizeFailure(title: "年份格式不正确", detail: "年份应为四位数字，或留空。")
      return
    }
    let authoritativeScope = ManualOrganizeScope.resolve(history: item, parsed: parsedTitle)
    let requiresMultipleFiles = authoritativeScope.requiresMultipleFiles || manualOrganizeRequiresMultipleFiles || manualOrganizeIsBatch
    let episodeStartText = manualOrganizeMediaType == "movie" ? "" : manualOrganizeEpisodeStart.trimmingCharacters(in: .whitespacesAndNewlines)
    // A single episode has no editable range end; never submit a stale hidden value.
    let episodeEndText = manualOrganizeMediaType == "movie" ? "" : (requiresMultipleFiles ? manualOrganizeEpisodeEnd.trimmingCharacters(in: .whitespacesAndNewlines) : episodeStartText)
    let episodeStart = episodeStartText.isEmpty ? nil : Int(episodeStartText)
    let episodeEnd = episodeEndText.isEmpty ? nil : Int(episodeEndText)
    guard (episodeStartText.isEmpty || episodeStart != nil),
          (episodeEndText.isEmpty || episodeEnd != nil) else {
      publishManualOrganizeFailure(title: "集数格式不正确", detail: "集数应为正整数，或留空让文件名解析器逐项识别。")
      return
    }
    if let episodeStart, let episodeEnd, episodeStart > episodeEnd {
      publishManualOrganizeFailure(title: "集数范围不正确", detail: "起始集数不能大于结束集数。")
      return
    }
    guard let target = organizeTargets.first(where: { $0.id == manualOrganizeTargetID && $0.enabled }) else {
      publishManualOrganizeFailure(title: "缺少整理目标", detail: "请先在设置中启用至少一个整理目标。")
      return
    }

    mapping.showName = showName
    mapping.showYear = year
    mapping.seasonNumber = max(0, mapping.seasonNumber)
    var manualParsed = parsedTitle ?? ParsedAnimeTitle(originalTitle: originalFilename)
    manualParsed.originalTitle = originalFilename
    manualParsed.title = showName
    manualParsed.season = mapping.seasonNumber
    manualParsed.seasonNumber = mapping.seasonNumber
    manualParsed.effectiveSeasonNumber = mapping.seasonNumber
    manualParsed.episode = episodeStart
    manualParsed.episodeNumber = episodeStart
    manualParsed.episodeStart = episodeStart
    manualParsed.episodeEnd = episodeEnd ?? episodeStart
    manualParsed.seasonEpisodeStart = episodeStart
    manualParsed.seasonEpisodeEnd = episodeEnd ?? episodeStart
    manualParsed.isBatch = requiresMultipleFiles
    manualParsed.isMultiEpisode = requiresMultipleFiles
    if requiresMultipleFiles {
      manualParsed.resourceType = (episodeStart != nil && episodeEnd != nil && episodeStart != episodeEnd)
        ? "episode_range"
        : (manualParsed.resourceType == "episode_range" ? "episode_range" : "batch")
    }
    parsedTitle = manualParsed
    let currentPreview = organizePreview
    let fileMappingOverrides = (currentPreview?.fileMappings ?? []).map { row in
      OrganizePreviewFileOverride(
        id: row.id,
        seasonNumber: row.seasonNumber,
        episodeNumber: row.episodeNumber,
        isSpecial: row.isSpecial,
        skipped: row.status == "skipped"
      )
    }

    await runManualOrganizeOperation(
      "生成手动整理预览",
      failureTitle: "生成手动整理预览失败"
    ) { operationID in
      let preview = try await client.organizePreview(
        OrganizePreviewRequest(
          sourcePath: "",
          downloadRecordId: item.id,
          libraryRoot: target.path,
          organizeTargetId: target.id,
          originalFilename: originalFilename,
          parsedTitle: manualParsed,
          mapping: mapping,
          episodeTitle: nil,
          isSpecial: mapping.seasonNumber == 0,
          singleFileMode: currentPreview?.singleFileMode == "none" ? nil : currentPreview?.singleFileMode,
          fileMappingOverrides: fileMappingOverrides,
          mediaType: manualOrganizeMediaType,
          selectFiles: true
        )
      )
      guard manualOrganizeSequence.accepts(operationID) else { throw CancellationError() }
      organizePreview = preview
    }
  }

  func cancelManualHistoryOrganize() {
    showingManualHistoryOrganizeSheet = false
    resetManualHistoryOrganize()
  }

  func invalidateManualHistoryOrganizePreview() {
    guard showingManualHistoryOrganizeSheet else { return }
    _ = manualOrganizeSequence.begin()
    var state = manualOrganizeOperation
    state.finish()
    manualOrganizeOperation = state
    organizePreview = nil
    dismissManualOrganizeFeedback()
  }

  private func configureManualOrganizeFields(response: MetadataSearchResponse) {
    let parsed = response.parsedTitle ?? parsedTitle
    let scope = ManualOrganizeScope.resolve(history: manualOrganizeHistoryItem, parsed: parsed)
    applyManualOrganizeScope(scope)
    if metadataQuery == originalFilename,
       let parsedName = parsed?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       !parsedName.isEmpty {
      metadataQuery = parsedName
    }
    let selectedID = response.recommendedCandidateId ?? response.candidates.first?.id
    if let selectedID {
      selectManualHistoryMetadata(selectedID)
    } else {
      manualOrganizeSelectedCandidateID = nil
      mapping.showName = parsed?.title ?? ""
      manualOrganizeOriginalTitle = parsed?.title ?? ""
      mapping.seasonNumber = max(
        0,
        parsed?.explicitSeasonNumber ??
          parsed?.effectiveSeasonNumber ??
          parsed?.seasonNumber ??
          parsed?.season ??
          1
      )
    }
  }

  private func applyManualOrganizeScope(_ scope: ManualOrganizeScope) {
    manualOrganizeRequiresMultipleFiles = scope.requiresMultipleFiles
    manualOrganizeIsBatch = scope.requiresMultipleFiles
    manualOrganizeEpisodeStart = scope.episodeStart.map(String.init) ?? ""
    manualOrganizeEpisodeEnd = scope.episodeEnd.map(String.init) ?? ""
  }

  private func resetManualHistoryOrganize() {
    _ = manualOrganizeSequence.begin()
    manualOrganizeMediaType = "anime"
    organizePreview = nil
    parsedTitle = nil
    manualOrganizeHistoryItem = nil
    manualOrganizeSelectedCandidateID = nil
    manualOrganizeOriginalTitle = ""
    manualOrganizeYear = ""
    manualOrganizeEpisodeStart = ""
    manualOrganizeEpisodeEnd = ""
    manualOrganizeIsBatch = false
    manualOrganizeRequiresMultipleFiles = false
    manualOrganizeTargetID = nil
    var operation = manualOrganizeOperation
    operation.reset()
    manualOrganizeOperation = operation
    metadataCandidates = []
    metadataWarnings = []
    metadataRecommendedCandidateID = nil
    metadataSuggestedMapping = nil
    metadataMergeSummary = nil
  }

  func loadSchedulerStatus(silent: Bool = false) async {
    if silent {
      do {
        schedulerStatus = try await client.schedulerStatus()
        schedulerIntervalSeconds = schedulerStatus?.intervalSeconds ?? schedulerIntervalSeconds
      } catch {
        appendLog("读取自动刷新状态失败：\(error.localizedDescription)")
      }
      return
    }
    await run("读取自动刷新状态") {
      schedulerStatus = try await client.schedulerStatus()
      schedulerIntervalSeconds = schedulerStatus?.intervalSeconds ?? schedulerIntervalSeconds
    }
  }

  func startScheduler() async {
    await run("启动自动刷新", successTitle: "自动刷新已启动", successDetail: { "间隔 \(self.schedulerIntervalSeconds) 秒" }) {
      schedulerStatus = try await client.startScheduler(intervalSeconds: schedulerIntervalSeconds)
      schedulerIntervalSeconds = schedulerStatus?.intervalSeconds ?? schedulerIntervalSeconds
      appendLog("自动刷新已启动，间隔 \(schedulerIntervalSeconds) 秒。")
    }
  }

  func stopScheduler() async {
    await run("停止自动刷新", successTitle: "自动刷新已停止") {
      schedulerStatus = try await client.stopScheduler()
      appendLog("自动刷新已停止。")
    }
  }

  func loadBrush(silent: Bool = false) async {
    if silent {
      guard !silentBrushRefreshInFlight else { return }
      silentBrushRefreshInFlight = true
      defer { silentBrushRefreshInFlight = false }
      do {
        async let settings = client.brushSettings()
        async let status = client.brushStatus()
        async let tasks = client.brushTasks(includeArchived: showArchivedBrushTasks)
        async let runs = client.brushRuns()
        async let capabilities = client.brushCapabilities()
        async let accounts = client.brushSiteAccounts()
        brushSettings = try await settings
        brushStatus = try await status
        brushTasks = try await tasks
        brushRuns = try await runs
        brushCapabilities = try await capabilities
        if let loadedAccounts = try? await accounts { brushSiteAccounts = loadedAccounts }
      } catch {
        appendLog("刷新站点刷流状态失败：\(error.localizedDescription)")
      }
      return
    }
    await run("加载站点刷流", successDetail: { self.brushStatus?.message ?? "刷流状态已更新" }) {
      _ = try await client.refreshTaskState()
      async let settings = client.brushSettings()
      async let status = client.brushStatus()
      async let tasks = client.brushTasks(includeArchived: showArchivedBrushTasks)
      async let runs = client.brushRuns()
      async let capabilities = client.brushCapabilities()
      async let accounts = client.brushSiteAccounts()
      brushSettings = try await settings
      brushStatus = try await status
      brushTasks = try await tasks
      brushRuns = try await runs
      brushCapabilities = try await capabilities
      if let loadedAccounts = try? await accounts { brushSiteAccounts = loadedAccounts }
    }
  }

  func refreshBrushSiteAccounts(force: Bool = true) async {
    do {
      brushSiteAccounts = try await client.brushSiteAccounts(refresh: force)
    } catch {
      appendLog("刷新站点账户失败：\(error.localizedDescription)")
    }
  }

  func refreshBrushRuns() async {
    do {
      brushRuns = try await client.brushRuns()
    } catch {
      appendLog("刷新刷流运行记录失败：\(error.localizedDescription)")
    }
  }

  func refreshBrushRuntime() async {
    guard !silentBrushRefreshInFlight else { return }
    silentBrushRefreshInFlight = true
    defer { silentBrushRefreshInFlight = false }
    do {
      async let status = client.brushStatus()
      async let tasks = client.brushTasks(includeArchived: showArchivedBrushTasks)
      brushStatus = try await status
      brushTasks = try await tasks
    } catch {
      appendLog("刷新刷流任务状态失败：\(error.localizedDescription)")
    }
  }

  @discardableResult
  func saveBrushSettings(_ settings: BrushSettings? = nil) async -> Bool {
    let payload = settings ?? brushSettings
    return await run("保存刷流规则", successTitle: "刷流规则已保存", successDetail: { self.brushStatus?.message ?? "设置已生效" }) {
      brushStatus = try await client.saveBrushSettings(payload)
      brushSettings = try await client.brushSettings()
      appendLog("站点刷流规则已保存。")
    }
  }

  func startBrush() async {
    await run("启动站点刷流", successTitle: "站点刷流已启动") {
      brushStatus = try await client.startBrush()
      brushSettings = try await client.brushSettings()
      appendLog("站点刷流后台调度已启动。")
    }
  }

  func stopBrush() async {
    await run("停止站点刷流", successTitle: "站点刷流已停止") {
      brushStatus = try await client.stopBrush()
      brushSettings = try await client.brushSettings()
      appendLog("站点刷流后台调度已停止。")
    }
  }

  func runBrushNow() async {
    await run("立即执行刷流", successTitle: "刷流执行完成", successDetail: { self.brushRuns.first?.summary ?? "任务已完成" }) {
      let response = try await client.runBrushNow()
      brushStatus = response.status
      brushTasks = try await client.brushTasks(includeArchived: showArchivedBrushTasks)
      brushRuns = try await client.brushRuns()
      appendLog(response.message)
    }
  }

  func checkBrushNow() async {
    await run("检查刷流任务", successTitle: "刷流任务已检查") {
      let response = try await client.checkBrushNow()
      brushStatus = response.status
      brushTasks = try await client.brushTasks(includeArchived: showArchivedBrushTasks)
      brushRuns = try await client.brushRuns()
      appendLog(response.message)
    }
  }

  func manageBrushTask(_ task: BrushTask, action: String) async {
    var resultMessage = "刷流任务已更新"
    await run("管理刷流任务", successTitle: "刷流任务已更新", successDetail: { resultMessage }) {
      let response = try await client.manageBrushTask(id: task.id, action: action)
      resultMessage = response.message
      brushTasks = try await client.brushTasks(includeArchived: showArchivedBrushTasks)
      brushStatus = try await client.brushStatus()
      appendLog(response.message)
    }
  }

  func clearBrushRecords() async {
    await run("清理刷流记录", successTitle: "刷流记录已清理") {
      let response = try await client.clearBrushRecords()
      brushTasks = try await client.brushTasks(includeArchived: showArchivedBrushTasks)
      brushRuns = try await client.brushRuns()
      brushStatus = try await client.brushStatus()
      appendLog(response.message)
    }
  }

  func loadHistory(silent: Bool = false) async {
    if silent {
      guard !silentHistoryRefreshInFlight else { return }
      silentHistoryRefreshInFlight = true
      defer { silentHistoryRefreshInFlight = false }
      if let subscriptionID = selectedHistorySubscriptionID {
        do {
          history = try await client.history(subscriptionID: subscriptionID)
          await loadOverview(silent: true)
        } catch {
          appendLog("自动刷新下载进度失败：\(error.localizedDescription)")
        }
      } else {
        do {
          history = try await client.history()
          await loadOverview(silent: true)
        } catch {
          appendLog("自动刷新下载进度失败：\(error.localizedDescription)")
        }
      }
      return
    }
    await run("加载下载历史", successDetail: { "共 \(self.history.count) 条历史" }) {
      _ = try await client.refreshTaskState()
      if let subscriptionID = selectedHistorySubscriptionID {
        history = try await client.history(subscriptionID: subscriptionID)
      } else {
        history = try await client.history()
      }
      await loadOverview(silent: true)
    }
  }

  func manageHistory(_ item: DownloadHistory, action: String) async {
    guard !historyManagementIDs.contains(item.id) else { return }
    historyManagementIDs.insert(item.id)
    defer { historyManagementIDs.remove(item.id) }
    let label: String
    switch action {
    case "pause":
      label = "暂停下载任务"
    case "resume":
      label = "恢复下载任务"
    case "delete":
      label = "删除下载任务"
    case "delete_files":
      label = "删除下载任务和文件"
    case "readd":
      label = "重新添加下载任务"
    default:
      label = "管理下载任务"
    }
    await run(label, loadingDetail: item.title, successTitle: "\(label)完成", successDetail: { self.lastHistoryManageResponse?.message ?? "下载历史已更新" }, showsLoading: false) {
      lastHistoryManageResponse = try await client.manageHistory(id: item.id, action: action)
      if let subscriptionID = selectedHistorySubscriptionID {
        history = try await client.history(subscriptionID: subscriptionID)
      } else {
        history = try await client.history()
      }
      if let subscriptionID = selectedMatchSubscriptionID {
        selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscriptionID)
        subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      }
      appendLog(lastHistoryManageResponse?.message ?? "\(label)完成。")
    }
  }

  func deleteHistoryRecord(_ item: DownloadHistory) async {
    await run("删除下载记录", loadingDetail: item.title, successTitle: "下载记录已删除") {
      _ = try await client.deleteHistory(id: item.id)
      try await refreshHistoryRelatedState()
      appendLog("已删除下载记录：\(item.title)。")
    }
  }

  func clearDownloadHistory(deleteQbittorrentTasks: Bool = false, deleteFiles: Bool = false) async {
    let label: String
    if deleteFiles {
      label = "清空历史并删除文件"
    } else if deleteQbittorrentTasks {
      label = "清空历史并删除任务"
    } else {
      label = "清空下载历史"
    }
    await run(label, successTitle: "\(label)完成", successDetail: { self.lastHistoryClearResponse?.message ?? "下载历史已清理" }) {
      lastHistoryClearResponse = try await client.clearHistory(
        scope: "download",
        subscriptionID: selectedHistorySubscriptionID,
        deleteQbittorrentTasks: deleteQbittorrentTasks,
        deleteFiles: deleteFiles
      )
      lastHistoryClearResponse?.warnings.forEach { appendLog($0) }
      try await refreshHistoryRelatedState()
      appendLog(lastHistoryClearResponse?.message ?? "\(label)完成。")
    }
  }

  func clearAllHistory() async {
    await run("清空全部历史", successTitle: "全部历史已清空", successDetail: { self.lastHistoryClearResponse?.message ?? "所有历史状态已清理" }) {
      lastHistoryClearResponse = try await client.clearHistory(scope: "all")
      lastHistoryClearResponse?.warnings.forEach { appendLog($0) }
      selectedHistorySubscriptionID = nil
      try await refreshHistoryRelatedState()
      appendLog(lastHistoryClearResponse?.message ?? "全部历史已清空。")
    }
  }

  func resetSubscriptionState(_ subscription: Subscription) async {
    await run("重置订阅状态", loadingDetail: subscription.name, successTitle: "订阅状态已重置", successDetail: { self.lastResetSubscriptionResponse?.message ?? subscription.name }) {
      lastResetSubscriptionResponse = try await client.resetSubscription(id: subscription.id)
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "订阅状态已重置：\(subscription.name)。")
    }
  }

  func clearSubscriptionRecognition(_ subscription: Subscription) async {
    await run("清除识别结果", loadingDetail: subscription.name, successTitle: "识别结果已清除", successDetail: { self.lastResetSubscriptionResponse?.message ?? subscription.name }) {
      lastResetSubscriptionResponse = try await client.clearSubscriptionRecognition(id: subscription.id)
      await loadMetadataBindings()
      await loadPlexMappings()
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "已清除识别结果：\(subscription.name)。")
    }
  }

  func clearSubscriptionMatchHistory(_ subscription: Subscription) async {
    await run("清空匹配历史", loadingDetail: subscription.name, successTitle: "匹配历史已清空", successDetail: { self.lastResetSubscriptionResponse?.message ?? subscription.name }) {
      lastResetSubscriptionResponse = try await client.clearSubscriptionMatchHistory(id: subscription.id)
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "已清空匹配历史：\(subscription.name)。")
    }
  }

  func clearSubscriptionOrganizeRecords(_ subscription: Subscription) async {
    await run("清空整理记录", loadingDetail: subscription.name, successTitle: "整理记录已清空", successDetail: { self.lastResetSubscriptionResponse?.message ?? subscription.name }) {
      lastResetSubscriptionResponse = try await client.clearSubscriptionOrganizeRecords(id: subscription.id)
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "已清空整理记录：\(subscription.name)。")
    }
  }

  func deleteEpisodeDownloadRecord(subscriptionID: Int, matchID: Int) async {
    await run("删除单集下载记录", successTitle: "单集下载记录已删除", successDetail: { self.lastResetSubscriptionResponse?.message ?? "记录已删除" }) {
      lastResetSubscriptionResponse = try await client.deleteEpisodeDownloadRecord(subscriptionID: subscriptionID, matchID: matchID)
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "单集下载记录已删除。")
    }
  }

  func deleteEpisodeOrganizeRecord(subscriptionID: Int, matchID: Int) async {
    await run("删除单集整理记录", successTitle: "单集整理记录已删除", successDetail: { self.lastResetSubscriptionResponse?.message ?? "记录已删除" }) {
      lastResetSubscriptionResponse = try await client.deleteEpisodeOrganizeRecord(subscriptionID: subscriptionID, matchID: matchID)
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "单集整理记录已删除。")
    }
  }

  func resetEpisodeState(subscriptionID: Int, matchID: Int) async {
    await run("重置单集状态", successTitle: "单集状态已重置", successDetail: { self.lastResetSubscriptionResponse?.message ?? "状态已重置" }) {
      lastResetSubscriptionResponse = try await client.resetEpisodeState(subscriptionID: subscriptionID, matchID: matchID)
      try await refreshHistoryRelatedState()
      appendLog(lastResetSubscriptionResponse?.message ?? "单集状态已重置。")
    }
  }

  func clearSubscriptionHistory(_ subscription: Subscription, scope: String) async {
    let label: String
    switch scope {
    case "download":
      label = "清空订阅下载历史"
    case "all":
      label = "清空订阅刷新与下载历史"
    default:
      label = "清空订阅刷新历史"
    }
    await run(label, loadingDetail: subscription.name, successTitle: "\(label)完成", successDetail: { self.lastHistoryClearResponse?.message ?? subscription.name }) {
      lastHistoryClearResponse = try await client.clearSubscriptionHistory(id: subscription.id, scope: scope)
      try await refreshHistoryRelatedState()
      appendLog(lastHistoryClearResponse?.message ?? "\(label)：\(subscription.name)。")
    }
  }

  func searchMetadata() async {
    await searchMetadata(sources: ["bangumi", "tmdb"], operationLabel: "搜索番剧信息")
  }

  func searchBangumiMetadata() async {
    await searchMetadata(sources: ["bangumi"], operationLabel: "搜索 Bangumi")
  }

  func searchTMDBMetadata() async {
    await searchMetadata(sources: ["tmdb"], operationLabel: "搜索 TMDB")
  }

  private func searchMetadata(sources: [String], operationLabel: String) async {
    let query = metadataQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      setStatus(.empty, title: "请输入番剧关键词", detail: "番剧信息搜索条件为空。")
      return
    }
    await run(
      operationLabel,
      loadingDetail: query,
      successTitle: "\(operationLabel)完成",
      successDetail: { "\(self.metadataCandidates.count) 个候选" }
    ) {
      _ = try await loadMetadataCandidates(query: query, sources: sources)
    }
  }

  private func loadMetadataCandidates(query: String, sources: [String]) async throws -> MetadataSearchResponse {
    let response = try await client.metadataSearch(query: query, sources: sources)
    applyMetadataResponse(response)
    return response
  }

  func matchMetadata(for result: SearchResult) async {
    metadataTargetType = "resource"
    metadataTargetID = result.id.isEmpty ? result.title : result.id
    metadataQuery = result.title
    await run("识别番剧信息", loadingDetail: result.title, successTitle: "番剧信息识别完成", successDetail: { "\(self.metadataCandidates.count) 个候选" }) {
      let response = try await client.metadataMatch(title: result.title)
      originalFilename = result.title
      applyMetadataResponse(response)
      showingMetadataReview = true
    }
  }

  private func initialMetadataQuery(for subscription: Subscription) -> String? {
    let candidates = [subscription.name, subscription.keyword, subscription.aliases.first ?? ""]
    for raw in candidates {
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.isEmpty {
        continue
      }
      if value.hasPrefix("http://") || value.hasPrefix("https://") {
        continue
      }
      return value
    }
    return nil
  }

  func bind(_ candidate: MetadataCandidate, targetID: String? = nil) async {
    guard metadataBindingSubmissionGate.begin(candidateID: candidate.id) else { return }
    let bindOperationID = metadataBindSequence.begin()
    metadataBindingCandidateID = metadataBindingSubmissionGate.activeCandidateID
    defer {
      metadataBindingSubmissionGate.finish(candidateID: candidate.id)
      metadataBindingCandidateID = metadataBindingSubmissionGate.activeCandidateID
    }
    await run("保存番剧信息", successTitle: "番剧信息已保存", successDetail: { candidate.title }) {
      let effectiveTargetID = targetID ?? metadataTargetID
      let request = MetadataBindRequest(
        candidate: candidate,
        targetType: metadataTargetType,
        targetId: effectiveTargetID,
        notes: "macOS 客户端手动确认番剧信息"
      )
      _ = try await client.bindMetadata(request)
      guard metadataBindSequence.accepts(bindOperationID) else {
        throw CancellationError()
      }
      metadataBindings = try await client.metadataBindings()
      updateSubscriptions(try await client.subscriptions())
      let boundSubscriptionID = metadataTargetType == "subscription" ? Int(effectiveTargetID) : selectedMatchSubscriptionID
      if let subscriptionID = boundSubscriptionID {
        selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscriptionID)
        subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      }
      mapping.subjectKey = candidate.id
      mapping.showName = candidate.title
      if let airDate = candidate.airDate, let year = Int(airDate.prefix(4)) {
        mapping.showYear = year
      }
      if let season = candidate.seasonNumber {
        mapping.seasonNumber = season
      }
      showingMetadataReview = false
      appendLog("已保存 \(candidate.source): \(candidate.title) 到 \(effectiveTargetID)")
    }
  }

  func loadMetadataBindings() async {
    await run("加载番剧识别结果", successDetail: { "\(self.metadataBindings.count) 条识别结果" }) {
      metadataBindings = try await client.metadataBindings()
    }
  }

  func applySuggestedMapping() {
    guard let suggested = metadataSuggestedMapping else { return }
    mapping = suggested
    setStatus(.success, title: "已使用整理规则建议", detail: "\(suggested.showName) / Season \(suggested.seasonNumber)")
    appendLog("已使用 \(suggested.showName) 的整理规则建议。")
  }

  func saveSuggestedMappingAndPreview() async {
    guard let suggested = metadataSuggestedMapping else {
      setStatus(.empty, title: "没有可用的整理规则建议", detail: "请先搜索或识别番剧信息。")
      return
    }
    mapping = suggested
    await saveMappingAndPreview()
  }

  func parseCurrentTitle() async {
    let title = originalFilename.isEmpty ? metadataQuery : originalFilename
    guard !title.isEmpty else {
      setStatus(.empty, title: "请输入标题", detail: "没有可解析的资源标题。")
      return
    }
    await run("解析标题", loadingDetail: title, successTitle: "标题解析完成") {
      parsedTitle = try await client.parseTitle(title)
    }
  }

  func saveMappingAndPreview() async {
    guard !mapping.showName.isEmpty else {
      setStatus(.empty, title: "缺少整理规则", detail: "请先确认番剧名称和 Season。")
      return
    }
    await run("生成整理预览", successTitle: "整理预览已生成", successDetail: { self.organizePreview?.destinationPreview ?? "已保存预览记录" }) {
      _ = try await client.saveMapping(mapping)
      await loadPlexMappings()
      let filename = originalFilename.isEmpty ? "\(mapping.showName).mkv" : originalFilename
      let target = previewOrganizeTarget
      let effectiveLibraryRoot = target?.path ?? libraryRoot
      let effectiveSourcePath = sourcePath.isEmpty ? sourcePathForOriginalFilename(filename) : sourcePath
      organizePreview = try await client.organizePreview(
        OrganizePreviewRequest(
          sourcePath: effectiveSourcePath,
          downloadRecordId: nil,
          libraryRoot: effectiveLibraryRoot,
          organizeTargetId: target?.id,
          originalFilename: filename,
          parsedTitle: parsedTitle,
          mapping: mapping,
          episodeTitle: episodeTitle.isEmpty ? nil : episodeTitle,
          isSpecial: mapping.seasonNumber == 0
        )
      )
      await loadOrganizePreviews()
      showingBatchOrganizeSheet = organizePreview?.isBatch == true
    }
  }

  func regenerateOrganizePreview() async {
    guard let preview = organizePreview, !isApplyingOrganizePreview, !isLoading else { return }
    await run("更新整理预览") {
      guard let previewID = preview.previewId else {
        throw AppStoreError.userFacing("原始预览记录不可用，请从下载历史重新发起手动整理。")
      }
      let records = try await client.organizePreviews()
      guard var request = records.first(where: { $0.id == previewID })?.request else {
        throw AppStoreError.userFacing("原始预览已删除，请从下载历史重新发起手动整理。")
      }
      request.singleFileMode = preview.singleFileMode == "none" ? nil : preview.singleFileMode
      request.fileMappingOverrides = (preview.fileMappings ?? []).map { row in
        OrganizePreviewFileOverride(id: row.id, seasonNumber: row.seasonNumber,
          episodeNumber: row.episodeNumber, isSpecial: row.isSpecial, skipped: row.status == "skipped")
      }
      organizePreview = try await client.organizePreview(request)
    }
  }

  func applyOrganizePreview() async {
    guard !isApplyingOrganizePreview else { return }
    guard let preview = organizePreview else {
      setStatus(.empty, title: "无法执行整理", detail: "请先生成或载入整理预览。")
      return
    }
    if showingManualHistoryOrganizeSheet, preview.canApply != true {
      publishManualOrganizeFailure(title: "请更新整理预览", detail: preview.blockReason ?? "当前预览尚未通过校验。")
      return
    }
    isApplyingOrganizePreview = true
    defer { isApplyingOrganizePreview = false }
    let manualHistory = manualOrganizeHistoryItem
    let manualCandidate = manualOrganizeSelectedCandidateID.flatMap { candidateID in
      metadataCandidates.first(where: { $0.id == candidateID })
    }
    var applied = false
    await run("执行整理", loadingDetail: preview.destinationPreview, successTitle: "整理执行完成", successDetail: { self.lastOrganizeApplyResponse?.message ?? "文件已处理" }) {
      let response = try await client.organizeApply(
        OrganizeApplyRequest(
          preview: preview,
          confirmRealMove: true
        )
      )
      lastOrganizeApplyResponse = response
      appendLog("\(response.message)：\(response.destinationPath)")
      guard response.ok else {
        if manualHistory != nil {
          publishManualOrganizeFailure(title: "整理未全部完成", detail: response.message)
        }
        throw APIClientError.server(409, response.message)
      }
      sourcePath = response.destinationPath
      applied = true
      showingBatchOrganizeSheet = false
      do {
        organizeHistory = try await client.organizeHistory()
        if let subscriptionID = selectedMatchSubscriptionID {
          selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscriptionID)
          subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
        }
      } catch {
        appendLog("整理已完成，刷新列表失败：\(error.localizedDescription)")
      }
      await loadOverview(silent: true)
    }
    guard applied else { return }

    if let manualHistory, let manualCandidate {
      do {
        _ = try await client.bindMetadata(
          MetadataBindRequest(
            candidate: manualCandidate,
            targetType: "resource",
            targetId: "download-history:\(manualHistory.id)",
            selectedTitle: mapping.showName,
            originalTitle: manualOrganizeOriginalTitle.isEmpty ? manualCandidate.originalTitle : manualOrganizeOriginalTitle,
            notes: "macOS 客户端手动整理确认"
          )
        )
        metadataBindings = try await client.metadataBindings()
      } catch {
        appendLog("整理已完成，但保存手动任务番剧绑定失败：\(error.localizedDescription)")
      }
    }
    if manualHistory != nil {
      showingManualHistoryOrganizeSheet = false
      resetManualHistoryOrganize()
      await loadHistory(silent: true)
    }
  }

  func updateOrganizePreviewMapping(
    id: String,
    seasonNumber: Int? = nil,
    episodeNumber: Int? = nil,
    isSpecial: Bool? = nil,
    skipped: Bool? = nil
  ) {
    guard var preview = organizePreview,
          var mappings = preview.fileMappings,
          let index = mappings.firstIndex(where: { $0.id == id }) else {
      return
    }
    var row = mappings[index]
    if let seasonNumber {
      row.seasonNumber = max(0, seasonNumber)
    }
    if let episodeNumber {
      row.episodeNumber = max(1, episodeNumber)
      row.manualOverride = row.parsedEpisode != row.episodeNumber
      row.overrideReason = row.manualOverride ? "用户在合集整理预览中修改集数" : row.overrideReason
    }
    if let isSpecial {
      row.isSpecial = isSpecial
      if isSpecial {
        row.seasonNumber = 0
      } else if row.seasonNumber == 0 {
        row.seasonNumber = max(1, preview.fileMappings?[index].seasonNumber ?? 1)
      }
    }
    if let skipped {
      let missingEpisode = preview.mediaType != "movie" && row.episodeNumber == nil
      row.status = skipped ? "skipped" : (missingEpisode ? "needs_confirmation" : "ready")
      row.message = skipped ? "已跳过" : (missingEpisode ? "需要确认集数" : "可整理")
    } else if row.status != "skipped" {
      row.status = row.episodeNumber == nil ? "needs_confirmation" : "ready"
      row.message = row.episodeNumber == nil ? "需要确认集数" : "可整理"
    }
    row = refreshedOrganizePreviewMapping(row, preview: preview)
    mappings[index] = row
    preview.fileMappings = mappings
    if showingManualHistoryOrganizeSheet {
      preview.canApply = false
      preview.blockReason = "文件映射已修改，请重新生成预览，让后端校验目标路径和冲突状态。"
    }
    organizePreview = preview
  }

  private func refreshedOrganizePreviewMapping(_ row: OrganizePreviewFileMapping, preview: OrganizePreviewItem) -> OrganizePreviewFileMapping {
    guard preview.mediaType != "movie" else { return row }
    guard row.status != "skipped", let episode = row.episodeNumber else { return row }
    var updated = row
    let extensionName = URL(fileURLWithPath: row.originalFilename).pathExtension
    let suffix = extensionName.isEmpty ? "mkv" : extensionName
    let showName = preview.showDirectory.replacingOccurrences(of: #" \(\d{4}\)$"#, with: "", options: .regularExpression)
    updated.targetFilename = "\(showName) - S\(String(format: "%02d", row.seasonNumber))E\(String(format: "%02d", episode)).\(suffix)"
    updated.targetPath = URL(fileURLWithPath: preview.libraryRoot)
      .appendingPathComponent(preview.showDirectory)
      .appendingPathComponent("Season \(String(format: "%02d", row.seasonNumber))")
      .appendingPathComponent(updated.targetFilename)
      .path
    if let subtitleMappings = row.subtitleMappings {
      let targetStem = URL(fileURLWithPath: updated.targetFilename).deletingPathExtension().lastPathComponent
      let targetDirectory = URL(fileURLWithPath: updated.targetPath).deletingLastPathComponent()
      updated.subtitleMappings = subtitleMappings.map { mapping in
        var subtitle = mapping
        let targetFilename = "\(targetStem)\(mapping.languageSuffix)\(mapping.extension)"
        subtitle.targetFilename = targetFilename
        subtitle.targetPath = targetDirectory.appendingPathComponent(targetFilename).path
        return subtitle
      }
    }
    return updated
  }

  func updateSingleFileBatchMode(_ mode: String) {
    guard var preview = organizePreview else { return }
    let showName = preview.showDirectory.replacingOccurrences(of: #" \(\d{4}\)$"#, with: "", options: .regularExpression)
    let extensionName = URL(fileURLWithPath: preview.filename).pathExtension.isEmpty
      ? (URL(fileURLWithPath: preview.sourcePath).pathExtension.isEmpty ? "mkv" : URL(fileURLWithPath: preview.sourcePath).pathExtension)
      : URL(fileURLWithPath: preview.filename).pathExtension
    let season = Int(preview.seasonDirectory.filter(\.isNumber)) ?? 1
    let start = preview.episodeStart ?? 1
    let end = preview.episodeEnd ?? start
    let seasonDirectory: String
    let filename: String
    switch mode {
    case "episode_range":
      seasonDirectory = "Season \(String(format: "%02d", season))"
      filename = "\(showName) - S\(String(format: "%02d", season))E\(String(format: "%02d", start))-E\(String(format: "%02d", end)).\(extensionName)"
    case "specials_batch":
      seasonDirectory = "Specials"
      filename = "\(showName) - Batch.\(extensionName)"
    default:
      seasonDirectory = "Season \(String(format: "%02d", season))"
      filename = "\(showName) - Batch.\(extensionName)"
    }
    preview.singleFileMode = mode
    preview.seasonDirectory = seasonDirectory
    preview.filename = filename
    preview.destinationPreview = URL(fileURLWithPath: preview.libraryRoot)
      .appendingPathComponent(preview.showDirectory)
      .appendingPathComponent(seasonDirectory)
      .appendingPathComponent(filename)
      .path
    if let subtitleMappings = preview.subtitleMappings {
      let targetStem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
      let targetDirectory = URL(fileURLWithPath: preview.destinationPreview).deletingLastPathComponent()
      preview.subtitleMappings = subtitleMappings.map { mapping in
        var subtitle = mapping
        let targetFilename = "\(targetStem)\(mapping.languageSuffix)\(mapping.extension)"
        subtitle.targetFilename = targetFilename
        subtitle.targetPath = targetDirectory.appendingPathComponent(targetFilename).path
        return subtitle
      }
    }
    if showingManualHistoryOrganizeSheet {
      preview.canApply = false
      preview.blockReason = "目标命名已修改，请重新生成预览，让后端校验目标路径和冲突状态。"
    }
    organizePreview = preview
  }

  func loadPlexMappings() async {
    await run("加载整理规则", successDetail: { "\(self.plexMappings.count) 条整理规则" }) {
      plexMappings = try await client.plexMappings()
    }
  }

  func applyPlexMappingRecord(_ record: PlexMappingRecord) {
    mapping = record.mapping
    setStatus(.success, title: "已套用整理规则", detail: "\(record.mapping.showName) / Season \(record.mapping.seasonNumber)")
    appendLog("已套用整理规则：\(record.mapping.showName) / Season \(record.mapping.seasonNumber)。")
  }

  func loadOrganizePreviews() async {
    await run("加载整理预览历史", successDetail: { "\(self.organizePreviewHistory.count) 条预览记录" }) {
      organizePreviewHistory = try await client.organizePreviews()
    }
  }

  func loadOrganizeHistory(subscriptionID: Int? = nil, status: String? = nil, search: String? = nil) async {
    await run("加载整理记录", successDetail: { "\(self.organizeHistory.count) 条执行记录" }) {
      organizeHistory = try await client.organizeHistory(subscriptionID: subscriptionID, status: status, search: search)
      organizeFailedCount = try await client.failedOrganizeHistorySummary(subscriptionID: subscriptionID).failedCount
    }
  }

  func deleteFailedOrganizeHistory(subscriptionID: Int? = nil) async {
    await run(
      "删除失败整理记录",
      successTitle: "失败记录已删除",
      successDetail: { self.lastFailedOrganizeHistoryDeleteResponse?.message ?? "失败记录已删除" }
    ) {
      lastFailedOrganizeHistoryDeleteResponse = try await client.deleteFailedOrganizeHistory(subscriptionID: subscriptionID)
      organizeFailedCount = 0
      appendLog(lastFailedOrganizeHistoryDeleteResponse?.message ?? "失败整理记录已删除。")
    }
  }

  func clearOrganizeHistory() async {
    await run("清空整理历史", successTitle: "整理历史已清空", successDetail: { self.lastOrganizeHistoryClearResponse?.message ?? "整理预览历史已清空" }) {
      lastOrganizeHistoryClearResponse = try await client.clearOrganizeHistory()
      organizePreviewHistory = []
      organizeHistory = []
      organizeFailedCount = 0
      organizePreview = nil
      appendLog(lastOrganizeHistoryClearResponse?.message ?? "整理历史已清空。")
      if let subscriptionID = selectedMatchSubscriptionID {
        selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscriptionID)
        subscriptionMatches = selectedSubscriptionDetail?.matches ?? subscriptionMatches
      }
    }
  }

  func selectPreviewRecord(_ record: OrganizePreviewRecord) {
    organizePreview = record.preview
    sourcePath = record.request.sourcePath
    libraryRoot = record.request.libraryRoot
    originalFilename = record.request.originalFilename
    parsedTitle = record.request.parsedTitle
    mapping = record.request.mapping
    episodeTitle = record.request.episodeTitle ?? ""
    setStatus(.success, title: "已加载整理预览", detail: "#\(record.id)")
    appendLog("已加载整理预览 #\(record.id)。")
  }

  func pendingFileMappings(for preview: OrganizePreviewItem) -> [OrganizePreviewFileMapping] {
    guard let record = organizePreviewHistory.first(where: { $0.id == preview.previewId }),
          let remaining = record.remainingSourcePaths else {
      return preview.fileMappings ?? []
    }
    let sources = Set(remaining)
    return (preview.fileMappings ?? []).filter { sources.contains($0.sourcePath) }
  }

  func clearLogs() {
    logs.removeAll()
    setStatus(.idle, title: "日志已清空", detail: "本地操作日志列表已清空。")
  }

  @discardableResult
  private func runManualOrganizeOperation(
    _ label: String,
    failureTitle: String,
    operation: (UInt64) async throws -> Void
  ) async -> Bool {
    guard !manualOrganizeOperation.isRunning else { return false }
    let operationID = manualOrganizeSequence.begin()
    var state = manualOrganizeOperation
    state.begin()
    manualOrganizeOperation = state
    do {
      try await operation(operationID)
      guard manualOrganizeSequence.accepts(operationID) else { return false }
      state = manualOrganizeOperation
      state.finish()
      manualOrganizeOperation = state
      return true
    } catch is CancellationError {
      guard manualOrganizeSequence.accepts(operationID) else { return false }
      state = manualOrganizeOperation
      state.finish()
      manualOrganizeOperation = state
      return false
    } catch {
      guard manualOrganizeSequence.accepts(operationID) else { return false }
      let message = error.localizedDescription
      state = manualOrganizeOperation
      state.fail(title: failureTitle, detail: message)
      manualOrganizeOperation = state
      appendLog("\(label)失败：\(message)")
      return false
    }
  }

  func dismissManualOrganizeFeedback() {
    var state = manualOrganizeOperation
    state.dismiss()
    manualOrganizeOperation = state
  }

  private func publishManualOrganizeFailure(title: String, detail: String) {
    var state = manualOrganizeOperation
    state.fail(title: title, detail: detail)
    manualOrganizeOperation = state
    appendLog("\(title)：\(detail)")
  }

  @discardableResult
  private func run(
    _ label: String,
    loadingDetail: String? = nil,
    successTitle: String? = nil,
    successDetail: (() -> String)? = nil,
    showsLoading: Bool = true,
    operation: () async throws -> Void
  ) async -> Bool {
    let parentOperationID = AppOperationContext.identifier
    let publishesStatus = showsLoading && parentOperationID == nil
    let operationID = parentOperationID ?? operationSequence.begin()
    let previousStatus = operationStatus
    if publishesStatus {
      beginOperation(operationID, label: label, detail: loadingDetail)
    }
    return await AppOperationContext.$identifier.withValue(operationID) {
      defer {
        if publishesStatus {
          endOperation(operationID)
        }
      }
      do {
        try await operation()
        if publishesStatus, operationSequence.accepts(operationID) {
          let detail = successDetail?() ?? "最后更新：\(DateFormatter.statusTime.string(from: Date()))"
          setStatus(.success, title: successTitle ?? "\(label)完成", detail: detail)
        }
        return true
      } catch is CancellationError {
        if publishesStatus, operationSequence.accepts(operationID) {
          operationStatus = previousStatus
        }
        return false
      } catch {
        let message = error.localizedDescription
        if publishesStatus, operationSequence.accepts(operationID) {
          setStatus(.failed, title: "\(label)失败", detail: message)
        }
        appendLog("\(label)失败：\(message)")
        return false
      }
    }
  }

  private func beginOperation(_ operationID: UInt64, label: String, detail: String?) {
    activeOperationLabels[operationID] = label
    isLoading = true
    activeOperationLabel = label
    setStatus(.loading, title: "\(label)中...", detail: detail ?? "正在处理，请稍候。")
  }

  private func endOperation(_ operationID: UInt64) {
    activeOperationLabels.removeValue(forKey: operationID)
    isLoading = !activeOperationLabels.isEmpty
    activeOperationLabel = activeOperationLabels.max(by: { $0.key < $1.key })?.value
  }

  private func setStatus(_ phase: OperationPhase, title: String, detail: String) {
    operationStatus = OperationStatus(
      phase: phase,
      title: title,
      detail: detail,
      updatedAt: Date()
    )
  }

  func appendLog(_ message: String) {
    logs.insert("[\(DateFormatter.logTime.string(from: Date()))] \(message)", at: 0)
    logs = Array(logs.prefix(100))
  }

  private func applyMetadataResponse(_ response: MetadataSearchResponse) {
    metadataCandidates = response.candidates
    metadataWarnings = response.warnings
    metadataRecommendedCandidateID = response.recommendedCandidateId
    metadataSuggestedMapping = response.suggestedMapping
    metadataMergeSummary = response.mergeSummary
    if let parsed = response.parsedTitle {
      parsedTitle = parsed
    }
    response.warnings.forEach { appendLog($0) }
  }

  private func splitComma(_ value: String) -> [String] {
    value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func splitLines(_ value: String) -> [String] {
    value
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func parseHeaderLines(_ value: String) -> [String: String]? {
    let lines = splitLines(value)
    guard !lines.isEmpty else { return [:] }
    var headers: [String: String] = [:]
    for line in lines {
      let separator = line.firstIndex(of: ":") ?? line.firstIndex(of: "=")
      guard let separator else { return nil }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { return nil }
      headers[key] = value
    }
    return headers
  }

  private func validSubscriptionEpisodeStart() -> Int? {
    let trimmed = subscriptionEpisodeStart.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      subscriptionEpisodeStart = "1"
      return 1
    }
    guard let value = Int(trimmed), value >= 1 else {
      return nil
    }
    return value
  }

  private func updateSubscriptions(_ values: [Subscription]) {
    subscriptions = values
    syncMikanProjectSubscriptionMarkers(with: values)
    let ids = Set(values.map(\.id))
    if let selectedID = selectedHistorySubscriptionID, !ids.contains(selectedID) {
      selectedHistorySubscriptionID = nil
      appendLog("已清除不存在的下载历史筛选。")
    }
    if let selectedID = selectedMatchSubscriptionID, !ids.contains(selectedID) {
      selectedMatchSubscriptionID = nil
      selectedSubscriptionDetail = nil
      subscriptionMatches = []
      appendLog("已清除不存在的订阅详情选择。")
    }
    if let editingID = editingSubscriptionID, !ids.contains(editingID) {
      resetSubscriptionForm(keepingKeyword: subscriptionKeyword)
      appendLog("正在编辑的订阅已不存在，已退出编辑。")
    }
  }

  private func syncMikanProjectSubscriptionMarkers(with values: [Subscription]) {
    var subscribedIDs = Set<String>()
    var legacyTitles = Set<String>()
    for subscription in values {
      let stableIDs = mikanBangumiIDs(from: subscription)
      if stableIDs.count == 1 {
        subscribedIDs.formUnion(stableIDs)
      } else if stableIDs.isEmpty, subscription.sites.contains("mikan") {
        legacyTitles.formUnion(
          mikanSubscriptionTitleKeys([subscription.name, subscription.keyword] + subscription.aliases.map(Optional.some))
        )
      }
    }

    if var season = mikanProjectSeason {
      for sectionIndex in season.sections.indices {
        for itemIndex in season.sections[sectionIndex].items.indices {
          let anime = season.sections[sectionIndex].items[itemIndex]
          let bangumiID = anime.bangumiId
          let titleMatch = !mikanSubscriptionTitleKeys([anime.title, anime.originalTitle]).isDisjoint(with: legacyTitles)
          season.sections[sectionIndex].items[itemIndex].subscribed = subscribedIDs.contains(bangumiID) || titleMatch
        }
      }
      mikanProjectSeason = season
    }

    for key in Array(mikanProjectResources.keys) {
      guard var response = mikanProjectResources[key], var anime = response.anime else { continue }
      let titleMatch = !mikanSubscriptionTitleKeys([anime.title, anime.originalTitle]).isDisjoint(with: legacyTitles)
      anime.subscribed = subscribedIDs.contains(anime.bangumiId) || titleMatch
      response.anime = anime
      mikanProjectResources[key] = response
    }
  }

  private func mikanBangumiIDs(from subscription: Subscription) -> Set<String> {
    Set(
      [subscription.mikanBangumiUrl, subscription.sourceUrl, subscription.identityKey]
        .compactMap(mikanBangumiID)
    )
  }

  private func mikanBangumiID(from rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty else { return nil }
    let identityPrefix = "mikan:bangumi:"
    if value.lowercased().hasPrefix(identityPrefix) {
      let id = String(value.dropFirst(identityPrefix.count))
      return id.allSatisfy(\.isNumber) ? id : nil
    }
    for marker in ["/Home/Bangumi/", "/Bangumi/"] {
      guard let range = value.range(of: marker, options: [.caseInsensitive]) else { continue }
      let tail = value[range.upperBound...]
      let id = tail.components(separatedBy: CharacterSet(charactersIn: "/?#&")).first ?? ""
      if !id.isEmpty, id.allSatisfy(\.isNumber) {
        return id
      }
    }
    let queryItems = URLComponents(string: value)?.queryItems ?? []
    return queryItems.first(where: {
      ["bangumiid", "bangumi_id"].contains($0.name.lowercased()) && ($0.value?.allSatisfy(\.isNumber) == true)
    })?.value
  }

  private func mikanSubscriptionTitleKeys(_ values: [String?]) -> Set<String> {
    let separators = CharacterSet(charactersIn: "/／|｜;；")
    return Set(
      values
        .compactMap { $0 }
        .flatMap { $0.components(separatedBy: separators) }
        .map {
          $0.precomposedStringWithCompatibilityMapping
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        }
        .filter { !$0.isEmpty }
    )
  }

  private func sourcePathForMatch(_ match: SubscriptionMatch) -> String? {
    guard let detail = selectedSubscriptionDetail else {
      return nil
    }
    let history = detail.history.first { $0.fingerprint == match.fingerprint } ??
      detail.history.first { $0.title == match.result.title || $0.torrentName == match.result.title }
    guard let history else {
      return nil
    }
    if let savePath = history.savePath, !savePath.isEmpty {
      let fileName = history.torrentName?.isEmpty == false ? history.torrentName! : history.title
      return appendFileName(fileName, to: savePath)
    }
    return nil
  }

  private func sourcePathForOriginalFilename(_ filename: String) -> String {
    let history = selectedSubscriptionDetail?.history.first { $0.title == filename || $0.torrentName == filename }
    if let savePath = history?.savePath, !savePath.isEmpty {
      let fileName = history?.torrentName?.isEmpty == false ? history!.torrentName! : filename
      return appendFileName(fileName, to: savePath)
    }
    if let savePath = selectedSubscriptionDetail?.subscription.savePath, !savePath.isEmpty {
      let folderPath = appendFolderIfNeeded(selectedSubscriptionDetail?.subscription.name, to: savePath)
      return appendFileName(filename, to: folderPath)
    }
    return filename
  }

  private func appendFolderIfNeeded(_ folderName: String?, to basePath: String) -> String {
    guard let folderName, !folderName.isEmpty else {
      return basePath
    }
    let safeFolder = folderName
      .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeFolder.isEmpty else {
      return basePath
    }
    let lastComponent = URL(fileURLWithPath: basePath).lastPathComponent
    if lastComponent.localizedCaseInsensitiveCompare(safeFolder) == .orderedSame {
      return basePath
    }
    if basePath.hasSuffix("/") {
      return "\(basePath)\(safeFolder)"
    }
    return "\(basePath)/\(safeFolder)"
  }

  private func appendFileName(_ fileName: String, to savePath: String) -> String {
    let lastComponent = URL(fileURLWithPath: savePath).lastPathComponent
    if lastComponent == fileName {
      return savePath
    }
    if savePath.hasSuffix("/") {
      return "\(savePath)\(fileName)"
    }
    return "\(savePath)/\(fileName)"
  }

  private func refreshHistoryRelatedState() async throws {
    if let subscriptionID = selectedHistorySubscriptionID {
      history = try await client.history(subscriptionID: subscriptionID)
    } else {
      history = try await client.history()
    }
    if let subscriptionID = selectedMatchSubscriptionID,
       subscriptions.contains(where: { $0.id == subscriptionID }) {
      selectedSubscriptionDetail = try await client.subscriptionDetail(id: subscriptionID)
      subscriptionMatches = selectedSubscriptionDetail?.matches ?? []
    }
    updateSubscriptions(try await client.subscriptions())
    organizePreviewHistory = try await client.organizePreviews()
  }

  func subscriptionPayloadFromForm(keyword: String) throws -> SubscriptionCreate {
    let name = subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines)
    let season = Int(subscriptionSeason.trimmingCharacters(in: .whitespacesAndNewlines))
    let episodeStart = validSubscriptionEpisodeStart() ?? 1
    let episodeOffset = Int(subscriptionEpisodeOffset.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let totalEpisodes = Int(subscriptionTotalEpisodes.trimmingCharacters(in: .whitespacesAndNewlines))
    let totalEpisodesWasEdited = totalEpisodes != subscriptionTotalEpisodesBaseline
    let totalEpisodesSource = totalEpisodes == nil
      ? nil
      : (totalEpisodesWasEdited ? "manual" : (subscriptionTotalEpisodesSource ?? "manual"))
    let metadataEpisodeCount = totalEpisodesSource == "manual" ? nil : subscriptionMetadataEpisodeCount
    let tags = splitComma(subscriptionTags)
    let includeKeywords = try SubscriptionKeywordExpression.parse(subscriptionIncludeKeywords)
    let excludeKeywords = try SubscriptionKeywordExpression.parse(subscriptionExcludeKeywords)
    let sizeRange = try subscriptionSizeFilterDraft.resolvedRange()
    let resolutionChoice = subscriptionResolution.trimmingCharacters(in: .whitespacesAndNewlines)
    let customResolution = subscriptionResolutionCustom.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolutionMode: String
    let resolutionPreset: String?
    let resolutionCustom: String?
    let legacyResolution: String?
    if resolutionChoice == "custom" {
      if customResolution.isEmpty {
        resolutionMode = "any"
        resolutionPreset = nil
        resolutionCustom = nil
        legacyResolution = nil
      } else {
        resolutionMode = "custom"
        resolutionPreset = nil
        resolutionCustom = customResolution
        legacyResolution = customResolution
      }
    } else if resolutionChoice.isEmpty {
      resolutionMode = "any"
      resolutionPreset = nil
      resolutionCustom = nil
      legacyResolution = nil
    } else {
      resolutionMode = "preset"
      resolutionPreset = resolutionChoice
      resolutionCustom = nil
      legacyResolution = resolutionChoice
    }
    let inheritsOrganizePolicy = subscriptionPostOrganizeAction == "default"
    let usesCustomSeedingPolicy =
      subscriptionPostOrganizeAction == "keep_seeding" && subscriptionSeedingPolicyMode == "custom"
    return SubscriptionCreate(
      name: name.isEmpty ? keyword : name,
      keyword: keyword,
      sourceType: subscriptionSourceType,
      identityKey: subscriptionIdentityKey,
      sites: Array(selectedSiteIDs).sorted(),
      sourceUrl: subscriptionSourceType == "mikan_bangumi" ? nilIfEmpty(subscriptionSourceURL) : nil,
      mikanBangumiUrl: subscriptionSourceType == "mikan_bangumi" ? nilIfEmpty(subscriptionSourceURL) : nil,
      aliases: splitComma(subscriptionAliases),
      rssUrls: subscriptionSourceType == "rss" ? splitLines(subscriptionRSSURLs) : [],
      regex: nilIfEmpty(subscriptionRegex),
      regexEnabled: subscriptionRegexEnabled,
      episodeFilter: nilIfEmpty(subscriptionEpisodeFilter),
      includeKeywords: includeKeywords,
      excludeKeywords: excludeKeywords,
      filterOrder: subscriptionFilterOrder,
      fansub: nilIfEmpty(subscriptionFansub),
      resolution: legacyResolution,
      resolutionMode: resolutionMode,
      resolutionPreset: resolutionPreset,
      resolutionCustom: resolutionCustom,
      minSizeBytes: sizeRange.minimum,
      maxSizeBytes: sizeRange.maximum,
      season: season,
      episode: nil,
      episodeStart: episodeStart,
      episodeOffset: episodeOffset,
      batchResourcePolicy: "show_only",
      episodeParseRules: subscriptionUseCustomEpisodeRules ? normalizedEpisodeParseRules() : [],
      totalEpisodes: totalEpisodes,
      totalEpisodesSource: totalEpisodesSource,
      metadataEpisodeCount: metadataEpisodeCount,
      enabled: subscriptionEnabled,
      autoDownload: subscriptionAutoDownload,
      organizeTargetId: subscriptionOrganizeTargetID ?? defaultOrganizeTarget?.id,
      autoOrganize: subscriptionAutoOrganize,
      postOrganizeAction: inheritsOrganizePolicy ? nil : subscriptionPostOrganizeAction,
      deleteTaskAfterOrganize: nil,
      deleteFilesAfterOrganize: nil,
      keepSeeding: nil,
      seedingPolicyMode: usesCustomSeedingPolicy ? "custom" : "inherit",
      seedingStopRatio: usesCustomSeedingPolicy ? subscriptionSeedingRatioValue : nil,
      seedingStopMinutes: usesCustomSeedingPolicy ? subscriptionSeedingMinutesValue : nil,
      seedingStopMode: subscriptionSeedingStopMode,
      postSeedingAction: subscriptionPostSeedingAction,
      savePath: nilIfEmpty(subscriptionSavePath) ?? subscriptionDownloaderSavePath,
      category: nilIfEmpty(subscriptionCategory) ?? subscriptionDownloaderCategory,
      tags: tags.isEmpty ? subscriptionDownloaderTags : tags
    )
  }

  private func effectiveSubscriptionKeyword() -> String {
    let keyword = subscriptionKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    if !keyword.isEmpty {
      return keyword
    }
    return subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizedEpisodeParseRules() -> [EpisodeParseRule] {
    subscriptionEpisodeParseRules.enumerated().map { index, rule in
      EpisodeParseRule(
        id: rule.id,
        name: rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自定义规则 \(index + 1)" : rule.name,
        pattern: rule.pattern,
        enabled: rule.enabled,
        priority: index,
        episodeGroup: rule.episodeGroup,
        startGroup: rule.startGroup,
        endGroup: rule.endGroup,
        finalGroup: rule.finalGroup
      )
    }
  }

  private func normalizedGlobalEpisodeParseRules() -> [EpisodeParseRule] {
    globalEpisodeParseRules.enumerated().map { index, rule in
      EpisodeParseRule(
        id: rule.id,
        name: rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "全局规则 \(index + 1)" : rule.name,
        pattern: rule.pattern,
        enabled: rule.enabled,
        priority: index,
        episodeGroup: rule.episodeGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "episode" : rule.episodeGroup,
        startGroup: rule.startGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "start" : rule.startGroup,
        endGroup: rule.endGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "end" : rule.endGroup,
        finalGroup: rule.finalGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "final" : rule.finalGroup
      )
    }
  }

  private func subscriptionPayload(from subscription: Subscription) -> SubscriptionCreate {
    SubscriptionCreate(
      name: subscription.name,
      keyword: subscription.keyword,
      sourceType: subscription.sourceType ?? inferredSubscriptionSourceType(subscription),
      identityKey: subscription.identityKey,
      sites: subscription.sites,
      sourceUrl: subscription.sourceUrl,
      mikanBangumiUrl: subscription.mikanBangumiUrl,
      aliases: subscription.aliases,
      rssUrls: subscription.rssUrls,
      regex: subscription.regex,
      regexEnabled: subscription.regexEnabled,
      episodeFilter: subscription.episodeFilter,
      includeKeywords: subscription.includeKeywords,
      excludeKeywords: subscription.excludeKeywords,
      filterOrder: subscription.filterOrder,
      fansub: subscription.fansub,
      resolution: subscription.resolution,
      resolutionMode: subscription.resolutionMode ?? (subscription.resolution == nil ? "any" : "preset"),
      resolutionPreset: subscription.resolutionPreset,
      resolutionCustom: subscription.resolutionCustom,
      minSizeBytes: subscription.minSizeBytes,
      maxSizeBytes: subscription.maxSizeBytes,
      season: subscription.season,
      episode: subscription.episode,
      episodeStart: subscription.episodeStart,
      episodeOffset: subscription.episodeOffset,
      batchResourcePolicy: subscription.batchResourcePolicy ?? "show_only",
      episodeParseRules: subscription.episodeParseRules,
      totalEpisodes: subscription.totalEpisodes,
      totalEpisodesSource: subscription.totalEpisodesSource,
      metadataEpisodeCount: subscription.metadataEpisodeCount,
      enabled: subscription.enabled,
      autoDownload: subscription.autoDownload,
      organizeTargetId: subscription.organizeTargetId,
      autoOrganize: subscription.autoOrganize ?? false,
      postOrganizeAction: subscription.postOrganizeAction,
      deleteTaskAfterOrganize: subscription.deleteTaskAfterOrganize,
      deleteFilesAfterOrganize: subscription.deleteFilesAfterOrganize,
      keepSeeding: subscription.keepSeeding,
      seedingPolicyMode: subscription.seedingPolicyMode ?? "inherit",
      seedingStopRatio: subscription.seedingStopRatio,
      seedingStopMinutes: subscription.seedingStopMinutes,
      seedingStopMode: subscription.seedingStopMode ?? "any",
      postSeedingAction: subscription.postSeedingAction ?? "pause",
      savePath: subscription.savePath,
      category: subscription.category,
      tags: subscription.tags
    )
  }

  private func resetSubscriptionForm(keepingKeyword keyword: String) {
    editingSubscriptionID = nil
    editingSubscriptionVersion = nil
    subscriptionIdentityKey = nil
    isSmartSubscriptionExistingMatch = false
    smartSubscriptionFansubOptions = []
    subscriptionName = ""
    subscriptionSourceType = "keyword"
    subscriptionKeyword = keyword
    subscriptionSourceURL = ""
    subscriptionAliases = ""
    subscriptionRSSURLs = ""
    subscriptionRegex = ""
    subscriptionRegexEnabled = false
    subscriptionEpisodeFilter = ""
    subscriptionIncludeKeywords = ""
    subscriptionExcludeKeywords = ""
    subscriptionFilterOrder = "include_first"
    subscriptionFansub = ""
    subscriptionResolution = ""
    subscriptionResolutionCustom = ""
    subscriptionMinSize = ""
    subscriptionMinSizeUnit = .gigabytes
    subscriptionMaxSize = ""
    subscriptionMaxSizeUnit = .gigabytes
    subscriptionSeason = ""
    subscriptionEpisodeStart = "1"
    subscriptionEpisodeOffset = ""
    subscriptionUseCustomEpisodeRules = false
    subscriptionEpisodeParseRules = []
    subscriptionEpisodeRuleTestTitle = ""
    lastEpisodeRuleTestResponse = nil
    subscriptionTotalEpisodes = ""
    subscriptionTotalEpisodesSource = nil
    subscriptionTotalEpisodesBaseline = nil
    subscriptionMetadataEpisodeCount = nil
    subscriptionSavePath = ""
    subscriptionCategory = ""
    subscriptionTags = ""
    subscriptionEnabled = true
    applyNewSubscriptionBehaviorDefaults()
    subscriptionOrganizeTargetID = defaultOrganizeTarget?.id
    subscriptionAutoOrganize = organizePolicy.autoOrganizeByDefault && defaultOrganizeTarget != nil
    selectedSiteIDs = contentSiteIDs
    lastSmartPrefill = nil
    lastSubscriptionSuggestion = nil
  }

  private func applyNewSubscriptionBehaviorDefaults() {
    subscriptionAutoDownload = true
    subscriptionPostOrganizeAction = "default"
    subscriptionDeleteTaskAfterOrganize = organizePolicy.deleteTaskAfterOrganize
    subscriptionDeleteFilesAfterOrganize = organizePolicy.deleteFilesAfterOrganize
    subscriptionKeepSeeding = organizePolicy.keepSeeding
    applySubscriptionSeedingDraft(mode: "inherit", ratio: nil, minutes: nil, stopMode: nil, postAction: nil)
  }

  private static func subscriptionPostOrganizeAction(
    explicitAction: String?,
    deleteTask: Bool?,
    deleteFiles: Bool?,
    keepSeeding: Bool?
  ) -> String {
    if let explicitAction, !explicitAction.isEmpty {
      return explicitAction
    }
    guard deleteTask != nil || deleteFiles != nil || keepSeeding != nil else {
      return "default"
    }
    if keepSeeding == true {
      return "keep_seeding"
    }
    if deleteTask == true && deleteFiles == true {
      return "remove_task_delete_files"
    }
    if deleteTask == true {
      return "remove_task_keep_files"
    }
    return "manual"
  }

  private func inferredSubscriptionSourceType(_ subscription: Subscription) -> String {
    if !subscription.rssUrls.isEmpty {
      return "rss"
    }
    if subscription.mikanBangumiUrl != nil || subscription.sourceUrl != nil {
      return "mikan_bangumi"
    }
    return "keyword"
  }

  private static func validSubscriptionSourceType(_ value: String) -> String {
    switch value {
    case "keyword", "mikan_bangumi", "rss":
      return value
    default:
      return "keyword"
    }
  }

  private func resetOrganizeTargetForm() {
    editingOrganizeTargetID = nil
    organizeTargetName = ""
    organizeTargetPath = ""
    organizeTargetMediaType = "anime"
    organizeTargetIsDefault = false
    organizeTargetEnabled = true
    lastOrganizeTargetValidation = nil
  }
}

private extension DateFormatter {
  static let logTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}
