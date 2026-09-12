import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Revealed server values never become an edit or a subsequent save payload.
struct SecretValueField: View {
  var label: String
  var prompt: String
  @Binding var text: String
  var reference: CredentialReference? = nil
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var revealed = false
  @State private var savedValue: String?
  @State private var pending: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var feedback: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Group {
          if revealed {
            TextField(prompt, text: $text, axis: .vertical)
              .lineLimit(1...4)
          } else {
            SecureField(prompt, text: $text)
          }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .accessibilityLabel(label)
        action(revealed ? "隐藏\(label)" : "显示\(label)", symbol: revealed ? "eye.slash" : "eye") {
          if revealed { reset() } else { read(copy: false) }
        }
        action("复制\(label)", symbol: "doc.on.doc") { read(copy: true) }
          .disabled(text.isEmpty && reference == nil)
      }
      if revealed, text.isEmpty, let savedValue {
        ScrollView {
          Text(savedValue)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)完整内容")
        .accessibilityValue(savedValue)
      }
      if pending != nil {
        ProgressView().controlSize(.small)
      } else if let feedback {
        Text(feedback).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onDisappear { reset() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { reset() } }
    .onChange(of: reference) { _, _ in reset() }
    .onChange(of: store.backendURL) { _, _ in reset() }
    .onChange(of: text) { _, _ in
      savedValue = nil
      feedback = nil
      pending?.cancel()
      pending = nil
      generation = UUID()
    }
  }

  private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      Image(systemName: symbol).font(.system(size: 14))
        #if os(iOS)
        .frame(width: 44, height: 44)
        #else
        .frame(width: 28, height: 28)
        #endif
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(title)
    .help(title)
    .disabled(pending != nil)
  }

  private func read(copy: Bool) {
    guard pending == nil else { return }
    feedback = nil
    if !text.isEmpty {
      if copy { copyValue(text) } else { revealed = true }
      return
    }
    guard let reference else { revealed = true; return }
    let requestGeneration = generation
    let client = store.client
    pending = Task { @MainActor in
      defer { if generation == requestGeneration { pending = nil } }
      do {
        let value = try await client.credential(reference)
        guard !Task.isCancelled, generation == requestGeneration else { return }
        guard !value.isEmpty else { feedback = "尚未保存\(label)"; return }
        if copy { copyValue(value) } else { savedValue = value; revealed = true }
      } catch {
        guard !Task.isCancelled, generation == requestGeneration else { return }
        if case APIClientError.server(404, _) = error {
          feedback = "请升级后端以查看完整凭证。"
        } else {
          feedback = "读取凭证失败，请重试。"
        }
      }
    }
  }

  private func copyValue(_ value: String) {
    #if os(iOS)
    UIPasteboard.general.string = value
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    #endif
    feedback = "已复制\(label)"
  }

  private func reset() {
    pending?.cancel()
    pending = nil
    generation = UUID()
    revealed = false
    savedValue = nil
    feedback = nil
  }
}
