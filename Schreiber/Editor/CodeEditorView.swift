import SwiftUI
import UIKit

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var language: EditorLanguage
    var theme: EditorTheme
    var hapticsEnabled: Bool
    var typeface: EditorTypeface
    var fontSize: Double
    var wrapsLines: Bool
    var requestAIEdit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    func makeUIView(context: Context) -> CodeTextView {
        let textView = CodeTextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.language = language
        textView.theme = theme
        textView.hapticsEnabled = hapticsEnabled
        textView.typeface = typeface
        textView.editorFontSize = fontSize
        textView.wrapsLines = wrapsLines
        textView.requestAIEdit = requestAIEdit
        textView.rehighlight()
        return textView
    }

    func updateUIView(_ textView: CodeTextView, context: Context) {
        textView.language = language
        textView.theme = theme
        textView.hapticsEnabled = hapticsEnabled
        textView.typeface = typeface
        textView.editorFontSize = fontSize
        textView.wrapsLines = wrapsLines
        textView.requestAIEdit = requestAIEdit
        guard textView.logicalText != text else {
            if textView.selectedRange != selection {
                textView.selectedRange = selection
                textView.scrollRangeToVisible(selection)
            }
            return
        }

        let previousText = textView.logicalText
        textView.prepareForExternalTextUpdate()
        textView.undoManager?.registerUndo(withTarget: textView) { target in
            target.text = previousText
            target.rehighlight()
            target.delegate?.textViewDidChange?(target)
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
            guard let codeTextView = textView as? CodeTextView, !codeTextView.isPerformingGhostMutation else { return }
            text = codeTextView.logicalText
            codeTextView.didEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection = textView.selectedRange
            (textView as? CodeTextView)?.selectionDidChange()
        }
    }
}
