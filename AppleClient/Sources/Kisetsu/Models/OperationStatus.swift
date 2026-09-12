import Foundation

enum OperationPhase: String {
  case idle
  case loading
  case success
  case empty
  case failed

  var iconName: String {
    switch self {
    case .idle: "circle"
    case .loading: "hourglass"
    case .success: "checkmark.circle.fill"
    case .empty: "tray"
    case .failed: "exclamationmark.triangle.fill"
    }
  }
}

struct OperationStatus: Identifiable, Equatable {
  let id = UUID()
  var phase: OperationPhase
  var title: String
  var detail: String
  var updatedAt: Date

  static var idle: OperationStatus {
    OperationStatus(
      phase: .idle,
      title: "准备就绪",
      detail: "尚未执行操作",
      updatedAt: Date()
    )
  }
}
