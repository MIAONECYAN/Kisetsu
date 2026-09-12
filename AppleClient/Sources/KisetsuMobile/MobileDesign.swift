import Foundation
import SwiftUI

enum MobileOrganizedTimePresentation {
  static func text(_ raw: String?, now: Date = Date()) -> String? {
    guard let raw else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: raw)
    if date == nil {
      formatter.formatOptions = [.withInternetDateTime]
      date = formatter.date(from: raw)
    }
    guard let date, date <= now else { return nil }
    let elapsed = now.timeIntervalSince(date)
    if elapsed < 60 { return "刚刚整理" }
    if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前整理" }
    if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前整理" }
    if elapsed < 86400 * 30 { return "\(Int(elapsed / 86400)) 天前整理" }
    return "整理于 \(date.formatted(.dateTime.year().month().day()))"
  }
}

enum MobilePlaylistAnimePresentation {
  static func mediaType(_ value: String) -> String? {
    switch value.lowercased() {
    case "tv": "电视动画"
    case "web": "网络动画"
    case "movie": "电影"
    case "ova": "OVA"
    default: value.isEmpty ? nil : value.uppercased()
    }
  }

  static func pairingSummary(_ pairing: PlexPairing) -> String {
    let source: String = switch pairing.source {
    case "external_id": "外部 ID"
    case "title": "标题"
    case "manual": "手动"
    default: "自动"
    }
    let score = pairing.score.isFinite ? "\(Int((min(max(pairing.score, 0), 1) * 100).rounded()))%" : nil
    return [pairing.year.map(String.init), "\(source)匹配", score].compactMap { $0 }.joined(separator: " · ")
  }
}

enum MobileMotion {
  static let status = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.20)
  static let reducedFade = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
  static let pressIn = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
  static let pressOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.08)
  static let progress = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
  static let directory = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
  static let hero = Animation.spring(duration: 0.5, bounce: 0.2)
}

enum MobileRefreshPresentation {
  static func isDisabled(isExternallyDisabled: Bool, isRefreshing: Bool) -> Bool {
    isExternallyDisabled || isRefreshing
  }
}

enum MobileSubscriptionProgressMotion {
  static func scale(fraction: Double, available: CGFloat) -> CGFloat {
    guard available > 0 else { return 0 }
    let clamped = CGFloat(min(max(fraction, 0), 1))
    return min(1, max(6 / available, clamped))
  }
}

enum MobileFormat {
  static func bytes(_ value: Int?) -> String {
    guard let value, value >= 0 else { return "--" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
  }

  static func speed(_ value: Int?) -> String {
    guard let value, value > 0 else { return "0 B/s" }
    return "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary))/s"
  }

  static func date(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "--" }
    return AppRelativeTime.concise(value)
  }
}

enum MobileStatusPresentation {
  static func autoDismissDelay(for phase: OperationPhase) -> TimeInterval? {
    switch phase {
    case .success: 2.5
    case .empty: 3.5
    case .failed: 6
    case .idle, .loading: nil
    }
  }
}

enum MobilePosterPalettePresentation {
  static func color(hex: String?) -> Color? {
    SubscriptionPalettePresentation.color(hex: hex)
  }
}

enum MobilePosterSizing {
  static let primaryListWidth: CGFloat = 84
  static let primaryListHeight: CGFloat = 120
}

enum MobileSubscriptionStatusPresentation {
  static func subscriptionSymbol(isEnabled: Bool) -> String {
    isEnabled ? "bell.badge.fill" : "bell.slash"
  }

  static func subscriptionAccessibilityLabel(isEnabled: Bool) -> String {
    isEnabled ? "订阅已启用" : "订阅已停用"
  }

  static func autoDownloadSymbol(isEnabled: Bool) -> String {
    isEnabled ? "arrow.down.circle.fill" : "arrow.down.circle"
  }

  static func autoDownloadAccessibilityLabel(isEnabled: Bool) -> String {
    isEnabled ? "自动下载已开启" : "自动下载已关闭"
  }

  static func tint(palette: PosterPalette?, isEnabled: Bool) -> Color {
    let base = SubscriptionPalettePresentation.colors(
      palette: palette,
      colorScheme: .light
    ).primary
    return isEnabled ? base : base.opacity(0.42)
  }

  static func tintHex(palette: PosterPalette?) -> String? {
    palette?.primary
  }
}

enum MobilePlaylistActionPresentation {
  static let selectionVisualSize: CGFloat = 13
  static let actionSpacing: CGFloat = 8

  static func pairingSymbol(isPaired: Bool) -> String {
    isPaired ? "link" : "link.badge.plus"
  }

  static func pairingAccessibilityLabel(isPaired: Bool) -> String {
    isPaired ? "修改配对" : "配对"
  }

  static func selectionSymbol(isSelected: Bool) -> String {
    isSelected ? "checkmark.circle.fill" : "circle"
  }

