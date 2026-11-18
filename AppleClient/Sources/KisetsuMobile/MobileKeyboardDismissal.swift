import SwiftUI
import UIKit

struct MobileKeyboardDismissal: UIViewRepresentable {
  func makeUIView(context: Context) -> WindowAttachment {
    let view = WindowAttachment()
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ uiView: WindowAttachment, context: Context) {}

  final class WindowAttachment: UIView, UIGestureRecognizerDelegate {
    private weak var editorAtTouchStart: UIView?
    private lazy var tap: UITapGestureRecognizer = {
      let recognizer = ObservingTap(target: self, action: #selector(didTapOutsideEditor))
      recognizer.delegate = self
      recognizer.cancelsTouchesInView = false
      recognizer.delaysTouchesBegan = false
      recognizer.delaysTouchesEnded = false
      return recognizer
    }()

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard tap.view !== window else { return }
      tap.view?.removeGestureRecognizer(tap)
      window?.addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      editorAtTouchStart = nil
      guard let window, let hit = touch.view, hit.window === window,
            !Self.isTextInputHit(hit),
            let editor = Self.activeEditor(in: window),
            !editor.bounds.contains(touch.location(in: editor)) else { return false }
      editorAtTouchStart = editor
      return true
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }

    @objc private func didTapOutsideEditor() {
      let editor = editorAtTouchStart
      editorAtTouchStart = nil
      // Finish the original tap before changing keyboard insets or navigation layout.
      Task { @MainActor [weak self, weak editor] in
        guard let window = self?.window, let editor,
              editor.window === window, editor.isFirstResponder else { return }
        editor.resignFirstResponder()
      }
    }

    static func isTextInputHit(_ view: UIView) -> Bool {
      var ancestor: UIView? = view
      while let current = ancestor {
        if current is any UITextInput { return true }
        ancestor = current.superview
      }
      return false
    }

    private static func activeEditor(in view: UIView) -> UIView? {
      if view.isFirstResponder && view is any UITextInput { return view }
      for child in view.subviews.reversed() {
        if let editor = activeEditor(in: child) { return editor }
      }
      return nil
    }
  }
}

private final class ObservingTap: UITapGestureRecognizer {
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }
}
