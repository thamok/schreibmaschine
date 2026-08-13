import SwiftUI
import UIKit

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var language: EditorLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    func makeUIView(context: Context) -> CodeTextView {
        let textView = CodeTextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.language = language
        textView.rehighlight()
        return textView
    }

    func updateUIView(_ textView: CodeTextView, context: Context) {
        textView.language = language
        guard textView.text != text else {
            if textView.selectedRange != selection { textView.selectedRange = selection }
            return
        }

        textView.text = text
        textView.selectedRange = NSRange(
            location: min(selection.location, textView.text.utf16.count),
            length: min(selection.length, max(0, textView.text.utf16.count - selection.location))
        )
        textView.rehighlight()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var selection: NSRange

        init(text: Binding<String>, selection: Binding<NSRange>) {
            _text = text
            _selection = selection
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
            (textView as? CodeTextView)?.didEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection = textView.selectedRange
            (textView as? CodeTextView)?.selectionDidChange()
        }
    }
}
