import SwiftUI

struct StatusBannerView: View {
  var status: OperationStatus
  @State private var isVisible = false
  @State private var dismissedStatusId: UUID?
  @State private var visibleStatusId: UUID?

  var body: some View {
    Group {
      if canShow {
        HStack(alignment: .center, spacing: 8) {
          if status.phase == .loading {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: status.phase.iconName)
              .foregroundStyle(tint)
              .font(.system(size: 15, weight: .semibold))
          }

          Text(compactMessage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

          Button {
            dismissedStatusId = status.id
            withAnimation(.snappy(duration: 0.18)) {
              isVisible = false
            }
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.plain)
          .help("关闭提示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 560, alignment: .center)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: KisetsuStyle.cardRadius, style: .continuous)
            .stroke(tint.opacity(0.28), lineWidth: 0.8)
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : -6)
        .animation(.snappy(duration: 0.2), value: isVisible)
        .onAppear {
          showAndScheduleDismiss()
        }
        .onChange(of: status.id) {
          showAndScheduleDismiss()
        }
      }
    }
    .allowsHitTesting(shouldShow)
  }

  private var canShow: Bool {
    status.phase != .idle && dismissedStatusId != status.id
  }

  private var shouldShow: Bool {
    canShow && isVisible
  }

  private func showAndScheduleDismiss() {
    guard status.phase != .idle else {
      isVisible = false
      return
    }
    dismissedStatusId = nil
    visibleStatusId = status.id
    withAnimation(.snappy(duration: 0.2)) {
      isVisible = true
    }
    let delay: Duration = status.phase == .failed ? .seconds(8) : status.phase == .loading ? .seconds(90) : .seconds(4)
    let scheduledStatusId = status.id
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      guard visibleStatusId == scheduledStatusId, scheduledStatusId != dismissedStatusId else { return }
      withAnimation(.snappy(duration: 0.2)) {
        isVisible = false
      }
    }
  }

  private var tint: Color {
    switch status.phase {
    case .idle: .secondary
    case .loading: .accentColor
    case .success: .green
    case .empty: .secondary
    case .failed: .red
    }
  }

  private var compactMessage: String {
    let title = status.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if detail.isEmpty {
      return title
    }
    return "\(title) · \(detail)"
  }
}
