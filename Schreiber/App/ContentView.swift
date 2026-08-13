import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var editor = EditorViewModel()
    @State private var isImporting = false
    @State private var isImportingProject = false
    @State private var isCommitting = false
    @State private var commitMessage = ""
    @State private var isAddingRemote = false
    @State private var remoteName = "origin"
    @State private var remoteURL = ""
    @State private var isCreatingProject = false
    @State private var isCreatingFolder = false
    @State private var isCreatingFile = false
    @State private var isGoingToLine = false
    @State private var requestedLine = ""
    @State private var newItemName = ""
    @State private var presentedSheet: SheetDestination?
    @State private var aiProposal: CodeEditProposal?
    @State private var aiProposalRange = NSRange(location: 0, length: 0)
    @State private var aiProposalDocument: URL?
    @State private var toolExpansion: EditorToolExpansion?
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var accessoryAIText = ""
    @State private var virtualModifiers: EditorModifierState = []
    @State private var findIndex = 0
    @AppStorage("editor.theme") private var editorTheme = EditorTheme.codex.rawValue
    @AppStorage("editor.haptics") private var hapticsEnabled = true
    @AppStorage("editor.typeface") private var editorTypeface = EditorTypeface.systemMono.rawValue
    @AppStorage("editor.fontSize") private var editorFontSize = 13.0
    @AppStorage("editor.wrapLines") private var wrapsLines = true
    @AppStorage("storage.default") private var defaultStorage = StorageLocation.iCloud.rawValue
    @AppStorage("git.user.name") private var gitUserName = "Schreiber User"
    @AppStorage("git.user.email") private var gitUserEmail = "schreiber@localhost"

    private var theme: EditorTheme { EditorTheme(rawValue: editorTheme) ?? .codex }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if horizontalSizeClass == .regular, let project = editor.project {
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
                        RichPreview(text: editor.text, language: editor.language, baseURL: editor.documentURL?.deletingLastPathComponent())
                    } else {
                        CodeEditorView(text: $editor.text, selection: $editor.selection, language: editor.language, theme: theme, hapticsEnabled: hapticsEnabled, typeface: EditorTypeface(rawValue: editorTypeface) ?? .systemMono, fontSize: editorFontSize, wrapsLines: wrapsLines) { instruction in
                            requestAIEdit(instruction)
                        }
                    }
                }

                }
            }
            .overlay(alignment: .bottom) {
                if editor.previewMode {
                    Button("Back to Editor", systemImage: "pencil") { editor.previewMode = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.bottom, 20)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isGoingToLine {
                    HStack(spacing: 8) {
                        Image(systemName: "number")
                        TextField("Line", text: $requestedLine)
                            .keyboardType(.numberPad)
                            .frame(width: 70)
                        Button("Go") {
                            if let line = Int(requestedLine) { editor.goToLine(line) }
                            isGoingToLine = false
                        }
                        Button { isGoingToLine = false } label: { Image(systemName: "xmark") }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !editor.previewMode {
                    EditorKeyboardTools(
                        expansion: $toolExpansion,
                        findText: $findText,
                        replaceText: $replaceText,
                        aiText: $accessoryAIText,
                        modifiers: $virtualModifiers,
                        findIndex: $findIndex,
                        source: editor.text,
                        runAI: requestAIEdit
                    )
                }
            }
            .navigationTitle(editor.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(editor.previewMode ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !editor.previewMode { Menu("Projects", systemImage: "folder") {
                        if !editor.iCloudProjects.isEmpty {
                            Section("iCloud Drive · Schreiber") {
                                ForEach(editor.iCloudProjects, id: \.url) { project in
                                    Button(project.name) { editor.selectProject(project) }
                                }
                            }
                        }
                        Section("On My iPhone · Schreiber") {
                            ForEach(editor.localProjects, id: \.url) { project in
                                Button(project.name) { editor.selectProject(project) }
                            }
                        }
                        if let project = editor.project, !project.files.isEmpty {
                            Section(project.name) {
                                ForEach(project.files) { file in
                                    Button(file.url.path.replacingOccurrences(of: project.url.path + "/", with: "")) { Task { await editor.open(file.url) } }
                                }
                            }
                        }
                        Section {
                            Button("New Project…", systemImage: "folder.badge.plus") { newItemName = ""; isCreatingProject = true }
                            Button("New Folder…", systemImage: "folder.badge.plus") { newItemName = ""; isCreatingFolder = true }
                                .disabled(editor.project == nil)
                            Button("New File…", systemImage: "doc.badge.plus") { newItemName = ""; isCreatingFile = true }
                                .disabled(editor.project == nil)
                        }
                        Section("Files & iCloud Drive") {
                            Button("Open File…") { isImporting = true }
                            Button("Open Project Folder…") { isImportingProject = true }
                        }
                    } }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !editor.previewMode {
                    Button("Preview", systemImage: "doc.richtext") { editor.previewMode = true }.disabled(!editor.language.canPreview)
                    Menu("Editor", systemImage: "ellipsis.circle") {
                        Button("Save", systemImage: "square.and.arrow.down") { Task { await editor.save() } }
                            .disabled(editor.documentURL == nil)
                        Button("Go to Line…", systemImage: "number") { requestedLine = ""; isGoingToLine = true }
                        Menu("Theme", systemImage: "paintpalette") {
                            ForEach(EditorTheme.allCases) { candidate in
                                Button(candidate.title) { editorTheme = candidate.rawValue }
                            }
                        }
                        if let project = editor.project {
                            Section("Git") {
                                if let branch = project.branch { Text("\(branch) · \(project.changeCount) changes") }
                                if project.isGitRepository {
                                    Button("Changes…", systemImage: "arrow.triangle.branch") { editor.loadGitSnapshot(); presentedSheet = .git }
                                    Button("Stage Current File") { Task { await editor.stageCurrentFile() } }
                                    Button("Commit Staged Changes") { isCommitting = true }
                                } else {
                                    Button("Initialize Local Git", systemImage: "arrow.triangle.branch") { Task { await editor.initializeGit() } }
                                }
                                Button("Fetch") { Task { await editor.fetch() } }.disabled(project.remotes.isEmpty)
                                Button("Push") { Task { await editor.push() } }.disabled(project.remotes.isEmpty)
                                Button("Add Remote…") { isAddingRemote = true }
                            }
                        }
                        Button("Settings…", systemImage: "gearshape") { presentedSheet = .settings }
                    }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.plainText, .sourceCode, .json, .rtf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    return
                }

                Task {
                    await editor.importFile(url)
                }
            }
            .fileImporter(isPresented: $isImportingProject, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await editor.importProject(url) }
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
            .alert("Add Git Remote", isPresented: $isAddingRemote) {
                TextField("Name", text: $remoteName)
                TextField("HTTPS or SSH URL", text: $remoteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let name = remoteName
                    let url = remoteURL
                    remoteURL = ""
                    Task { await editor.addRemote(name: name, url: url) }
                }
            } message: {
                Text("Credentials remain in your system credential provider; Schreiber does not store them.")
            }
            .alert("New Project", isPresented: $isCreatingProject) {
                TextField("Project name", text: $newItemName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { do { try editor.createProject(named: newItemName) } catch { editor.errorMessage = error.localizedDescription } }
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Folder name", text: $newItemName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { do { try editor.createFolder(named: newItemName) } catch { editor.errorMessage = error.localizedDescription } }
            }
            .alert("New File", isPresented: $isCreatingFile) {
                TextField("File name, e.g. Sources/App.swift", text: $newItemName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") { do { try editor.createFile(named: newItemName) } catch { editor.errorMessage = error.localizedDescription } }
            }
            .alert("Proposed edit", isPresented: Binding(get: { aiProposal != nil }, set: { if !$0 { aiProposal = nil } })) {
                Button("Reject", role: .cancel) { aiProposal = nil }
                Button("Apply") {
                    if let proposal = aiProposal { editor.apply(proposal: proposal, range: aiProposalRange, document: aiProposalDocument) }
                    aiProposal = nil
                }
            } message: {
                Text(aiProposal.map { "\($0.summary)\n\n\($0.replacement)" } ?? "")
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .settings:
                    SettingsSheet(hapticsEnabled: $hapticsEnabled, typeface: $editorTypeface, fontSize: $editorFontSize, wrapsLines: $wrapsLines, defaultStorage: $defaultStorage, gitUserName: $gitUserName, gitUserEmail: $gitUserEmail, iCloudAvailable: editor.isICloudAvailable)
                        .presentationDetents([.medium])
                case .git:
                    GitChangesSheet(snapshot: editor.gitSnapshot, projectName: editor.project?.name ?? "Project")
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    private func requestAIEdit(_ instruction: String) {
        let range = editor.selection
        let document = editor.documentURL
        let source = editor.text
        Task {
            do {
                aiProposal = try await FoundationModelService.shared.proposeEdit(file: source, instruction: instruction, selection: range)
                aiProposalRange = range
                aiProposalDocument = document
            } catch { editor.errorMessage = error.localizedDescription }
        }
    }
}

private enum EditorToolExpansion { case find, replace, ai }

private struct EditorKeyboardTools: View {
    @Binding var expansion: EditorToolExpansion?
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var aiText: String
    @Binding var modifiers: EditorModifierState
    @Binding var findIndex: Int
    let source: String
    let runAI: (String) -> Void

    private var matches: Int {
        guard !findText.isEmpty else { return 0 }
        let text = source as NSString; var count = 0; var location = 0
        while location < text.length {
            let range = text.range(of: findText, options: [.caseInsensitive], range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound else { break }
            count += 1; location = max(NSMaxRange(range), location + 1)
        }
        return count
    }

    var body: some View {
        VStack(spacing: 8) {
            if let expansion {
                VStack(spacing: 6) {
                    if expansion == .ai {
                        HStack { TextField("Ask the on-device model…", text: $aiText).onSubmit(submitAI); Button(action: submitAI) { Image(systemName: "arrow.up.circle.fill") } }
                            .padding(.horizontal, 12).frame(height: 42).glassEffect(.regular.interactive(), in: .capsule)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                            TextField("Find", text: $findText)
                                .submitLabel(.search)
                                .onSubmit { next() }
                                .onChange(of: findText) { _, value in findIndex = 0; send(.find(value, 0)) }
                            Text(matches == 0 ? "0/0" : "\(min(findIndex + 1, matches))/\(matches)").font(.caption).foregroundStyle(.secondary)
                            Button { previous() } label: { Image(systemName: "chevron.up") }.disabled(findIndex <= 0 || matches == 0)
                            Button { next() } label: { Image(systemName: "chevron.down") }.disabled(findIndex + 1 >= matches || matches == 0)
                            Button { closeFind() } label: { Image(systemName: "xmark") }
                        }
                        .padding(.horizontal, 12).frame(height: 42).glassEffect(.regular.interactive(), in: .capsule)
                        if expansion == .replace {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                TextField("Replace", text: $replaceText).onSubmit { replace(all: false) }
                                Button("One") { replace(all: false) }.buttonStyle(.glass)
                                Button("All") { replace(all: true) }.buttonStyle(.glass)
                            }
                            .padding(.horizontal, 12).frame(height: 42).glassEffect(.regular.interactive(), in: .capsule)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 10) { HStack(spacing: 10) {
                    tool("magnifyingglass", "Find") {
                        expansion = expansion == nil ? .find : (expansion == .find ? .replace : nil)
                    }
                    tool("arrow.right.to.line.compact", "Tab") { send(.command(.acceptCompletion)) }
                    modifier("command", "Command", .command)
                    modifier("option", "Option", .option)
                    modifier("shift", "Shift", .shift)
                    tool("sparkles", "AI Edit") { expansion = expansion == .ai ? nil : .ai }
                    tool("document.on.document", "Copy") { send(.command(.copy)) }
                    tool("clipboard", "Paste") { send(.command(.paste)) }
                    tool("keyboard", "Symbols Keyboard") { send(.command(.toggleSymbolsKeyboard)) }
                } }
                .padding(.horizontal, 8)
            }
            .frame(height: 44)
        }
        .padding(.vertical, 6)
    }

    private func tool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 16, height: 16).padding(10) }
            .accessibilityLabel(label)
            .buttonStyle(.glass)
    }

    private func modifier(_ symbol: String, _ label: String, _ value: EditorModifierState) -> some View {
        Group {
            if modifiers.contains(value) {
                modifierButton(symbol, label, value).buttonStyle(.glassProminent)
            } else {
                modifierButton(symbol, label, value).buttonStyle(.glass)
            }
        }
    }

    private func modifierButton(_ symbol: String, _ label: String, _ value: EditorModifierState) -> some View {
        Button {
            if modifiers.contains(value) { modifiers.remove(value) } else { modifiers.insert(value) }
            send(.modifier(value))
        } label: { Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 16, height: 16).padding(10) }
            .accessibilityLabel(label)
    }

    private func submitAI() {
        let request = aiText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        runAI(request); aiText = ""; expansion = nil
    }

    private func send(_ action: EditorToolAction) { NotificationCenter.default.post(name: .editorToolAction, object: action) }
    private func previous() { guard findIndex > 0 else { return }; findIndex -= 1; send(.find(findText, findIndex)) }
    private func next() { guard findIndex + 1 < matches else { return }; findIndex += 1; send(.find(findText, findIndex)) }
    private func closeFind() { findText = ""; replaceText = ""; findIndex = 0; expansion = nil; send(.find("", 0)) }
    private func replace(all: Bool) { guard !findText.isEmpty else { return }; send(.replace(findText, replaceText, findIndex, all)) }
}

private enum SheetDestination: String, Identifiable {
    case settings, git
    var id: String { rawValue }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var hapticsEnabled: Bool
    @Binding var typeface: String
    @Binding var fontSize: Double
    @Binding var wrapsLines: Bool
    @Binding var defaultStorage: String
    @Binding var gitUserName: String
    @Binding var gitUserEmail: String
    let iCloudAvailable: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Editor") {
                    Toggle("Cursor controller vibration", isOn: $hapticsEnabled)
                    Picker("Typeface", selection: $typeface) {
                        ForEach(EditorTypeface.allCases) { face in Text(face.title).tag(face.rawValue) }
                    }
                    VStack(alignment: .leading) {
                        Text("Font size · \(Int(fontSize)) pt")
                        Slider(value: $fontSize, in: 9...24, step: 1)
                    }
                    Toggle("Wrap long lines", isOn: $wrapsLines)
                }
                Section("New projects") {
                    Picker("Default storage", selection: $defaultStorage) {
                        Text("iCloud Drive").tag(StorageLocation.iCloud.rawValue)
                        Text("On My iPhone").tag(StorageLocation.local.rawValue)
                    }
                    if !iCloudAvailable { Text("iCloud Drive is currently unavailable; new projects fall back to this iPhone.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Git identity") {
                    TextField("Name", text: $gitUserName)
                    TextField("Email", text: $gitUserEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct RichPreview: View {
    let text: String
    let language: EditorLanguage
    let baseURL: URL?

    var body: some View {
        if language == .markdown {
            ScrollView {
                MarkdownPreview(markdown: text)
            }
        } else {
            HTMLPreview(html: text, baseURL: baseURL)
        }
    }
}

private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { Text(String(line.dropFirst(4))).font(.title3.bold()) }
                else if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(.title2.bold()) }
                else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.largeTitle.bold()) }
                else if line.hasPrefix("- ") { Label { inlineMarkdown(String(line.dropFirst(2))) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) } }
                else if line.hasPrefix("> ") { inlineMarkdown(String(line.dropFirst(2))).foregroundStyle(.secondary).padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 3) } }
                else if line.isEmpty { Color.clear.frame(height: 4) }
                else { inlineMarkdown(line) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func inlineMarkdown(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

private struct HTMLPreview: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = true
        view.backgroundColor = UIColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        view.scrollView.backgroundColor = view.backgroundColor
        view.overrideUserInterfaceStyle = .dark
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html || context.coordinator.loadedBaseURL != baseURL else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.loadedBaseURL = baseURL
        let previewHead = "<meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{min-height:100%;background:#0e1014;color:#f2f4f8}body{font:-apple-system-body;margin:20px;overflow-wrap:anywhere}img,video{max-width:100%;height:auto}</style>"
        let page: String
        if let headRange = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            page = html.replacingCharacters(in: headRange, with: String(html[headRange]) + previewHead)
        } else if let htmlRange = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            page = html.replacingCharacters(in: htmlRange, with: String(html[htmlRange]) + "<head>\(previewHead)</head>")
        } else {
            page = "<!doctype html><html><head>\(previewHead)</head><body>\(html)</body></html>"
        }
        view.loadHTMLString(page, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedHTML: String?
        var loadedBaseURL: URL?
    }
}
