import Foundation

struct LatestOperationSequence {
  private(set) var latestID: UInt64 = 0

  mutating func begin() -> UInt64 {
    latestID &+= 1
    return latestID
  }

  func accepts(_ id: UInt64) -> Bool {
    id == latestID
  }
}

struct MetadataBindingSubmissionGate {
  private(set) var activeCandidateID: String?

  mutating func begin(candidateID: String) -> Bool {
    guard activeCandidateID == nil else { return false }
    activeCandidateID = candidateID
    return true
  }

  mutating func finish(candidateID: String) {
    guard activeCandidateID == candidateID else { return }
    activeCandidateID = nil
  }
}

enum AppOperationContext {
  @TaskLocal static var identifier: UInt64?
}
