import SwiftUI

@MainActor
final class MobileAutoRefreshState: ObservableObject {
  enum Action { case save, start, stop }
  enum Unit: Int, CaseIterable { case seconds = 1, minutes = 60 }

  @Published private(set) var status: SchedulerStatus?
  @Published private(set) var isBusy = false
  @Published private(set) var errorMessage: String?
  @Published var intervalText = ""
  @Published private(set) var unit: Unit = .minutes
  private let client: APIClient
  private var savedDraftSeconds: Int?
  private var isInvalidated = false

  init(client: APIClient) { self.client = client }

  func invalidate() { isInvalidated = true }

  private func checkActive() throws {
    try Task.checkCancellation()
    if isInvalidated { throw CancellationError() }
  }

  var intervalSeconds: Int? {
    guard let value = Int(intervalText), value > 0, value <= 86400 / unit.rawValue else { return nil }
    return value * unit.rawValue
  }

  var hasChanges: Bool { intervalSeconds != savedDraftSeconds }

  func changeUnit(to newUnit: Unit) {
    guard let seconds = intervalSeconds, seconds % newUnit.rawValue == 0 else { return }
    unit = newUnit
    intervalText = String(seconds / newUnit.rawValue)
  }

  func load() async {
    guard !isBusy, !isInvalidated else { return }
    isBusy = true
    errorMessage = nil
    let preserveDraft = savedDraftSeconds != nil && hasChanges
    defer { isBusy = false }
    do {
      let fresh = try await client.schedulerStatus()
      try checkActive()
      status = fresh
      savedDraftSeconds = fresh.intervalSeconds
      if !preserveDraft { fillDraft(fresh.intervalSeconds) }
    } catch {
      status = nil
      errorMessage = error.localizedDescription
    }
  }

  func perform(_ action: Action) async {
    guard !isBusy, !isInvalidated, status != nil else { return }
    guard action == .stop || intervalSeconds != nil else {
      errorMessage = "刷新间隔须为 1–86400 秒。"
      return
    }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      switch action {
      case .save:
        _ = try await client.saveSchedulerInterval(seconds: intervalSeconds!)
      case .start:
        let seconds = intervalSeconds!
        if hasChanges { _ = try await client.saveSchedulerInterval(seconds: seconds) }
        try checkActive()
        _ = try await client.startScheduler(intervalSeconds: seconds)
      case .stop:
        _ = try await client.stopScheduler()
      }
      try checkActive()
      let fresh = try await client.schedulerStatus()
      try checkActive()
      status = fresh
      savedDraftSeconds = fresh.intervalSeconds
      if action != .stop { fillDraft(fresh.intervalSeconds) }
    } catch {
      guard !isInvalidated, !Task.isCancelled else { return }
      let failure = error.localizedDescription
      // A mutation may have reached the server. Reconcile once, never resend it.
      status = try? await client.schedulerStatus()
      if let status { savedDraftSeconds = status.intervalSeconds }
      errorMessage = failure
    }
  }

  private func fillDraft(_ seconds: Int) {
    unit = seconds % 60 == 0 ? .minutes : .seconds
    intervalText = String(seconds / unit.rawValue)
  }
}
