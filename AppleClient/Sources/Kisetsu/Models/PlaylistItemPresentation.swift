import Foundation

struct PlaylistSchedulePresentation: Equatable {
  var dateText: String
  var scheduleText: String?
}

enum PlaylistSchedulePresenter {
  private enum Recurrence: Equatable {
    case once
    case daily
    case weekly
    case monthly
  }

  private struct BroadcastValue {
    var start: Date
    var recurrence: Recurrence
  }

  static func presentation(
    begin: String,
    broadcast: String?,
    mediaType: String,
    locale: Locale = Locale(identifier: "zh_CN"),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> PlaylistSchedulePresentation {
    let beginDate = parseDate(begin)
    let calendarDate = calendarDateText(begin, locale: locale)
    let broadcastValue = parseBroadcast(broadcast)
    let type = mediaType.lowercased()

    if type == "movie" {
      if broadcastValue == nil, let calendarDate {
        return PlaylistSchedulePresentation(dateText: "上映 · \(calendarDate)", scheduleText: nil)
      }
      guard let date = broadcastValue?.start ?? beginDate else {
        return PlaylistSchedulePresentation(dateText: "上映时间未知", scheduleText: nil)
      }
      return PlaylistSchedulePresentation(
        dateText: "上映 · \(dateOnly(date, locale: locale, timeZone: timeZone))",
        scheduleText: nil
      )
    }

    if type == "ova" {
      if broadcastValue == nil, let calendarDate {
        return PlaylistSchedulePresentation(dateText: "发售 · \(calendarDate)", scheduleText: nil)
      }
      guard let date = broadcastValue?.start ?? beginDate else {
        return PlaylistSchedulePresentation(dateText: "发售时间未知", scheduleText: nil)
      }
      return PlaylistSchedulePresentation(
        dateText: "发售 · \(dateOnly(date, locale: locale, timeZone: timeZone))",
        scheduleText: nil
      )
    }

    if let broadcastValue {
      if broadcastValue.recurrence == .once {
        return PlaylistSchedulePresentation(
          dateText: "播出 · \(dateAndTime(broadcastValue.start, locale: locale, timeZone: timeZone))",
          scheduleText: nil
        )
      }
      return PlaylistSchedulePresentation(
        dateText: calendarDate.map { "首播 · \($0)" } ?? beginDate.map { "首播 · \(dateOnly($0, locale: locale, timeZone: timeZone))" }
          ?? "首播时间未知",
        scheduleText: recurrenceText(
          broadcastValue,
          locale: locale,
          timeZone: timeZone
        )
      )
    }

    if let calendarDate {
      return PlaylistSchedulePresentation(dateText: "\(type == "web" ? "上线" : "首播") · \(calendarDate)", scheduleText: nil)
    }
    guard let beginDate else {
      return PlaylistSchedulePresentation(dateText: "播出时间未知", scheduleText: nil)
    }
    let prefix = type == "web" ? "上线" : "首播"
    return PlaylistSchedulePresentation(
      dateText: "\(prefix) · \(dateAndTime(beginDate, locale: locale, timeZone: timeZone))",
      scheduleText: nil
    )
  }

  private static func calendarDateText(_ value: String, locale: Locale) -> String? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
          let utc = TimeZone(secondsFromGMT: 0) else { return nil }
    let parser = formatter("yyyy-MM-dd", locale: Locale(identifier: "en_US_POSIX"), timeZone: utc)
    parser.isLenient = false
    guard let date = parser.date(from: text), parser.string(from: date) == text else { return nil }
    return dateOnly(date, locale: locale, timeZone: utc)
  }

  private static func parseBroadcast(_ value: String?) -> BroadcastValue? {
    guard let value else { return nil }
    let components = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 3,
          components[0] == "R",
          let start = parseDate(String(components[1])) else { return nil }
    let recurrence: Recurrence
    switch components[2] {
    case "P0D": recurrence = .once
    case "P1D": recurrence = .daily
    case "P7D": recurrence = .weekly
    case "P1M": recurrence = .monthly
    default: return nil
    }
    return BroadcastValue(start: start, recurrence: recurrence)
  }

