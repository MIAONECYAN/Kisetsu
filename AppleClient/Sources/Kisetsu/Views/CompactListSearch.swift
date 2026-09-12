import AppKit
import SwiftUI

struct CompactListSearchAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(
    value: inout Anchor<CGRect>?,
    nextValue: () -> Anchor<CGRect>?
  ) {
    value = nextValue() ?? value
  }
}

struct CompactListSearchButton: View {
  var search: SubscriptionSearchPresentationState
  var label: String
  var resultCount: Int
  var totalCount: Int
  var itemName: String
  var toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(search.isActive ? Color.accentColor : Color.primary)
        .frame(width: 16, height: 16)
        .overlay(alignment: .topTrailing) {
          if search.isActive {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 5, height: 5)
          }
        }
    }
    .frame(width: 34)
    .help(search.isActive ? "\(label)：\(search.query)" : label)
    .accessibilityLabel(label)
    .accessibilityValue(
      search.isActive
        ? "\(resultCount) 个匹配，共 \(totalCount) 个\(itemName)"
        : "未启用"
    )
    .anchorPreference(
      key: CompactListSearchAnchorKey.self,
      value: .bounds
    ) { bounds in
      bounds
    }
  }
}

struct CompactListSearchOverlay: View {
  @Binding var query: String
  @FocusState private var searchIsFocused: Bool
  var presentationID: Int
  var focusID: Int?
  var resultCount: Int
  var prompt: String
  var itemName: String
  var attachedToWindow: (Int, Bool) -> Void
  var escape: () -> Bool

  private var isActive: Bool {
    !SubscriptionSearch.normalizedTokens(query).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      searchField

      if isActive {
        Text(resultCount == 0 ? "没有匹配的\(itemName)" : "找到 \(resultCount) 个\(itemName)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(resultCount == 0 ? "没有匹配的\(itemName)" : "找到 \(resultCount) 个\(itemName)")
      }
    }
    .padding(12)
    .frame(width: 300)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
    }
    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    .background {
      CompactSearchWindowAttachmentReader(
        presentationID: presentationID,
        attachedToWindow: attachedToWindow
      )
    }
    .onChange(of: focusID, initial: true) { _, newFocusID in
      searchIsFocused = newFocusID == presentationID
    }
    .onKeyPress(.escape) {
      escape() ? .handled : .ignored
    }
    .accessibilityElement(children: .contain)
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("", text: $query, prompt: Text(prompt))
        .textFieldStyle(.plain)
        .focused($searchIsFocused)
        .accessibilityLabel(prompt)

      if isActive {
        Button {
          query = ""
          searchIsFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 30)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(searchIsFocused ? Color.accentColor : Color.secondary.opacity(0.24), lineWidth: 1)
    }
  }
}

private struct CompactSearchWindowAttachmentReader: NSViewRepresentable {
  var presentationID: Int
  var attachedToWindow: (Int, Bool) -> Void

  func makeNSView(context: Context) -> AttachmentView {
    let view = AttachmentView()
    view.presentationID = presentationID
    view.attachedToWindow = attachedToWindow
    return view
  }

  func updateNSView(_ nsView: AttachmentView, context: Context) {
    nsView.presentationID = presentationID
    nsView.attachedToWindow = attachedToWindow
    nsView.reportAttachmentIfNeeded()
  }

  final class AttachmentView: NSView {
    var presentationID = 0
    var attachedToWindow: ((Int, Bool) -> Void)?
    private var reportedPresentationID: Int?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reportAttachmentIfNeeded()
    }

    func reportAttachmentIfNeeded() {
      guard let window,
            window.isVisible,
            reportedPresentationID != presentationID
      else { return }

      reportedPresentationID = presentationID
      let id = presentationID
      Task { @MainActor [weak self] in
        guard let self,
              self.window === window,
              window.isVisible
        else { return }
        self.attachedToWindow?(id, true)
      }
    }
  }
}
