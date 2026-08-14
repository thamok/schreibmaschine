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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, selection: $selection) }

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
        let liveText = textView.logicalText
        guard liveText != text, !context.coordinator.hasPendingText(liveText) else {
            if !context.coordinator.hasPendingSelection && textView.selectedRange != selection {
                textView.selectedRange = selection
            }
            return
        }
        context.coordinator.cancelPending()
        textView.prepareForExternalTextUpdate()
        textView.text = text
        textView.selectedRange = NSRange(location: min(selection.location, textView.text.utf16.count), length: min(selection.length, max(0, textView.text.utf16.count - selection.location)))
        textView.rehighlight()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var selection: NSRange
        private var pendingText: String?
        private var textWork: DispatchWorkItem?
        private var pendingSelection: NSRange?
        private var selectionWork: DispatchWorkItem?

        init(text: Binding<String>, selection: Binding<NSRange>) {
            _text = text
            _selection = selection
        }

        var hasPendingSelection: Bool { pendingSelection != nil }
        func hasPendingText(_ value: String) -> Bool { pendingText == value }

        func cancelPending() {
            textWork?.cancel()
            selectionWork?.cancel()
            pendingText = nil
            pendingSelection = nil
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let editor = textView as? CodeTextView, !editor.isPerformingGhostMutation else { return }
            let value = editor.logicalText
            pendingText = value
            textWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingText == value else { return }
                self.pendingText = nil
                self.text = value
            }
            textWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
            editor.didEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let value = textView.selectedRange
            pendingSelection = value
            selectionWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingSelection == value else { return }
                self.pendingSelection = nil
                self.selection = value
            }
            selectionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
            (textView as? CodeTextView)?.selectionDidChange()
        }
    }
}