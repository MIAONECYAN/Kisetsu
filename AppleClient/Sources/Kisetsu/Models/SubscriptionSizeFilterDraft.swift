import Foundation

enum SubscriptionSizeUnit: String, CaseIterable, Identifiable {
  case megabytes = "MB"
  case gigabytes = "GB"

  var id: String { rawValue }

  var multiplier: Double {
    switch self {
    case .megabytes: 1024 * 1024
    case .gigabytes: 1024 * 1024 * 1024
    }
  }
}

struct SubscriptionSizeFilterDraft: Equatable {
  var minimumText: String
  var minimumUnit: SubscriptionSizeUnit
  var maximumText: String
  var maximumUnit: SubscriptionSizeUnit

  var validationMessage: String? {
    do {
      _ = try resolvedRange()
      return nil
    } catch let error as ValidationError {
      return error.message
    } catch {
      return "视频体积设置无效。"
    }
  }

  func resolvedRange() throws -> (minimum: Int?, maximum: Int?) {
    let minimum = try Self.bytes(from: minimumText, unit: minimumUnit, fieldName: "最小体积")
    let maximum = try Self.bytes(from: maximumText, unit: maximumUnit, fieldName: "最大体积")
    if let minimum, let maximum, minimum > maximum {
      throw ValidationError(message: "最小视频体积不能大于最大视频体积。")
    }
    return (minimum, maximum)
  }

  static func convertedText(_ text: String, from oldUnit: SubscriptionSizeUnit, to newUnit: SubscriptionSizeUnit) -> String {
    guard oldUnit != newUnit,
          let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite,
          value > 0 else { return text }
    return formatted(value * oldUnit.multiplier / newUnit.multiplier)
  }

  static func display(bytes: Int?) -> (text: String, unit: SubscriptionSizeUnit) {
    guard let bytes, bytes > 0 else { return ("", .gigabytes) }
    let unit: SubscriptionSizeUnit = bytes >= Int(SubscriptionSizeUnit.gigabytes.multiplier) ? .gigabytes : .megabytes
    return (formatted(Double(bytes) / unit.multiplier), unit)
  }

  static func persistenceValidationMessage(
    requestedMinimum: Int?,
    requestedMaximum: Int?,
    persistedMinimum: Int?,
    persistedMaximum: Int?
  ) -> String? {
    guard requestedMinimum != persistedMinimum || requestedMaximum != persistedMaximum else {
      return nil
    }
    return "后端未保存视频体积条件。请升级 Kisetsu 后端后重试。"
  }

  private static func bytes(from text: String, unit: SubscriptionSizeUnit, fieldName: String) throws -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let value = Double(trimmed), value.isFinite, value > 0 else {
      throw ValidationError(message: "\(fieldName)请输入大于 0 的有限数字。")
    }
    let bytes = value * unit.multiplier
    guard bytes.isFinite, bytes < Double(Int.max) else {
      throw ValidationError(message: "\(fieldName)超出可用范围。")
    }
    return Int(bytes.rounded())
  }

  private static func formatted(_ value: Double) -> String {
    value.formatted(
      .number
        .locale(Locale(identifier: "en_US_POSIX"))
        .grouping(.never)
        .precision(.fractionLength(0...6))
    )
  }

  private struct ValidationError: LocalizedError {
    var message: String

    var errorDescription: String? { message }
  }
}
