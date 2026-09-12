import Foundation

enum APIClientError: LocalizedError {
  case invalidBaseURL
  case invalidResponse
  case network(String)
  case operationTimedOut(String)
  case server(Int, String)
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      "后端地址无效，请检查设置里的 URL。"
    case .invalidResponse:
      "后端返回格式无效。"
    case .network(let message):
      "网络连接失败：\(message)"
    case .operationTimedOut(let message):
      message
    case .server(_, let message):
      message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "操作失败，请稍后重试。" : message
    case .decoding(let message):
      "响应解析失败：\(message)"
    }
  }
}

enum BackendEndpoint {
  static func normalizedString(_ rawValue: String) throws -> String {
    try normalizedURL(rawValue).absoluteString
  }

  static func connectionPort(_ rawValue: String) throws -> Int {
    let url = try normalizedURL(rawValue)
    if let port = url.port {
      return port
    }
    switch url.scheme?.lowercased() {
    case "http":
      return 80
    case "https":
      return 443
    default:
      throw APIClientError.invalidBaseURL
    }
  }

  static func normalizedURL(_ rawValue: String) throws -> URL {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
          var components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host,
          !host.isEmpty else {
      throw APIClientError.invalidBaseURL
    }
    guard components.user == nil, components.password == nil else {
      throw APIClientError.invalidBaseURL
    }
    guard components.query == nil, components.fragment == nil else {
      throw APIClientError.invalidBaseURL
    }
    guard components.path.isEmpty || components.path == "/" else {
      throw APIClientError.invalidBaseURL
    }
    if let port = components.port, !(1...65_535).contains(port) {
      throw APIClientError.invalidBaseURL
    }

    components.scheme = scheme
    components.path = ""
    guard let url = components.url else {
      throw APIClientError.invalidBaseURL
    }
    return url
  }

  static func isLocalNetworkURL(_ url: URL) -> Bool {
    guard let rawHost = url.host?.lowercased() else { return false }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".local") {
      return true
    }
    if host.contains(":") {
      return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9")
        || host.hasPrefix("fea") || host.hasPrefix("feb")
        || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }
    return octets[0] == 10
      || octets[0] == 127
      || (octets[0] == 169 && octets[1] == 254)
      || (octets[0] == 172 && (16...31).contains(octets[1]))
      || (octets[0] == 192 && octets[1] == 168)
  }
}

enum BackendHealthPresentation {
  private static let legacyAppName = "AnimePilot" // 旧后端品牌兼容

  static func statusText(health: HealthResponse, connectedURL: String) throws -> String {
    let port = try BackendEndpoint.connectionPort(connectedURL)
    return "\(displayAppName(reportedName: health.app)) \(health.version) · \(health.message) · 端口 \(port)"
  }

  static func displayAppName(reportedName: String) -> String {
    let normalized = reportedName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
      .lowercased()
    return normalized == legacyAppName.lowercased() ? "Kisetsu" : reportedName
  }
}

enum LocalNetworkErrorClassifier {
  static func containsAddressNotAvailable(_ error: NSError) -> Bool {
    let expectedCode = Int(POSIXErrorCode.EADDRNOTAVAIL.rawValue)
    var current: NSError? = error
    var visited = Set<ObjectIdentifier>()
    while let candidate = current {
      let identifier = ObjectIdentifier(candidate)
      guard visited.insert(identifier).inserted else { break }
      if candidate.domain == NSPOSIXErrorDomain, candidate.code == expectedCode {
        return true
      }
      let streamDomain = (candidate.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.intValue
      let streamCode = (candidate.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue
      if streamDomain == 1, streamCode == expectedCode {
        return true
      }
      current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}

private actor PlaylistReadSessionPool {
  static let shared = PlaylistReadSessionPool()
  private var session = makeSession()

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: configuration)
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let activeSession = session
    do {
      return try await activeSession.data(for: request)
    } catch {
      if LocalNetworkErrorClassifier.containsAddressNotAvailable(error as NSError),
         activeSession === session {
        activeSession.invalidateAndCancel()
        session = Self.makeSession()
      }
      throw error
    }
  }
}

private enum APIClientURLSessions {

  static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let method = request.httpMethod?.uppercased() ?? "GET"
    let components = request.url?.pathComponents.filter { $0 != "/" } ?? []
    if method == "GET", Array(components.prefix(2)) == ["api", "playlists"] {
      return try await PlaylistReadSessionPool.shared.data(for: request)
    }
    return try await URLSession.shared.data(for: request)
  }
}

struct APIClient {
  typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private static let transientPlaylistRetryDelayNanoseconds: UInt64 = 1_500_000_000

  var baseURL: String
  private let dataLoader: DataLoader

  init(
    baseURL: String,
    dataLoader: @escaping DataLoader = { request in
      try await APIClientURLSessions.data(for: request)
    }
  ) {
    self.baseURL = baseURL
    self.dataLoader = dataLoader
  }

  var rootURL: URL {
    get throws {
      try BackendEndpoint.normalizedURL(baseURL)
    }
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }

