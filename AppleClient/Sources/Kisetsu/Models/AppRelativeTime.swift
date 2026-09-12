import Foundation

enum AppRelativeTime {
  static func concise(_ raw: String) -> String {
    guard let date = parse(raw) else { return raw }
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 {
      return "刚刚"
    }
    if seconds < 3_600 {
      return "\(max(seconds / 60, 1)) 分钟前"
    }
    if seconds < 86_400 {
      return "\(max(seconds / 3_600, 1)) 小时前"
    }
    if seconds < 86_400 * 7 {
      return "\(max(seconds / 86_400, 1)) 天前"
    }
    return absoluteFormatter.string(from: date)
  }

  private static func parse(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) {
      return date
    }
    return ISO8601DateFormatter().date(from: raw)
  }

  private static let absoluteFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
  }()
}
