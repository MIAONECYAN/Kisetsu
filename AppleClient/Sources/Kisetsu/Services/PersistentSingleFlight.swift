import Foundation

@MainActor
final class PersistentSingleFlight {
  private var inFlightTask: Task<Void, Never>?
  private var inFlightID: UUID?

  var isRunning: Bool {
    inFlightTask != nil
  }

  func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
    if let inFlightTask {
      await inFlightTask.value
      return
    }

    let requestID = UUID()
    let task = Task { @MainActor in
      await operation()
    }
    inFlightID = requestID
    inFlightTask = task
    await task.value

    if inFlightID == requestID {
      inFlightID = nil
      inFlightTask = nil
    }
  }
}
