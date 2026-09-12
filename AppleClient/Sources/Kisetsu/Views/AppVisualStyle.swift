import AppKit
import SwiftUI

enum KisetsuStyle {
  static let cardRadius: CGFloat = 7
  static let posterRadius: CGFloat = 7
  static let pagePadding: CGFloat = 20
  static let sectionSpacing: CGFloat = 20
  static let rowSpacing: CGFloat = 10
  static let toolbarVerticalPadding: CGFloat = 12
  static let contentMaxWidth: CGFloat = 1220

  static var cardBackground: Color {
    Color(nsColor: .controlBackgroundColor).opacity(0.30)
  }

  static var elevatedCardBackground: Color {
    Color(nsColor: .textBackgroundColor).opacity(0.74)
  }

  static var subtleBorder: Color {
    Color.primary.opacity(0.065)
  }

  static var selectionBackground: Color {
    Color.accentColor.opacity(0.10)
  }

  static var hoverBackground: Color {
    Color.primary.opacity(0.04)
  }

  static var animeTint: Color {
    Color(red: 0.28, green: 0.53, blue: 0.92)
  }

  static var sakuraTint: Color {
    Color(red: 0.92, green: 0.43, blue: 0.62)
  }

  static func statusColor(_ severity: String) -> Color {
    switch severity {
    case "success": .green
    case "warning": .orange
    case "error": .red
    default: .blue
    }
  }
}

struct AnimeCardModifier: ViewModifier {
  var elevated = false

  func body(content: Content) -> some View {
    content
      .background(
        elevated ? KisetsuStyle.elevatedCardBackground : KisetsuStyle.cardBackground,
        in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
          .stroke(KisetsuStyle.subtleBorder, lineWidth: elevated ? 0.8 : 0.6)
      }
  }
}

struct AppleTVPosterHoverPreset: Sendable {
  var maximumTilt: CGFloat
  var hoveredScale: CGFloat
  var lift: CGFloat
  var highlightOpacity: CGFloat
  var highlightRadius: CGFloat

  static let hero = Self(
    maximumTilt: 4.5,
    hoveredScale: 1.025,
    lift: 3,
    highlightOpacity: 0.12,
    highlightRadius: 150
  )

  static let rail = Self(
    maximumTilt: 5,
    hoveredScale: 1.03,
    lift: 3,
    highlightOpacity: 0.13,
    highlightRadius: 130
  )

  static let grid = Self(
    maximumTilt: 5.5,
    hoveredScale: 1.03,
    lift: 3,
    highlightOpacity: 0.14,
    highlightRadius: 145
  )

  static let list = Self(
    maximumTilt: 4.5,
    hoveredScale: 1.025,
    lift: 2.5,
    highlightOpacity: 0.12,
    highlightRadius: 120
  )
}

struct AppleTVPosterHoverState: Equatable, Sendable {
  var rotationX: CGFloat
  var rotationY: CGFloat
  var scale: CGFloat
  var lift: CGFloat
  var highlightX: CGFloat
  var highlightY: CGFloat
  var highlightOpacity: CGFloat
  var isHovered: Bool

  static let idle = Self(
    rotationX: 0,
    rotationY: 0,
    scale: 1,
    lift: 0,
    highlightX: 0.5,
    highlightY: 0.5,
    highlightOpacity: 0,
    isHovered: false
  )
}

enum AppleTVPosterHoverMath {
  static func state(
    location: CGPoint,
    size: CGSize,
    preset: AppleTVPosterHoverPreset,
    reduceMotion: Bool
  ) -> AppleTVPosterHoverState {
    guard size.width > 0, size.height > 0 else { return .idle }

    let unitX = clamp(location.x / size.width, lower: 0, upper: 1)
    let unitY = clamp(location.y / size.height, lower: 0, upper: 1)
    let normalizedX = unitX * 2 - 1
    let normalizedY = unitY * 2 - 1

    if reduceMotion {
      return AppleTVPosterHoverState(
        rotationX: 0,
        rotationY: 0,
        scale: 1,
        lift: 0,
        highlightX: 0.5,
        highlightY: 0.5,
        highlightOpacity: min(preset.highlightOpacity, 0.06),
        isHovered: true
      )
    }

    return AppleTVPosterHoverState(
      rotationX: -normalizedY * preset.maximumTilt,
      rotationY: normalizedX * preset.maximumTilt,
      scale: preset.hoveredScale,
      lift: preset.lift,
      highlightX: unitX,
      highlightY: unitY,
      highlightOpacity: preset.highlightOpacity,
      isHovered: true
    )
  }

