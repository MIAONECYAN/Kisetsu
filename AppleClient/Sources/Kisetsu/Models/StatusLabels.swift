import Foundation

enum StatusLabels {
  static func match(_ status: String) -> String {
    switch status {
    case "new":
      "新匹配"
    case "matched":
      "已匹配"
    case "skipped":
      "已跳过"
    case "queued":
      "已提交下载"
    case "dry_run":
      "未提交记录"
    case "error":
      "错误"
    default:
      passthrough(status)
    }
  }

  static func download(_ status: String) -> String {
    switch status {
    case "queued":
      "已提交下载"
    case "dry_run":
      "未提交记录"
    case "error":
      "提交失败"
    case "skipped":
      "已跳过"
    case "new":
      "新记录"
    case "organized":
      "已整理"
    case "organized_task_removed":
      "已整理并移除任务"
    case "deleted":
      "已从 qBittorrent 移除"
    default:
      passthrough(status)
    }
  }

  static func message(_ value: String?) -> String {
    guard let value else { return "无" }
    switch value {
    case "error":
      return "存在提交失败的匹配条目"
    case "queued":
      return "已提交下载"
    case "dry_run":
      return "未提交记录"
    case "skipped":
      return "已跳过"
    case "new":
      return "新匹配"
    default:
      return passthrough(value)
    }
  }

  private static func passthrough(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未知" : trimmed
  }
}