  private func request<Response: Decodable>(_ path: String, method: String = "GET") async throws -> Response {
    let url = try makeURL(path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    return try await perform(request)
  }

  private func request<Response: Decodable>(
    _ path: String,
    queryItems: [URLQueryItem]
  ) async throws -> Response {
    var url = try makeURL(path)
    if !queryItems.isEmpty {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw APIClientError.invalidBaseURL
      }
      components.queryItems = (components.queryItems ?? []) + queryItems
      guard let queryURL = components.url else {
        throw APIClientError.invalidBaseURL
      }
      url = queryURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    return try await perform(request)
  }

  func overview() async throws -> OverviewResponse {
    try await request("api/overview")
  }

  private func request<Body: Encodable, Response: Decodable>(
    _ path: String,
    method: String,
    body: Body,
    queryItems: [URLQueryItem] = []
  ) async throws -> Response {
    var url = try makeURL(path)
    if !queryItems.isEmpty {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw APIClientError.invalidBaseURL
      }
      components.queryItems = (components.queryItems ?? []) + queryItems
      guard let queryURL = components.url else {
        throw APIClientError.invalidBaseURL
      }
      url = queryURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(body)
    return try await perform(request)
  }

  func makeURL(_ path: String) throws -> URL {
    guard let relative = URLComponents(string: path),
          relative.scheme == nil,
          relative.host == nil,
          relative.fragment == nil,
          var components = URLComponents(url: try rootURL, resolvingAgainstBaseURL: false) else {
      throw APIClientError.invalidBaseURL
    }
    components.percentEncodedPath = "/" + relative.percentEncodedPath.trimmingCharacters(
      in: CharacterSet(charactersIn: "/")
    )
    components.percentEncodedQuery = relative.percentEncodedQuery
    guard let url = components.url else {
      throw APIClientError.invalidBaseURL
    }
    return url
  }

  private func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let payload: (Data, URLResponse)
    var retriedTransientPlaylistRead = false
    while true {
      do {
        payload = try await dataLoader(request)
        break
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as URLError {
        if Self.isCancellation(error) {
          throw CancellationError()
        }
        if !retriedTransientPlaylistRead,
           Self.shouldRetryTransientPlaylistRead(error, request: request) {
          retriedTransientPlaylistRead = true
          try await Task.sleep(nanoseconds: Self.transientPlaylistRetryDelayNanoseconds)
          continue
        }
        if error.code == .timedOut, let message = Self.operationTimeoutMessage(for: request) {
          throw APIClientError.operationTimedOut(message)
        }
        throw APIClientError.network(Self.networkErrorMessage(error, requestURL: request.url))
      } catch {
        throw APIClientError.network("请求未完成，请检查网络或后端服务状态。")
      }
    }
    let data = payload.0
    let response = payload.1
    guard let http = response as? HTTPURLResponse else {
      throw APIClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let message = extractErrorMessage(from: data) ?? httpStatusMessage(http.statusCode)
      throw APIClientError.server(http.statusCode, message)
    }
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw APIClientError.decoding(decodingErrorMessage(error))
    }
  }

  private static func shouldRetryTransientPlaylistRead(
    _ error: URLError,
    request: URLRequest
  ) -> Bool {
    guard request.httpMethod == "GET",
          let pathComponents = request.url?.pathComponents.filter({ $0 != "/" }),
          Array(pathComponents.prefix(2)) == ["api", "playlists"] else {
      return false
    }
    return LocalNetworkErrorClassifier.containsAddressNotAvailable(error as NSError)
  }

  static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }

  static func operationTimeoutMessage(for request: URLRequest) -> String? {
    guard let path = request.url?.path else { return nil }
    let method = request.httpMethod?.uppercased() ?? "GET"
    if path == "/api/subscriptions/refresh_all" || path == "/api/subscriptions/refresh-all" {
      return "全部订阅刷新等待超时。后端可能仍在处理，请稍后重新加载订阅状态。"
    }
    let components = path.split(separator: "/")
    if components.count == 4,
       components[0] == "api",
       components[1] == "subscriptions",
       Int(components[2]) != nil,
       components[3] == "refresh" {
      return "订阅刷新等待超时。后端可能仍在处理，请稍后重新加载订阅状态。"
    }
    if path == "/api/subscriptions", method == "POST" {
      return "创建订阅等待超时。后端可能已经保存，请稍后重新加载订阅列表确认。"
    }
    if components.count == 3,
       components[0] == "api",
       components[1] == "subscriptions",
       Int(components[2]) != nil,
       method == "PUT" {
      return "保存订阅等待超时。后端可能已经更新，请稍后重新加载订阅列表确认。"
    }
    if method == "GET",
       components.count >= 2,
       components[0] == "api",
       components[1] == "playlists" {
      return "播放列表数据加载超时。该页面请求未完成，但不代表后端已经断开；请稍后重试。"
    }
    return nil
  }

  static func networkErrorMessage(_ error: URLError, requestURL: URL?) -> String {
    let isLocalNetwork = requestURL.map(BackendEndpoint.isLocalNetworkURL) ?? false
    let streamErrorCode = error.userInfo["_kCFStreamErrorCodeKey"] as? Int
    return switch error.code {
    case .badURL, .unsupportedURL:
      "后端地址格式不正确，请检查设置里的 URL。"
    case .cannotFindHost:
      "找不到后端主机，请检查地址是否正确。"
    case .cannotConnectToHost:
      if isLocalNetwork {
        "局域网主机可定位，但后端端口拒绝连接；请确认服务监听局域网接口且端口正确。"
      } else {
        "无法连接后端，请确认服务已启动且端口正确。"
      }
    case .networkConnectionLost:
      "连接中断，请重试。"
    case .notConnectedToInternet:
      if isLocalNetwork {
        if streamErrorCode == 50 {
          "macOS 当前禁止 Kisetsu 访问本地网络；请检查“隐私与安全性 → 本地网络”权限后重新打开 App。"
        } else {
          "没有到局域网后端的可用路由；请确认两台设备位于可互通的网络、目标设备在线，并检查防火墙。"
        }
      } else {
        "当前网络不可用，请检查网络连接。"
      }
    case .timedOut:
      if isLocalNetwork {
        "局域网后端响应超时；请确认目标设备在线、地址可达且防火墙允许该端口。"
      } else {
        "请求超时，请确认后端仍在运行。"
      }
    case .dataNotAllowed:
      "系统不允许当前网络请求；请在 macOS“隐私与安全性 → 本地网络”中允许 Kisetsu 访问。"
    case .appTransportSecurityRequiresSecureConnection:
      "macOS 安全策略拒绝了此 HTTP 地址；请使用 HTTPS，或确认该地址属于允许访问的本地网络。"
    case .secureConnectionFailed, .serverCertificateHasBadDate,
         .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid, .clientCertificateRejected,
         .clientCertificateRequired:
      "HTTPS 安全连接失败，请检查后端证书和系统时间。"
    case .cancelled:
      "请求已取消。"
    default:
      "请求未完成（\(error.code.rawValue)），请检查后端服务状态。"
    }
  }

