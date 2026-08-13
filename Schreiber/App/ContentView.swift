import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var editor = EditorViewModel()
    @State private var isImporting = false
    @State private var isImportingProject = false
    @State private var isCommitting = false
    @State private var commitMessage = ""

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if let project = editor.project {
                    List(project.files, selection: Binding(get: { editor.documentURL.map { ProjectFile(url: $0) } }, set: { file in
                        guard let file else { return }
                        Task { await editor.open(file.url) }
                    })) { file in
                        Label(file.name, systemImage: "doc.text")
                            .tag(file)
                    }
                    .frame(minWidth: 190, idealWidth: 240, maxWidth: 280)
                }

                VStack(spacing: 0) {
                Group {
                    if editor.previewMode, editor.language.canPreview {
                        RichPreview(text: editor.text, language: editor.language)
                    } else {
                        CodeEditorView(text: $editor.text, selection: $editor.selection, language: editor.language)
                    }
                }
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                Divider()

                AIAssistantBar(editor: editor)
                }
            }
            .navigationTitle(editor.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Open", systemImage: "folder") {
                        Button("File") { isImporting = true }
                        Button("Project Folder") { isImportingProject = true }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let project = editor.project, let branch = project.branch {
                        Menu("\(branch) · \(project.changeCount)", systemImage: "arrow.triangle.branch") {
                            Button("Stage Current File") { Task { await editor.stageCurrentFile() } }
                                .disabled(editor.documentURL == nil)
                            Button("Commit Staged Changes") { isCommitting = true }
                        }
                    }
                    if editor.language.canPreview {
                        Button(editor.previewMode ? "Edit" : "Preview", systemImage: editor.previewMode ? "pencil" : "doc.richtext") {
                            editor.previewMode.toggle()
                        }
                    }
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
            .fileImporter(isPresented: $isImportingProject, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await editor.openProject(url) }
            }
            .alert("Editor Error", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
                Button("OK") { editor.errorMessage = nil }
            } message: { Text(editor.errorMessage ?? "Unknown error") }
            .alert("Commit Staged Changes", isPresented: $isCommitting) {
                TextField("Commit message", text: $commitMessage)
                Button("Cancel", role: .cancel) {}
                Button("Commit") {
                    let message = commitMessage
                    commitMessage = ""
                    Task { await editor.commit(message: message) }
                }.disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct RichPreview: View {
    let text: String
    let language: EditorLanguage

    var body: some View {
        ScrollView {
            if language == .markdown {
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                HTMLPreview(html: text)
            }
        }
    }
}

private struct HTMLPreview: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else { view.text = html; return }
        view.attributedText = attributed
    }
}
