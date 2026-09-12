import AppKit
import SwiftUI

struct AppTextFieldStyle: TextFieldStyle {
  @Environment(\.isEnabled) private var isEnabled

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(Color(nsColor: .textBackgroundColor).opacity(isEnabled ? 0.96 : 0.55), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color.secondary.opacity(isEnabled ? 0.28 : 0.14), lineWidth: 1)
      )
      .opacity(isEnabled ? 1 : 0.72)
  }
}

struct InputHelpText: View {
  var text: String

  var body: some View {
    if !text.isEmpty {
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

struct InlineValidationMessage: View {
  var text: String?

  var body: some View {
    if let text, !text.isEmpty {
      Label(text, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }
}

struct FormField<Control: View>: View {
  var label: String
  var help: String = ""
  var error: String? = nil
  @ViewBuilder var control: Control

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
      control
      InputHelpText(text: help)
      InlineValidationMessage(text: error)
    }
  }
}

struct LabeledDirectoryPathField: View {
  let label: String
  let placeholder: String
  @Binding var path: String

  var body: some View {
    FormField(label: label) {
      HStack(spacing: 8) {
        TextField("", text: $path, prompt: Text(placeholder))
          .truncationMode(.middle)
          .accessibilityLabel(label)
        Button {
          chooseDirectory()
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 24)
        .help("选择文件夹")
        .accessibilityLabel("选择文件夹")
      }
    }
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "选择"
    if panel.runModal() == .OK, let url = panel.url {
      path = url.path
    }
  }
}

struct LabeledTextField: View {
  var label: String
  var placeholder: String
  @Binding var text: String
  var help: String = ""
  var error: String? = nil
  var disabled = false

  var body: some View {
    FormField(label: label, help: help, error: error) {
      TextField("", text: $text, prompt: Text(placeholder))
        .disabled(disabled)
        .accessibilityLabel(label)
    }
  }
}

struct LabeledSecureField: View {
  var label: String
  var placeholder: String
  @Binding var text: String
  var help: String = ""
  var error: String? = nil
  var disabled = false
  var reference: CredentialReference? = nil

  var body: some View {
    FormField(label: label, help: help, error: error) {
      SecretValueField(label: label, prompt: placeholder, text: $text, reference: reference)
        .disabled(disabled)
    }
  }
}

struct LabeledSecretField: View {
  var label: String
  var placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool
  var help: String = ""
  var error: String? = nil
  var disabled = false
  var trailingText: String? = nil
  var onClear: (() -> Void)? = nil

  var body: some View {
    FormField(label: label, help: help, error: error) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Group {
            if isRevealed {
              TextField("", text: $text, prompt: Text(placeholder))
            } else {
              SecureField("", text: $text, prompt: Text(placeholder))
            }
          }
          .disabled(disabled)
          .accessibilityLabel(label)
          Button {
            isRevealed.toggle()
          } label: {
            Label(isRevealed ? "隐藏" : "显示", systemImage: isRevealed ? "eye.slash" : "eye")
          }
          .disabled(disabled)
          if let onClear {
            Button(role: .destructive) {
              onClear()
            } label: {
              Label("清除", systemImage: "xmark.bin")
            }
            .disabled(disabled)
          }
        }
        if let trailingText, !trailingText.isEmpty {
          Text(trailingText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct LabeledTextEditor: View {
  var label: String
  @Binding var text: String
  var help: String = ""
  var minHeight: CGFloat = 82

  var body: some View {
    FormField(label: label, help: help) {
      AppInputContainer {
        TextEditor(text: $text)
          .scrollContentBackground(.hidden)
          .frame(minHeight: minHeight)
          .accessibilityLabel(label)
      }
    }
  }
}

struct AppInputContainer<Content: View>: View {
  var isError = false
  var isReadOnly = false
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(background, in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .stroke(borderColor, lineWidth: 1)
      )
  }

  private var background: Color {
    if isReadOnly {
      return Color(nsColor: .controlBackgroundColor).opacity(0.74)
    }
    return Color(nsColor: .textBackgroundColor).opacity(0.96)
  }

  private var borderColor: Color {
    if isError {
      return .red.opacity(0.55)
    }
    if isReadOnly {
      return Color.secondary.opacity(0.20)
    }
    return Color.secondary.opacity(0.30)
  }
}

struct CodeBlockView: View {
  var text: String
  var isError = false
  var isReadOnly = true

  var body: some View {
    AppInputContainer(isError: isError, isReadOnly: isReadOnly) {
      ScrollView(.horizontal, showsIndicators: true) {
        Text(text.isEmpty ? "暂无内容" : text)
          .font(.body.monospaced())
          .foregroundStyle(text.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