  private func decodingErrorMessage(_ error: Error) -> String {
    if let decodingError = error as? DecodingError {
      switch decodingError {
      case .keyNotFound(let key, _):
        return "后端响应缺少字段 \(key.stringValue)，请确认后端与客户端版本一致。"
      case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        if path.isEmpty {
          return "后端响应内容无法解析，请确认后端与客户端版本一致。"
        }
        return "后端响应字段 \(path) 无法解析，请确认后端与客户端版本一致。"
      @unknown default:
        return "后端响应结构无法解析，请确认后端与客户端版本一致。"
      }
    }
    return "后端响应结构无法解析，请确认后端与客户端版本一致。"
  }

  private func httpStatusMessage(_ statusCode: Int) -> String {
    switch statusCode {
    case 400:
      return "请求内容无效，请检查表单字段后重试。"
    case 401, 403:
      return "没有权限执行此操作，请检查配置或访问权限。"
    case 404:
      return "请求的资源不存在，可能已被删除或地址不正确。"
    case 409:
      return "当前状态冲突，请刷新后重试。"
    case 422:
      return "请求参数无效，请检查必填字段和格式。"
    case 500:
      return "后端内部错误，请查看日志后重试。"
    case 502:
      return "后端调用外部服务失败，请检查下载器、站点或网络。"
    case 503:
      return "后端服务暂不可用，请稍后重试。"
    case 504:
      return "后端请求超时，请稍后重试。"
    default:
      return "后端请求失败，请稍后重试。"
    }
  }