  private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}

@MainActor
final class AppleTVPosterHoverCoordinator {
  private(set) var isScrolling = false
  private(set) var activeInteractionID: UUID?
  private var resetActiveHover: (() -> Void)?

  func setScrolling(_ scrolling: Bool) {
    guard isScrolling != scrolling else { return }
    isScrolling = scrolling
    if scrolling {
      clearActiveHover()
    }
  }

  @discardableResult
  func activate(id: UUID, reset: @escaping () -> Void) -> Bool {
    guard !isScrolling else { return false }
    if activeInteractionID != id {
      clearActiveHover()
      activeInteractionID = id
    }
    resetActiveHover = reset
    return true
  }

  func deactivate(id: UUID) {
    guard activeInteractionID == id else { return }
    activeInteractionID = nil
    resetActiveHover = nil
  }

  private func clearActiveHover() {
    let reset = resetActiveHover
    activeInteractionID = nil
    resetActiveHover = nil
    reset?()
  }
}

private struct AppleTVPosterHoverModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoverState = AppleTVPosterHoverState.idle
  @State private var contentSize = CGSize.zero
  @State private var interactionID = UUID()

  var preset: AppleTVPosterHoverPreset
  var cornerRadius: CGFloat
  var isEnabled: Bool
  var interactionSize: CGSize?
  var coordinator: AppleTVPosterHoverCoordinator?

  func body(content: Content) -> some View {
    content
      .overlay {
        if interactionSize == nil {
          GeometryReader { proxy in
            Color.clear
              .onAppear {
                contentSize = proxy.size
              }
              .onChange(of: proxy.size) { _, newSize in
                contentSize = newSize
              }
          }
          .allowsHitTesting(false)
        }
      }
      .overlay {
        if hoverState.isHovered {
          RadialGradient(
            colors: [
              Color.white,
              Color.white.opacity(0.26),
              Color.clear,
            ],
            center: UnitPoint(x: hoverState.highlightX, y: hoverState.highlightY),
            startRadius: 0,
            endRadius: preset.highlightRadius
          )
          .opacity(hoverState.highlightOpacity)
          .blendMode(.screen)
          .allowsHitTesting(false)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .rotation3DEffect(
        .degrees(hoverState.rotationX),
        axis: (x: 1, y: 0, z: 0),
        perspective: 0.72
      )
      .rotation3DEffect(
        .degrees(hoverState.rotationY),
        axis: (x: 0, y: 1, z: 0),
        perspective: 0.72
      )
      .scaleEffect(hoverState.scale)
      .offset(y: -hoverState.lift)
      .background {
        if hoverState.isHovered {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.10))
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 7)
        }
      }
      .zIndex(hoverState.isHovered ? 2 : 0)
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .onContinuousHover(coordinateSpace: .local) { phase in
        guard isEnabled else { return }
        switch phase {
        case .active(let location):
          guard coordinator?.activate(id: interactionID, reset: {
            resetHover(animated: false)
          }) != false else { return }
          hoverState = AppleTVPosterHoverMath.state(
            location: location,
            size: interactionSize ?? contentSize,
            preset: preset,
            reduceMotion: reduceMotion
          )
        case .ended:
          resetHover()
        }
      }
      .onChange(of: reduceMotion) { _, _ in
        resetHover()
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled {
          resetHover(animated: false)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        resetHover()
      }
      .onDisappear {
        resetHover(animated: false)
      }
      .animation(
        .interactiveSpring(response: 0.22, dampingFraction: 0.86, blendDuration: 0.08),
        value: hoverState
      )
  }

  private func resetHover(animated: Bool = true) {
    coordinator?.deactivate(id: interactionID)
    guard hoverState != .idle else { return }
    if animated && !reduceMotion {
      hoverState = .idle
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        hoverState = .idle
      }
    }
  }
}

struct SubscriptionRowHoverState: Equatable, Sendable {
  var lift: CGFloat
  var shadowOpacity: CGFloat
  var borderOpacity: CGFloat
  var isHovered: Bool

  static let idle = Self(
    lift: 0,
    shadowOpacity: 0,
    borderOpacity: 0,
    isHovered: false
  )
}