  static func selectionOpacity(isSelected: Bool) -> Double {
    isSelected ? 0.96 : 0.72
  }
}

enum MobileSpeedLimitDraft {
  static let bytesPerMegabyte = 1_048_576.0

  static func bytesPerSecond(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
          value.isFinite,
          value >= 0 else { return nil }
    let bytes = value * bytesPerMegabyte
    guard bytes <= Double(Int.max) else { return nil }
    return Int(bytes.rounded())
  }

  static func validationMessage(download: String, upload: String) -> String? {
    if bytesPerSecond(download) == nil {
      return "全局下载上限必须是大于或等于 0 的数字。"
    }
    if bytesPerSecond(upload) == nil {
      return "全局上传上限必须是大于或等于 0 的数字。"
    }
    return nil
  }
}

enum MobileFormValidation {
  static func httpURLMessage(
    _ value: String,
    field: String,
    allowsEmpty: Bool = false
  ) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return allowsEmpty ? nil : "\(field)不能为空。"
    }
    guard let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          components.host?.isEmpty == false,
          components.url != nil else {
      return "\(field)必须是以 http:// 或 https:// 开头的完整地址。"
    }
    return nil
  }

  static func httpURLListMessage(
    _ value: String,
    field: String,
    requiresValue: Bool
  ) -> String? {
    let entries = value
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if entries.isEmpty {
      return requiresValue ? "\(field)不能为空。" : nil
    }
    for (index, entry) in entries.enumerated() {
      if httpURLMessage(entry, field: field) != nil {
        return "\(field)第 \(index + 1) 行必须是完整的 HTTP 或 HTTPS 地址。"
      }
    }
    return nil
  }

  static func integerMessage(
    _ value: String,
    field: String,
    minimum: Int,
    allowsEmpty: Bool
  ) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return allowsEmpty ? nil : "\(field)不能为空。"
    }
    guard let parsed = Int(trimmed), parsed >= minimum else {
      return "\(field)必须是大于或等于 \(minimum) 的整数。"
    }
    return nil
  }

  static func signedIntegerMessage(
    _ value: String,
    field: String,
    allowsEmpty: Bool
  ) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return allowsEmpty ? nil : "\(field)不能为空。"
    }
    guard Int(trimmed) != nil else {
      return "\(field)必须是整数。"
    }
    return nil
  }

  static func positiveDecimalMessage(
    _ value: String,
    field: String,
    allowsEmpty: Bool
  ) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return allowsEmpty ? nil : "\(field)不能为空。"
    }
    guard let parsed = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
          parsed.isFinite,
          parsed > 0 else {
      return "\(field)必须是大于 0 的数字。"
    }
    return nil
  }

  static func episodeFilterMessage(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for rawPart in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
      let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !part.isEmpty else {
        return "集数过滤中存在空条件，请使用 1-6, 8, 10-12 这样的格式。"
      }
      if let value = Int(part), value >= 0 { continue }
      let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
      guard bounds.count == 2,
            let start = Int(bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
            let end = Int(bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
            start >= 0,
            end >= start else {
        return "集数过滤格式无效，请使用 1-6, 8, 10-12 这样的格式。"
      }
    }
    return nil
  }
}

struct MobileFormValidationMessage: View {
  var message: String?

  var body: some View {
    if let message {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("输入错误：\(message)")
    }
  }
}

struct MobileFormTextField: View {
  var label: String
  var prompt: String
  @Binding var text: String
  var alignment: TextAlignment = .trailing

  var body: some View {
    LabeledContent(label) {
      TextField(prompt, text: $text)
        .multilineTextAlignment(alignment)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("可编辑")
    }
  }

  private var accessibilityValue: String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未设置" : trimmed
  }
}

struct MobileFormSecureField: View {
  var label: String
  var prompt: String
  @Binding var text: String
  var reference: CredentialReference? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.subheadline)
      SecretValueField(label: label, prompt: prompt, text: $text, reference: reference)
    }
  }
}