  private func extractErrorMessage(from data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    if
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      if let message = object["message"] as? String {
        return message
      }
      if let detail = object["detail"] as? String {
        return detail
      }
      if let detail = object["detail"] {
        if let details = detail as? [[String: Any]], !details.isEmpty {
          return "请求参数无效，请检查必填字段和格式。"
        }
        if let detailObject = detail as? [String: Any],
           let message = detailObject["message"] as? String {
          return message
        }
        return "操作失败，后端没有提供可读说明。"
      }
      if let error = object["error"] as? String {
        return error
      }
      return "操作失败，后端没有提供可读说明。"
    }
    guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty,
          !text.hasPrefix("<") else {
      return nil
    }
    return text
  }

  func health() async throws -> HealthResponse {
    try await request("health")
  }

  func sites() async throws -> [SiteInfo] {
    try await request("api/sites")
  }

  func createSite(siteID: String) async throws -> SiteInfo {
    try await request("api/sites", method: "POST", body: SiteCreateRequest(siteId: siteID))
  }

  func saveSiteSettings(siteID: String, settings: SiteSettingsUpdate) async throws -> SiteInfo {
    try await request("api/sites/\(encodedPathComponent(siteID))", method: "PUT", body: settings)
  }

  func deleteSite(siteID: String) async throws -> [SiteInfo] {
    try await request("api/sites/\(encodedPathComponent(siteID))", method: "DELETE")
  }

  func addSiteMirror(siteID: String, url: String) async throws -> SiteInfo {
    try await request("api/sites/\(encodedPathComponent(siteID))/mirrors", method: "POST", body: SiteMirrorRequest(url: url))
  }

  func deleteSiteMirror(siteID: String, index: Int) async throws -> SiteInfo {
    try await request("api/sites/\(encodedPathComponent(siteID))/mirrors/\(index)", method: "DELETE")
  }

  func selectSiteMirror(siteID: String, url: String) async throws -> SiteInfo {
    try await request("api/sites/\(encodedPathComponent(siteID))/select-mirror", method: "POST", body: SiteMirrorRequest(url: url))
  }

  func previewSiteRSS(siteID: String, url: String, settings: SiteSettingsUpdate? = nil, keyword: String? = nil, category: String? = nil, page: Int = 1, pageSize: Int = 25) async throws -> RssTestResponse {
    try await request(
      "api/sites/\(encodedPathComponent(siteID))/rss/preview",
      method: "POST",
      body: RssTestRequest(url: url, site: siteID, siteSettings: settings, keyword: keyword, category: category, limit: pageSize, page: page, pageSize: pageSize)
    )
  }

  func testSiteDomain(siteID: String, url: String) async throws -> SiteDomainTestResponse {
    try await request("api/sites/\(encodedPathComponent(siteID))/test", method: "POST", body: SiteDomainTestRequest(url: url))
  }

  func loadQbittorrentConfig() async throws -> QbittorrentConfig {
    try await request("api/config/qbittorrent")
  }

  func saveQbittorrentConfig(_ config: QbittorrentConfig) async throws -> QbittorrentConfig {
    try await request("api/config/qbittorrent", method: "PUT", body: config)
  }

  func loadTransmissionConfig() async throws -> TransmissionConfig {
    try await request("api/config/transmission")
  }

  func saveTransmissionConfig(_ config: TransmissionConfig) async throws -> TransmissionConfig {
    try await request("api/config/transmission", method: "PUT", body: config)
  }

  func downloaderRouting() async throws -> DownloaderRoutingResponse {
    try await request("api/config/downloaders")
  }

  func saveDownloaderRouting(_ settings: DownloaderRoutingSettings) async throws -> DownloaderRoutingResponse {
    try await request("api/config/downloaders", method: "PUT", body: settings)
  }

  func qBittorrentGlobalLimits() async throws -> QbittorrentGlobalLimits {
    try await request("api/qbittorrent/global-limits")
  }

  func saveQBittorrentGlobalLimits(_ limits: QbittorrentGlobalLimits) async throws -> QbittorrentGlobalLimits {
    try await request("api/qbittorrent/global-limits", method: "PUT", body: limits)
  }

  func transmissionGlobalLimits() async throws -> QbittorrentGlobalLimits {
    try await request("api/transmission/global-limits")
  }

  func saveTransmissionGlobalLimits(_ limits: QbittorrentGlobalLimits) async throws -> QbittorrentGlobalLimits {
    try await request("api/transmission/global-limits", method: "PUT", body: limits)
  }

  func settings() async throws -> AppSettingsResponse {
    try await request("api/settings")
  }

  func searchSettings() async throws -> SearchSettings {
    try await request("api/settings/search")
  }

  func saveSearchSettings(_ settings: SearchSettings) async throws -> SearchSettings {
    try await request("api/settings/search", method: "PUT", body: settings)
  }

  func mikanProjectSettings() async throws -> MikanProjectSettings {
    try await request("api/mikan-project/settings")
  }

  func saveMikanProjectSettings(_ settings: MikanProjectSettings) async throws -> MikanProjectSettings {
    try await request("api/mikan-project/settings", method: "PUT", body: settings)
  }

  func mikanProjectSeason() async throws -> MikanProjectSeasonResponse {
    try await request("api/mikan-project/season")
  }

  func refreshMikanProjectSeason() async throws -> MikanProjectSeasonResponse {
    try await request("api/mikan-project/season/refresh", method: "POST")
  }

  func mikanProjectResources(bangumiID: String) async throws -> MikanProjectResourcesResponse {
    try await request("api/mikan-project/anime/\(encodedPathComponent(bangumiID))/resources")
  }

  func saveMetadataSettings(tmdbApiKey: String?) async throws -> MetadataSettingsResponse {
    try await request("api/settings/metadata", method: "PUT", body: MetadataSettings(tmdbApiKey: tmdbApiKey))
  }

  func clearTMDBSettings() async throws -> MetadataSettingsResponse {
    try await request("api/settings/tmdb", method: "DELETE")
  }

  func testTMDB(tmdbApiKey: String?) async throws -> QbittorrentTestResponse {
    try await request("api/settings/tmdb/test", method: "POST", body: TMDBTestRequest(tmdbApiKey: tmdbApiKey))
  }

  func notificationSettings() async throws -> NotificationSettingsResponse {
    do {
      return try await request("api/settings/notifications")
    } catch APIClientError.server(let status, _) where status == 404 {
      return try await request("api/settings/notification")
    }
  }

  func saveNotificationSettings(_ settings: NotificationSettings) async throws -> NotificationSettingsResponse {
    do {
      return try await request("api/settings/notifications", method: "PUT", body: settings)
    } catch APIClientError.server(let status, _) where status == 404 {
      return try await request("api/settings/notification", method: "PUT", body: settings)
    }
  }

  func testNotification(_ requestBody: NotificationTestRequest) async throws -> NotificationTestResponse {
    do {
      return try await request("api/settings/notifications/test", method: "POST", body: requestBody)
    } catch APIClientError.server(let status, _) where status == 404 {
      return try await request("api/settings/notification/test", method: "POST", body: requestBody)
    }
  }

  func aiSettings() async throws -> AISettingsResponse {
    try await request("api/settings/ai")
  }

  func saveAISettings(_ settings: AISettings) async throws -> AISettingsResponse {
    try await request("api/settings/ai", method: "PUT", body: settings)
  }

  func testAISettings(_ settings: AISettings) async throws -> QbittorrentTestResponse {
    try await request("api/settings/ai/test", method: "POST", body: settings)
  }

  func listAIModels(_ requestBody: AIModelListRequest) async throws -> AIModelListResponse {
    try await request("api/settings/ai/models", method: "POST", body: requestBody)
  }

  func analyzeTitleAI(_ requestBody: AITitleAnalyzeRequest) async throws -> AITitleAnalysisResponse {
    try await request("api/title/analyze-ai", method: "POST", body: requestBody)
  }

  func suggestEpisodeRuleAI(_ requestBody: AITitleAnalyzeRequest) async throws -> AITitleAnalysisResponse {
    try await request("api/episode-rules/suggest-ai", method: "POST", body: requestBody)
  }

  func saveOrganizePolicy(_ policy: OrganizePolicySettings) async throws -> OrganizePolicySettings {
    try await request("api/settings/organize-policy", method: "PUT", body: policy)
  }

  func episodeRuleSettings() async throws -> EpisodeRuleSettingsResponse {
    try await request("api/settings/episode-rules")
  }

  func saveEpisodeRuleSettings(_ rules: [EpisodeParseRule]) async throws -> EpisodeRuleSettingsResponse {
    try await request("api/settings/episode-rules", method: "PUT", body: EpisodeRuleSettingsUpdate(userRules: rules))
  }

  func testGlobalEpisodeRules(title: String, episodeParseRules: [EpisodeParseRule]) async throws -> EpisodeRuleTestResponse {
    try await request(
      "api/settings/episode-rules/test",
      method: "POST",
      body: EpisodeRuleTestRequest(title: title, episodeParseRules: episodeParseRules)
    )
  }

  func testGlobalEpisodeRules(tests: [EpisodeRuleTestCase], episodeParseRules: [EpisodeParseRule]) async throws -> EpisodeRuleTestResponse {
    try await request(
      "api/episode-rules/test",
      method: "POST",
      body: EpisodeRuleTestRequest(title: tests.first?.title ?? "", episodeParseRules: episodeParseRules, tests: tests)
    )
  }

  func tokenizeEpisodeRuleTitle(_ title: String) async throws -> EpisodeRuleTokenizeResponse {
    try await request(
      "api/settings/episode-rules/tokenize-title",
      method: "POST",
      body: EpisodeRuleTokenizeRequest(title: title)
    )
  }

  func previewEpisodeRule(title: String, marks: [EpisodeRuleVisualMark], name: String?) async throws -> EpisodeRulePreviewResponse {
    try await request(
      "api/settings/episode-rules/preview-from-marks",
      method: "POST",
      body: EpisodeRulePreviewRequest(title: title, marks: marks, name: name)
    )
  }

  func testQbittorrent(_ config: QbittorrentConfig) async throws -> QbittorrentTestResponse {
    try await request("api/qbittorrent/test", method: "POST", body: config)
  }

  func testTransmission(_ config: TransmissionConfig) async throws -> TransmissionTestResponse {
    try await request("api/transmission/test", method: "POST", body: config)
  }

  func organizeTargets() async throws -> [OrganizeTarget] {
    try await request("api/organize/targets")
  }

  func createOrganizeTarget(_ target: OrganizeTargetCreate) async throws -> OrganizeTarget {
    try await request("api/organize/targets", method: "POST", body: target)
  }

  func updateOrganizeTarget(id: Int, _ target: OrganizeTargetCreate) async throws -> OrganizeTarget {
    try await request("api/organize/targets/\(id)", method: "PUT", body: target)
  }

  func deleteOrganizeTarget(id: Int) async throws -> OKResponse {
    try await request("api/organize/targets/\(id)", method: "DELETE")
  }

  func setDefaultOrganizeTarget(id: Int) async throws -> OrganizeTarget {
    try await request("api/organize/targets/\(id)/set-default", method: "POST")
  }

  func validateOrganizeTarget(id: Int) async throws -> OrganizeTargetValidateResponse {
    try await request("api/organize/targets/\(id)/validate", method: "POST")
  }

  func search(
    keyword: String,
    sites: [String],
    deduplicate: Bool,
    pageSize: Int = 50,
    page: Int? = nil,
    maxPages: Int? = nil,
    timeoutSeconds: Double? = nil
  ) async throws -> SearchResponse {
    try await request(
      "api/search",
      method: "POST",
      body: SearchRequest(
        keyword: keyword,
        sites: sites,
        channels: sites,
        limit: 5000,
        page: page,
        pageSize: pageSize,
        maxPages: maxPages,
        deduplicate: deduplicate,
        stopWhenNoNewResults: true,
        timeoutSeconds: timeoutSeconds,
        includeDiagnostics: true
      )
    )
  }

  func addDownload(result: SearchResult, organizeTargetID: Int? = nil, dryRun: Bool = false) async throws -> DownloadResponse {
    try await request(
      "api/downloads",
      method: "POST",
      body: DownloadRequest(
        result: result,
        qbittorrent: nil,
        savePath: nil,
        organizeTargetId: organizeTargetID,
        category: nil,
        tags: ["kisetsu"],
        dryRun: dryRun
      )
    )
  }

  func subscriptions() async throws -> [Subscription] {
    try await request("api/subscriptions")
  }

  func subscriptionDetail(id: Int) async throws -> SubscriptionDetail {
    try await request("api/subscriptions/\(id)")
  }

  func createSubscription(_ subscription: SubscriptionCreate) async throws -> Subscription {
    try await request("api/subscriptions", method: "POST", body: subscription)
  }

  func suggestSubscription(
    result: SearchResult,
    sites: [String],
    organizeTargetID: Int? = nil,
    savePath: String? = nil,
    category: String? = "anime",
    tags: [String] = ["kisetsu"]
  ) async throws -> SubscriptionSuggestionResponse {
    try await request(
      "api/subscriptions/suggest",
      method: "POST",
      body: SubscriptionSuggestionRequest(
        result: result,
        sites: sites,
        organizeTargetId: organizeTargetID,
        savePath: savePath,
        category: category,
        tags: tags
      )
    )
  }

  func smartSubscriptionPrefill(
    result: SearchResult,
    sites: [String],
    organizeTargetID: Int? = nil,
    savePath: String? = nil,
    category: String? = "anime",
    tags: [String] = ["kisetsu"],
    useAI: Bool? = nil
  ) async throws -> SmartSubscriptionPrefillResponse {
    try await request(
      "api/subscriptions/smart-prefill",
      method: "POST",
      body: SmartSubscriptionPrefillRequest(
        result: result,
        sites: sites,
        organizeTargetId: organizeTargetID,
        savePath: savePath,
        category: category,
        tags: tags,
        useAi: useAI
      )
    )
  }

  func updateSubscription(
    id: Int,
    _ subscription: SubscriptionCreate,
    expectedUpdatedAt: String? = nil
  ) async throws -> Subscription {
    let queryItems = expectedUpdatedAt.map {
      [URLQueryItem(name: "expected_updated_at", value: $0)]
    } ?? []
    return try await request(
      "api/subscriptions/\(id)",
      method: "PUT",
      body: subscription,
      queryItems: queryItems
    )
  }

  func testSubscriptionMatch(_ subscription: SubscriptionCreate) async throws -> SubscriptionTestMatchResponse {
    try await request("api/subscriptions/test-match", method: "POST", body: subscription)
  }

  func testRSS(url: String, site: String) async throws -> RssTestResponse {
    try await request("api/rss/test", method: "POST", body: RssTestRequest(url: url, site: site))
  }

  func refreshSubscription(id: Int) async throws -> RefreshResponse {
    try await request("api/subscriptions/\(id)/refresh", method: "POST")
  }

  func subscriptionMatches(id: Int) async throws -> [SubscriptionMatch] {
    try await request("api/subscriptions/\(id)/matches")
  }

  func subscriptionEpisodes(id: Int) async throws -> [SubscriptionEpisodeStatus] {
    try await request("api/subscriptions/\(id)/episodes")
  }

  func downloadSubscriptionMatches(
    subscriptionID: Int,
    matchIDs: [Int],
    allMatches: Bool = false,
    dryRun: Bool = false
  ) async throws -> SubscriptionDownloadResponse {
    try await request(
      "api/subscriptions/\(subscriptionID)/download",
      method: "POST",
      body: SubscriptionDownloadRequest(matchIds: matchIDs, allMatches: allMatches, dryRun: dryRun)
    )
  }

  func organizeSubscription(
    subscriptionID: Int,
    episodeNumbers: [Int] = [],
    matchIDs: [Int] = [],
    organizeTargetID: Int? = nil,
    deleteTaskAfterSuccess: Bool? = nil,
    deleteFiles: Bool? = nil,
    keepSeeding: Bool? = nil,
    dryRun: Bool = false,
    confirm: Bool = true
  ) async throws -> SubscriptionOrganizeResponse {
    try await request(
      "api/subscriptions/\(subscriptionID)/organize",
      method: "POST",
      body: SubscriptionOrganizeRequest(
        episodeNumbers: episodeNumbers,
        matchIds: matchIDs,
        organizeTargetId: organizeTargetID,
        deleteQbittorrentTaskAfterSuccess: deleteTaskAfterSuccess,
        deleteFilesFromQbittorrent: deleteFiles,
        keepSeeding: keepSeeding,
        dryRun: dryRun,
        confirm: confirm,
        manualOverride: nil,
        overrideReason: nil
      )
    )
  }

  func organizeSubscriptionEpisodes(
    subscriptionID: Int,
    episodeNumbers: [Int],
    matchIDs: [Int] = [],
    organizeTargetID: Int? = nil,
    dryRun: Bool = false,
    confirm: Bool = true
  ) async throws -> SubscriptionOrganizeResponse {
    try await request(
      "api/subscriptions/\(subscriptionID)/episodes/organize",
      method: "POST",
      body: SubscriptionOrganizeRequest(
        episodeNumbers: episodeNumbers,
        matchIds: matchIDs,
        organizeTargetId: organizeTargetID,
        deleteQbittorrentTaskAfterSuccess: nil,
        deleteFilesFromQbittorrent: nil,
        keepSeeding: nil,
        dryRun: dryRun,
        confirm: confirm,
        manualOverride: nil,
        overrideReason: nil
      )
    )
  }

  func refreshAllSubscriptions() async throws -> RefreshAllResponse {
    try await request("api/subscriptions/refresh_all", method: "POST")
  }

  func deleteSubscription(id: Int) async throws -> OKResponse {
    try await request("api/subscriptions/\(id)", method: "DELETE")
  }

  func resetSubscription(id: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(id)/reset", method: "POST", body: ResetSubscriptionRequest(confirm: true))
  }

  func clearSubscriptionHistory(id: Int, scope: String) async throws -> HistoryClearResponse {
    try await request(
      "api/subscriptions/\(id)/history/clear",
      method: "POST",
      body: SubscriptionHistoryClearRequest(scope: scope, confirm: true)
    )
  }

  func clearSubscriptionRecognition(id: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(id)/clear-recognition", method: "POST", body: ResetSubscriptionRequest(confirm: true))
  }

  func clearSubscriptionMatchHistory(id: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(id)/clear-match-history", method: "POST", body: ResetSubscriptionRequest(confirm: true))
  }

  func clearSubscriptionOrganizeRecords(id: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(id)/clear-organize-records", method: "POST", body: ResetSubscriptionRequest(confirm: true))
  }

  func deleteEpisodeDownloadRecord(subscriptionID: Int, matchID: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(subscriptionID)/episodes/\(matchID)/download-record", method: "DELETE")
  }

  func deleteEpisodeOrganizeRecord(subscriptionID: Int, matchID: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(subscriptionID)/episodes/\(matchID)/organize-record", method: "DELETE")
  }

  func resetEpisodeState(subscriptionID: Int, matchID: Int) async throws -> ResetSubscriptionResponse {
    try await request("api/subscriptions/\(subscriptionID)/episodes/\(matchID)/reset", method: "POST", body: ResetSubscriptionRequest(confirm: true))
  }

  func schedulerStatus() async throws -> SchedulerStatus {
    do {
      let status: AutomationStatus = try await request("api/automation/status")
      return schedulerStatus(from: status)
    } catch APIClientError.server(let status, _) where status == 404 {
      return try await request("api/scheduler/status")
    }
  }

  func startScheduler(intervalSeconds: Int) async throws -> SchedulerStatus {
    do {
      let status: AutomationStatus = try await request("api/automation/start", method: "POST", body: SchedulerStartRequest(intervalSeconds: intervalSeconds))
      return schedulerStatus(from: status)
    } catch APIClientError.server(let status, _) where status == 404 {
      return try await request("api/scheduler/start", method: "POST", body: SchedulerStartRequest(intervalSeconds: intervalSeconds))
    }
  }

  func stopScheduler() async throws -> SchedulerStatus {
    do {
      let status: AutomationStatus = try await request("api/automation/stop", method: "POST")
      return schedulerStatus(from: status)
    } catch APIClientError.server(let status, _) where status == 404 {
      return try await request("api/scheduler/stop", method: "POST")
    }
  }

  func saveAutomationSettings(_ settings: AutomationSettingsRequest) async throws -> SchedulerStatus {
    let status: AutomationStatus = try await request("api/automation/settings", method: "PUT", body: settings)
    return schedulerStatus(from: status)
  }

  func saveSchedulerInterval(seconds: Int) async throws -> SchedulerStatus {
    do {
      let status: AutomationStatus = try await request(
        "api/automation/interval", method: "PUT", body: SchedulerStartRequest(intervalSeconds: seconds)
      )
      return schedulerStatus(from: status)
    } catch APIClientError.server(let status, _) where status == 404 || status == 405 {
      throw APIClientError.server(status, "后端尚不支持单独保存刷新间隔，请升级后端。")
    }
  }

  private func schedulerStatus(from status: AutomationStatus) -> SchedulerStatus {
    SchedulerStatus(
      running: status.schedulerRunning,
      intervalSeconds: status.autoRefreshIntervalSeconds,
      lastRunAt: status.lastRunAt,
      lastError: status.lastErrorMessage,
      nextRunAt: status.nextRunAt,
      lastSuccessAt: status.lastSuccessAt,
      lastErrorAt: status.lastErrorAt,
      lastErrorMessage: status.lastErrorMessage,
      currentJobId: status.currentJobId,
      message: status.message
    )
  }

  func refreshTaskState() async throws -> TaskStateSyncStatus {
    try await request("api/task-state/refresh", method: "POST")
  }

  func taskStateStatus() async throws -> TaskStateSyncStatus {
    try await request("api/task-state/status")
  }

  func history() async throws -> [DownloadHistory] {
    try await request("api/history")
  }

  func history(subscriptionID: Int) async throws -> [DownloadHistory] {
    try await request("api/history?subscription_id=\(subscriptionID)")
  }

  func manageHistory(id: Int, action: String) async throws -> DownloadHistoryManageResponse {
    try await request(
      "api/history/\(id)/manage",
      method: "POST",
      body: DownloadHistoryManageRequest(action: action)
    )
  }

  func deleteHistory(id: Int) async throws -> OKResponse {
    try await request("api/history/\(id)", method: "DELETE")
  }

  func clearHistory(
    scope: String,
    subscriptionID: Int? = nil,
    deleteQbittorrentTasks: Bool = false,
    deleteFiles: Bool = false
  ) async throws -> HistoryClearResponse {
    try await request(
      "api/history/clear",
      method: "POST",
      body: HistoryClearRequest(
        scope: scope,
        subscriptionId: subscriptionID,
        deleteQbittorrentTasks: deleteQbittorrentTasks,
        deleteFiles: deleteFiles,
        confirm: true
      )
    )
  }

  func metadataSearch(query: String, year: Int? = nil, sources: [String] = ["bangumi", "tmdb"], mediaType: String = "anime") async throws -> MetadataSearchResponse {
    try await request(
      "api/metadata/search",
      method: "POST",
      body: MetadataSearchRequest(query: query, year: year, mediaType: mediaType, sources: sources)
    )
  }

  func metadataMatch(title: String, year: Int? = nil, downloadRecordID: Int? = nil, mediaType: String = "anime") async throws -> MetadataSearchResponse {
    try await request(
      "api/metadata/match",
      method: "POST",
      body: MetadataMatchRequest(title: title, year: year, downloadRecordId: downloadRecordID, mediaType: mediaType)
    )
  }

  func bindMetadata(_ requestBody: MetadataBindRequest) async throws -> MetadataBindResponse {
    try await request("api/metadata/bind", method: "POST", body: requestBody)
  }

  func metadataBindings() async throws -> [MetadataBindingRecord] {
    try await request("api/metadata/bindings")
  }

  func metadataBindings(targetType: String, targetID: String) async throws -> [MetadataBindingRecord] {
    let encodedTargetID = encodedPathComponent(targetID)
    let records: [MetadataBindingRecord] = try await request("api/metadata/bindings/\(targetType)/\(encodedTargetID)")
    return records
  }

  func parseTitle(_ title: String, episodeParseRules: [EpisodeParseRule] = []) async throws -> ParsedAnimeTitle {
    try await request("api/title/parse", method: "POST", body: TitleParseRequest(title: title, episodeParseRules: episodeParseRules))
  }

  func testEpisodeRules(subscriptionID: Int, title: String, episodeParseRules: [EpisodeParseRule]) async throws -> EpisodeRuleTestResponse {
    try await request(
      "api/subscriptions/\(subscriptionID)/episode-rules/test",
      method: "POST",
      body: EpisodeRuleTestRequest(title: title, episodeParseRules: episodeParseRules)
    )
  }

  func saveMapping(_ mapping: PlexSeasonMapping) async throws -> PlexMappingResponse {
    try await request("api/plex/mapping", method: "POST", body: mapping)
  }

  func plexMappings() async throws -> [PlexMappingRecord] {
    try await request("api/plex/mappings")
  }

  func organizePreview(_ requestBody: OrganizePreviewRequest) async throws -> OrganizePreviewItem {
    try await request("api/organize/preview", method: "POST", body: requestBody)
  }

  func organizeApply(_ requestBody: OrganizeApplyRequest) async throws -> OrganizeApplyResponse {
    try await request("api/organize/apply", method: "POST", body: requestBody)
  }

  func organizePreviews() async throws -> [OrganizePreviewRecord] {
    try await request("api/organize/previews")
  }

  func organizeHistory(subscriptionID: Int? = nil, status: String? = nil, search: String? = nil) async throws -> [OrganizeHistoryRecord] {
    var components = URLComponents()
    var queryItems: [URLQueryItem] = []
    if let subscriptionID {
      queryItems.append(URLQueryItem(name: "subscription_id", value: String(subscriptionID)))
    }
    if let status, !status.isEmpty, status != "all" {
      queryItems.append(URLQueryItem(name: "status", value: status))
    }
    if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      queryItems.append(URLQueryItem(name: "search", value: search))
    }
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    let suffix = components.percentEncodedQuery.map { "?\($0)" } ?? ""
    return try await request("api/organize/history\(suffix)")
  }

  func clearOrganizeHistory() async throws -> HistoryClearResponse {
    try await request(
      "api/organize/history/clear",
      method: "POST",
      body: OrganizeHistoryClearRequest(confirm: true)
    )
  }

  func failedOrganizeHistorySummary(subscriptionID: Int? = nil) async throws -> OrganizeFailedHistorySummary {
    let suffix = subscriptionID.map { "?subscription_id=\($0)" } ?? ""
    return try await request("api/organize/history/failed/summary\(suffix)")
  }

  func deleteFailedOrganizeHistory(subscriptionID: Int? = nil) async throws -> OrganizeFailedHistoryDeleteResponse {
    try await request(
      "api/organize/history/failed/delete",
      method: "POST",
      body: OrganizeFailedHistoryDeleteRequest(confirm: true, subscriptionId: subscriptionID)
    )
  }

  func brushSettings() async throws -> BrushSettings {
    try await request("api/brush/settings")
  }

  func saveBrushSettings(_ settings: BrushSettings) async throws -> BrushStatus {
    try await request("api/brush/settings", method: "PUT", body: settings)
  }

  func brushStatus() async throws -> BrushStatus {
    try await request("api/brush/status")
  }

  func brushCapabilities() async throws -> [BrushCapabilities] {
    try await request("api/brush/capabilities")
  }

  func brushSiteAccounts(refresh: Bool = false) async throws -> [BrushSiteAccount] {
    try await request("api/brush/site-accounts?refresh=\(refresh ? "true" : "false")")
  }

  func startBrush() async throws -> BrushStatus {
    try await request("api/brush/start", method: "POST")
  }

  func stopBrush() async throws -> BrushStatus {
    try await request("api/brush/stop", method: "POST")
  }

  func runBrushNow() async throws -> BrushRunResponse {
    try await request("api/brush/run-now", method: "POST")
  }

  func checkBrushNow() async throws -> BrushRunResponse {
    try await request("api/brush/check-now", method: "POST")
  }

  func brushTasks(includeArchived: Bool = false) async throws -> [BrushTask] {
    try await request("api/brush/tasks?include_archived=\(includeArchived ? "true" : "false")")
  }

  func brushRuns() async throws -> [BrushRun] {
    try await request("api/brush/runs/recent")
  }

  func manageBrushTask(id: Int, action: String) async throws -> BrushActionResponse {
    try await request("api/brush/tasks/\(id)/manage", method: "POST", body: BrushActionRequest(action: action))
  }

  func clearBrushRecords() async throws -> BrushActionResponse {
    try await request("api/brush/records/clear", method: "POST", body: BrushClearRequest(includeActive: false, confirm: true))
  }

  func fileBrowserRoots() async throws -> FileBrowserRootResponse {
    try await request("api/files/roots")
  }

  func fileBrowserDirectory(
    rootID: String,
    path: String,
    offset: Int = 0,
    limit: Int = 250,
    showHidden: Bool = false
  ) async throws -> FileBrowserDirectoryResponse {
    try await request(
      "api/files/list",
      queryItems: [
        URLQueryItem(name: "root_id", value: rootID),
        URLQueryItem(name: "path", value: path),
        URLQueryItem(name: "offset", value: String(offset)),
        URLQueryItem(name: "limit", value: String(limit)),
        URLQueryItem(name: "show_hidden", value: showHidden ? "true" : "false")
      ]
    )
  }

  func beginFileBrowserEditSession() async throws -> FileBrowserEditSession {
    try await request(
      "api/files/edit-session",
      method: "POST",
      body: FileBrowserEditSessionRequest(confirm: true)
    )
  }

  func lockFileBrowserEditSession(token: String) async throws -> FileBrowserWriteResponse {
    try await request(
      "api/files/edit-session/lock",
      method: "POST",
      body: FileBrowserLockRequest(token: token)
    )
  }

  func renameFileBrowserItem(_ requestBody: FileBrowserRenameRequest) async throws -> FileBrowserWriteResponse {
    try await request("api/files/rename", method: "POST", body: requestBody)
  }

  func createFileBrowserFolder(_ requestBody: FileBrowserCreateFolderRequest) async throws -> FileBrowserWriteResponse {
    try await request("api/files/folders", method: "POST", body: requestBody)
  }

  func previewFileBrowserDelete(
    _ requestBody: FileBrowserDeletePreviewRequest
  ) async throws -> FileBrowserDeletePreview {
    try await request("api/files/delete-preview", method: "POST", body: requestBody)
  }

  func startFileBrowserDelete(_ requestBody: FileBrowserDeleteRequest) async throws -> FileBrowserOperationStatus {
    try await request("api/files/delete", method: "POST", body: requestBody)
  }

  func startFileBrowserOperation(_ requestBody: FileBrowserOperationRequest) async throws -> FileBrowserOperationStatus {
    try await request("api/files/operations", method: "POST", body: requestBody)
  }

  func fileBrowserOperation(id: String) async throws -> FileBrowserOperationStatus {
    try await request("api/files/operations/\(encodedPathComponent(id))")
  }

  func recentFileBrowserOperations(limit: Int = 20) async throws -> [FileBrowserOperationStatus] {
    try await request(
      "api/files/operations",
      queryItems: [URLQueryItem(name: "limit", value: String(limit))]
    )
  }

  func cancelFileBrowserOperation(id: String, token: String) async throws -> FileBrowserOperationStatus {
    try await request(
      "api/files/operations/\(encodedPathComponent(id))/cancel",
      method: "POST",
      body: FileBrowserCancelRequest(editToken: token)
    )
  }

  func playlistSettings() async throws -> PlaylistSettingsResponse {
    try await request("api/playlists/settings")
  }

  func credential(_ reference: CredentialReference) async throws -> String {
    let response: CredentialValue = try await request("api/settings/credential", method: "POST", body: reference)
    return response.value
  }

  func savePlaylistSettings(_ settings: PlaylistSettingsUpdate) async throws -> PlaylistSettingsResponse {
    try await request("api/playlists/settings", method: "PUT", body: settings)
  }

  func testPlaylistPlexConnection() async throws -> PlexConnectionResponse {
    try await request("api/playlists/connection-test", method: "POST")
  }

  func playlistQuarters(refresh: Bool = false) async throws -> [PlaylistQuarterOption] {
    try await request(
      "api/playlists/quarters",
      queryItems: [URLQueryItem(name: "refresh", value: refresh ? "true" : "false")]
    )
  }

  func playlistQuarter(year: Int, month: Int, refresh: Bool = false) async throws -> PlaylistQuarterResponse {
    try await request(
      "api/playlists/quarters/\(year)/\(month)",
      queryItems: [URLQueryItem(name: "refresh", value: refresh ? "true" : "false")]
    )
  }

  func warmPlaylistPosters(year: Int, month: Int) async throws -> OKResponse {
    try await request("api/playlists/quarters/\(year)/\(month)/warm-posters", method: "POST")
  }

  func plexShows(query: String = "") async throws -> [PlexShow] {
    try await request(
      "api/playlists/plex/shows",
      queryItems: [URLQueryItem(name: "query", value: query)]
    )
  }

  func plexShowHierarchy(ratingKey: String) async throws -> PlexShowHierarchy {
    try await request("api/playlists/plex/shows/\(encodedPathComponent(ratingKey))/hierarchy")
  }

  func pairPlaylistItem(_ pairing: PairingRequest) async throws -> PlexPairing {
    try await request("api/playlists/pairings", method: "POST", body: pairing)
  }

  func unpairPlaylistItem(itemKey: String) async throws -> OKResponse {
    try await request(
      "api/playlists/pairings/remove",
      method: "POST",
      body: PairingDeleteRequest(itemKey: itemKey)
    )
  }

  func rematchPlaylistItem(itemKey: String) async throws -> OKResponse {
    try await request(
      "api/playlists/pairings/rematch",
      method: "POST",
      body: PairingDeleteRequest(itemKey: itemKey)
    )
  }

  func plexPlaylists() async throws -> [PlexPlaylistSummary] {
    try await request("api/playlists/existing")
  }

  func plexPlaylistDetail(ratingKey: String) async throws -> PlexPlaylistDetail {
    try await request("api/playlists/existing/\(encodedPathComponent(ratingKey))")
  }

  func previewPlaylistCreation(_ preview: PlaylistCreatePreviewRequest) async throws -> PlaylistCreatePreviewResponse {
    try await request("api/playlists/create-preview", method: "POST", body: preview)
  }

  func createPlexPlaylist(_ creation: PlaylistCreateRequest) async throws -> PlaylistCreateResponse {
    try await request("api/playlists/create", method: "POST", body: creation)
  }
}
