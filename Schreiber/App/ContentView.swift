import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var editor = EditorViewModel()
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CodeEditorView(text: $editor.text)
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                Divider()

                AIAssistantBar(editor: editor)
            }
            .navigationTitle(editor.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Open", systemImage: "folder") {
                        isImporting = true
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", systemImage: "square.and.arrow.down") {
                        Task {
                            await editor.save()
                        }
                    }
                    .disabled(editor.documentURL == nil)
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.plainText, .sourceCode, .json],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    return
                }

                Task {
                    await editor.open(url)
                }
            }
        }
    }
}
