#if DEBUG
import Foundation

actor MobileAutoRefreshFixture {
  private var running: Bool
  private var seconds: Int
  private(set) var requests: [String] = []
  private var failurePath: String?
  private var failureAfterWrite = false
  private var latency: Duration

  init(running: Bool = false, seconds: Int = 1800, latency: Duration = .zero, failStart: Bool = false) {
    self.running = running
    self.seconds = seconds
    self.latency = latency
    failurePath = failStart ? "/api/automation/start" : nil
  }

  nonisolated func client() -> APIClient {
    APIClient(baseURL: "https://kisetsu-fixture.invalid") { try await self.respond($0) }
  }

  func failNext(_ path: String, afterWrite: Bool = false) {
    failurePath = "/api/automation/\(path)"
    failureAfterWrite = afterWrite
  }

  func setRemote(running: Bool, seconds: Int) {
    self.running = running
    self.seconds = seconds
  }

  private func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    guard let url = request.url, url.host == "kisetsu-fixture.invalid" else { throw URLError(.unsupportedURL) }
    let path = url.path
    requests.append("\(request.httpMethod ?? "GET") \(path)")
    let failing = path == failurePath
    let afterWrite = failureAfterWrite
    if failing { failurePath = nil }
    if latency > .zero { try await Task.sleep(for: latency) }
    if failing && !afterWrite { throw URLError(.timedOut) }
    switch (request.httpMethod, path) {
    case ("GET", "/api/automation/status"): break
    case ("PUT", "/api/automation/interval"), ("POST", "/api/automation/start"):
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let body = try decoder.decode(SchedulerStartRequest.self, from: request.httpBody ?? Data())
      guard (1...86400).contains(body.intervalSeconds) else { throw URLError(.badServerResponse) }
      seconds = body.intervalSeconds
      if path.hasSuffix("/start") { running = true }
    case ("POST", "/api/automation/stop"): running = false
    default: throw URLError(.unsupportedURL)
    }
    if failing { throw URLError(.timedOut) }
    let status = AutomationStatus(
      backendRunning: true, schedulerRunning: running, autoRefreshEnabled: running,
      autoRefreshIntervalSeconds: seconds, autoDownloadEnabled: false,
      autoOrganizeEnabled: false, notificationsEnabled: false, message: running ? "运行中" : "已停止"
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
      throw URLError(.badServerResponse)
    }
    return (try encoder.encode(status), response)
  }
}
#endif
