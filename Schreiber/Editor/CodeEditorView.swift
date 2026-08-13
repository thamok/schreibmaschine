import SwiftUI
import UIKit

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> CodeTextView {
        let textView = CodeTextView()
        textView.delegate = context.coordinator
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: CodeTextView, context: Context) {
        guard textView.text != text else {
            return
        }

        let selection = textView.selectedRange
        textView.text = text
        textView.selectedRange = NSRange(
            location: min(selection.location, textView.text.utf16.count),
            length: 0
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
