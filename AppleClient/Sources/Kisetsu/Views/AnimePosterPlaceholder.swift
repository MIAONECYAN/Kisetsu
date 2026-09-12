import AppKit
import SwiftUI

enum AnimePosterPlaceholderStatus: Equatable {
  case loading
  case unavailable

  var accessibilityLabel: String {
    switch self {
    case .loading: "正在加载海报"
    case .unavailable: "海报不可用"
    }
  }
}

struct AnimePosterPlaceholder: View {
  var status: AnimePosterPlaceholderStatus = .unavailable

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color.accentColor.opacity(0.20),
          KisetsuStyle.sakuraTint.opacity(0.12),
          Color(nsColor: .controlBackgroundColor),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      VStack(spacing: 8) {
        Image(systemName: "sparkles.tv")
          .font(.title2)
        Text("Anime")
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(status.accessibilityLabel)
  }
}
