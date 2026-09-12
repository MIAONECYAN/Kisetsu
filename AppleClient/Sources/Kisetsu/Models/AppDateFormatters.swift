import Foundation

extension DateFormatter {
  static let statusTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()
}