  private static func parseDate(_ value: String) -> Date? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    if let date = isoFormatter(fractionalSeconds: true).date(from: cleaned) {
      return date
    }
    return isoFormatter(fractionalSeconds: false).date(from: cleaned)
  }

  private static func recurrenceText(
    _ value: BroadcastValue,
    locale: Locale,
    timeZone: TimeZone
  ) -> String {
    let time = timeOnly(value.start, locale: locale, timeZone: timeZone)
    switch value.recurrence {
    case .once:
      return "单次播出 · \(dateAndTime(value.start, locale: locale, timeZone: timeZone))"
    case .daily:
      return "每日 \(time)"
    case .weekly:
      return "每\(weekday(value.start, locale: locale, timeZone: timeZone)) \(time)"
    case .monthly:
      var calendar = Calendar(identifier: .gregorian)
      calendar.locale = locale
      calendar.timeZone = timeZone
      return "每月 \(calendar.component(.day, from: value.start)) 日 \(time)"
    }
  }

  private static func dateOnly(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
    formatter("yyyy年M月d日", locale: locale, timeZone: timeZone).string(from: date)
  }

  private static func dateAndTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
    formatter("yyyy年M月d日 HH:mm", locale: locale, timeZone: timeZone).string(from: date)
  }

  private static func timeOnly(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
    formatter("HH:mm", locale: locale, timeZone: timeZone).string(from: date)
  }

  private static func weekday(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
    formatter("EEE", locale: locale, timeZone: timeZone).string(from: date)
  }

  private static func formatter(
    _ format: String,
    locale: Locale,
    timeZone: TimeZone
  ) -> DateFormatter {
    let key = "Kisetsu.Playlist.DateFormatter.\(locale.identifier).\(timeZone.identifier).\(format)"
    if let formatter = Thread.current.threadDictionary[key] as? DateFormatter {
      return formatter
    }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    Thread.current.threadDictionary[key] = formatter
    return formatter
  }

  private static func isoFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
    let key = "Kisetsu.Playlist.ISO8601.\(fractionalSeconds)"
    if let formatter = Thread.current.threadDictionary[key] as? ISO8601DateFormatter {
      return formatter
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractionalSeconds
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    Thread.current.threadDictionary[key] = formatter
    return formatter
  }
}

struct PlaylistExternalLinkPresentation: Identifiable, Equatable {
  var title: String
  var url: URL
  var id: String { url.absoluteString }
}

struct PlaylistExternalLinkGroup: Identifiable, Equatable {
  var kind: String
  var title: String
  var systemImage: String
  var links: [PlaylistExternalLinkPresentation]
  var id: String { kind }
}

enum PlaylistExternalLinkPresenter {
  private static let categories: [(kind: String, title: String, systemImage: String)] = [
    ("info", "情报", "info.circle"),
    ("onair", "配信", "play.tv"),
    ("resource", "下载", "arrow.down.circle"),
  ]

  static func groups(for links: [PlaylistSiteLink]) -> [PlaylistExternalLinkGroup] {
    var seenURLs: Set<String> = []
    let safeLinks = links.compactMap { link -> (String, PlaylistExternalLinkPresentation)? in
      guard let url = safeURL(link.url) else { return nil }
      let key = url.absoluteString
      guard seenURLs.insert(key).inserted else { return nil }
      let title = [link.title, link.site, url.host]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "网站"
      return (link.kind, PlaylistExternalLinkPresentation(title: title, url: url))
    }

    return categories.compactMap { category in
      let categoryLinks = safeLinks.compactMap { kind, link in
        kind == category.kind ? link : nil
      }
      guard !categoryLinks.isEmpty else { return nil }
      return PlaylistExternalLinkGroup(
        kind: category.kind,
        title: category.title,
        systemImage: category.systemImage,
        links: categoryLinks
      )
    }
  }

  private static func safeURL(_ value: String) -> URL? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: cleaned),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          components.host?.isEmpty == false,
          components.user == nil,
          components.password == nil else { return nil }
    components.scheme = scheme
    components.host = components.host?.lowercased()
    return components.url
  }
}