enum SubscriptionRowHoverMath {
  static func state(reduceMotion: Bool) -> SubscriptionRowHoverState {
    if reduceMotion {
      return SubscriptionRowHoverState(
        lift: 0,
        shadowOpacity: 0,
        borderOpacity: 0.05,
        isHovered: true
      )
    }

    return SubscriptionRowHoverState(
      lift: 2.5,
      shadowOpacity: 0.09,
      borderOpacity: 0.07,
      isHovered: true
    )
  }
}

private struct SubscriptionRowHoverModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoverState = SubscriptionRowHoverState.idle

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
          .fill(KisetsuStyle.cardBackground)
          .shadow(
            color: .black.opacity(hoverState.shadowOpacity),
            radius: 9,
            x: 0,
            y: 4
          )
        .allowsHitTesting(false)
      }
      .offset(y: -hoverState.lift)
      .zIndex(hoverState.isHovered ? 1 : 0)
      .overlay {
        RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
          .stroke(Color.primary.opacity(hoverState.borderOpacity), lineWidth: 0.8)
          .allowsHitTesting(false)
      }
      .onHover { hovering in
        updateHover(hovering: hovering)
      }
      .onChange(of: reduceMotion) { _, _ in
        updateHover(hovering: hoverState.isHovered)
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        resetHover()
      }
      .onDisappear {
        resetHover()
      }
  }

  private func updateHover(hovering: Bool) {
    let target = hovering ? SubscriptionRowHoverMath.state(reduceMotion: reduceMotion) : .idle
    let animation: Animation
    if reduceMotion {
      animation = .easeOut(duration: 0.10)
    } else if hovering {
      animation = .spring(response: 0.14, dampingFraction: 1, blendDuration: 0.04)
    } else {
      animation = .spring(response: 0.18, dampingFraction: 1, blendDuration: 0.06)
    }
    withAnimation(animation) {
      hoverState = target
    }
  }

  private func resetHover() {
    updateHover(hovering: false)
  }
}

struct AppToolbarSurfaceModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, KisetsuStyle.pagePadding)
      .padding(.vertical, KisetsuStyle.toolbarVerticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
      .overlay(alignment: .bottom) {
        Divider()
      }
  }
}

struct AppPageContentModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(KisetsuStyle.pagePadding)
      .frame(maxWidth: KisetsuStyle.contentMaxWidth, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

extension View {
  func animeCard(elevated: Bool = false) -> some View {
    modifier(AnimeCardModifier(elevated: elevated))
  }

  func appToolbarSurface() -> some View {
    modifier(AppToolbarSurfaceModifier())
  }

  func appPageContent() -> some View {
    modifier(AppPageContentModifier())
  }

  func appleTVPosterHover(
    _ preset: AppleTVPosterHoverPreset,
    cornerRadius: CGFloat = KisetsuStyle.posterRadius,
    isEnabled: Bool = true,
    interactionSize: CGSize? = nil,
    coordinator: AppleTVPosterHoverCoordinator? = nil
  ) -> some View {
    modifier(
      AppleTVPosterHoverModifier(
        preset: preset,
        cornerRadius: cornerRadius,
        isEnabled: isEnabled,
        interactionSize: interactionSize,
        coordinator: coordinator
      )
    )
  }

  func subscriptionRowHoverLift() -> some View {
    modifier(SubscriptionRowHoverModifier())
  }
}

struct SettingsNavigationRow: View {
  var title: String
  var symbol: String
  var isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .frame(width: 18)
        Text(title)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        isSelected ? KisetsuStyle.selectionBackground : Color.clear,
        in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
  }
}

struct PosterAmbientBackground: View {
  var palette: PosterPalette?
  var isEmphasized: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let colors = SubscriptionPalettePresentation.colors(palette: palette, colorScheme: colorScheme)
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      LinearGradient(
        colors: gradientColors(colors),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private func gradientColors(_ colors: SubscriptionPaletteColors) -> [Color] {
    let style = SubscriptionPalettePresentation.ambientStyle(colorScheme: colorScheme)
    return [
      colors.primary.opacity(style.primaryOpacity),
      colors.background.opacity(style.backgroundOpacity),
      colors.secondary.opacity(style.secondaryOpacity),
      .clear,
    ]
  }
}

extension Color {
  init?(hex: String?) {
    guard let hex else { return nil }
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255.0,
      green: Double((value >> 8) & 0xFF) / 255.0,
      blue: Double(value & 0xFF) / 255.0
    )
  }
}
