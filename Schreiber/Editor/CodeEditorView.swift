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

        if textView.logicalText != text {
            textView.prepareForExternalTextUpdate()
            textView.text = text
            textView.selectedRange = clamped(selection, to: textView.text.utf16.count)
            textView.rehighlight()
            return
        }

        let target = clamped(selection, to: textView.text.utf16.count)
        if textView.selectedRange != target {
            textView.selectedRange = target
        }
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), max(0, length - location))
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var selection: NSRange

        init(text: Binding<String>, selection: Binding<NSRange>) {
            _text = text
            _selection = selection
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let editor = textView as? CodeTextView else { return }
            text = editor.logicalText
            selection = editor.selectedRange
            editor.didEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection = textView.selectedRange
            (textView as? CodeTextView)?.selectionDidChange()
        }
    }
}