struct MobileFormTextEditor: View {
  var label: String
  var hint: String? = nil
  @Binding var text: String
  var minHeight: CGFloat = 72

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label)
        .font(.subheadline)
      TextEditor(text: $text)
        .frame(minHeight: minHeight)
        .accessibilityLabel(label)
        .accessibilityValue(text.isEmpty ? "未设置" : text)
        .accessibilityHint("可编辑")
      if let hint {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

enum MobileMikanPresentation {
  static let subscribedSymbol = "bell.badge.fill"
  static let subscribedMarkerTitle = "已订阅"
  static let smartSubscriptionSymbol = "bell.badge"

  static let resourceActionControlSize: ControlSize = .regular

  static func filteredGroups(
    _ groups: [MikanProjectResourceGroup],
    selectedID: String?
  ) -> [MikanProjectResourceGroup] {
    guard let selectedID else { return groups }
    return groups.filter { $0.id == selectedID }
  }
}

struct MobileToolbarRefreshButton: View {
  var target: MobileRefreshTarget
  var isDisabled = false
  var isRefreshing = false
  var action: () async -> Void
  @State private var isPerformingAction = false

  private var showsProgress: Bool { isRefreshing || isPerformingAction }

  var body: some View {
    Button {
      guard !isDisabled, !showsProgress else { return }
      isPerformingAction = true
      Task {
        defer { isPerformingAction = false }
        await action()
      }
    } label: {
      Group {
        if showsProgress {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .frame(width: 24, height: 24)
    }
    .accessibilityLabel(target.accessibilityLabel)
    .accessibilityValue(showsProgress ? "正在刷新" : "")
    .disabled(MobileRefreshPresentation.isDisabled(
      isExternallyDisabled: isDisabled,
      isRefreshing: showsProgress
    ))
  }
}

enum MobileRefreshTarget: String, CaseIterable {
  case overview
  case subscriptions
  case subscriptionDetail
  case tasks
  case mikan
  case playlists
  case sites
  case files

  var accessibilityLabel: String {
    switch self {
    case .overview: "刷新概览"
    case .subscriptions: "刷新订阅"
    case .subscriptionDetail: "刷新订阅详情"
    case .tasks: "刷新任务"
    case .mikan: "刷新 Mikan Project"
    case .playlists: "刷新播放列表"
    case .sites: "刷新站点管理"
    case .files: "刷新文件管理"
    }
  }
}

struct MobileSectionHeader: View {
  var title: String
  var count: Int? = nil
  var systemImage: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      if let count {
        Text("\(count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .accessibilityElement(children: .combine)
  }
}

struct MobileErrorView: View {
  var title: String
  var message: String
  var retry: (() -> Void)?

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: "wifi.exclamationmark")
    } description: {
      Text(message)
    } actions: {
      if let retry {
        Button("重试", systemImage: "arrow.clockwise", action: retry)
          .buttonStyle(.glass)
      }
    }
  }
}

struct MobileTag: View {
  var text: String
  var systemImage: String? = nil
  var tint: Color = .secondary
  var maximumTextWidth: CGFloat? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: maximumTextWidth, alignment: .leading)
    }
    .font(.caption)
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(tint.opacity(0.10), in: Capsule())
  }
}

struct MobileTagFlowLayout: Layout {
  var horizontalSpacing: CGFloat = 6
  var verticalSpacing: CGFloat = 6

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    arrangement(for: subviews, proposedWidth: proposal.width).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    let layout = arrangement(for: subviews, proposedWidth: bounds.width)
    for (subview, frame) in zip(subviews, layout.frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height)
      )
    }
  }

  private func arrangement(for subviews: Subviews, proposedWidth: CGFloat?) -> Arrangement {
    let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let width = proposedWidth.flatMap { $0.isFinite ? max($0, 0) : nil }
      ?? idealSizes.map(\.width).max() ?? 0
    let sizes = zip(subviews, idealSizes).map { subview, ideal in
      subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
    }
    return arrangement(for: sizes, width: width)
  }

  func arrangement(for sizes: [CGSize], width: CGFloat) -> Arrangement {
    let availableWidth = max(width, 0)
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var hasItemInRow = false
    for size in sizes {
      let itemWidth = min(max(size.width, 0), availableWidth)
      if hasItemInRow && x + itemWidth > availableWidth {
        y += rowHeight + verticalSpacing
        x = 0
        rowHeight = 0
      }
      frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
      x += itemWidth + horizontalSpacing
      rowHeight = max(rowHeight, size.height)
      hasItemInRow = true
    }
    return Arrangement(size: CGSize(width: availableWidth, height: y + rowHeight), frames: frames)
  }

  struct Arrangement {
    var size: CGSize
    var frames: [CGRect]
  }
}

struct MobilePressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var isEnabled = true

  func makeBody(configuration: Configuration) -> some View {
    let isVisuallyPressed = configuration.isPressed && isEnabled
    configuration.label
      .scaleEffect(reduceMotion || !isVisuallyPressed ? 1 : 0.975)
      .opacity(isVisuallyPressed ? 0.96 : 1)
      .animation(
        reduceMotion ? MobileMotion.pressOut : (isVisuallyPressed ? MobileMotion.pressIn : MobileMotion.pressOut),
        value: isVisuallyPressed
      )
  }
}

extension View {
  func mobileNavigationTitle(
    _ title: String,
    displayMode: NavigationBarItem.TitleDisplayMode = .large
  ) -> some View {
    mobileStatusNavigationTitle(title)
      .navigationBarTitleDisplayMode(displayMode)
  }

  func mobileStatusNavigationTitle(_ title: String) -> some View {
    navigationTitle(title)
      .modifier(MobileStatusToolbarModifier())
  }
}
