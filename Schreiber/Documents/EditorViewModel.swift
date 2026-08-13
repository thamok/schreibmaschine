import Foundation
import Observation
import SwiftGitX

@MainActor
@Observable
final class EditorViewModel {
    var text = "" { didSet { scheduleAutosave() } }

    var documentURL: URL?
    var selection = NSRange(location: 0, length: 0)
    var language: EditorLanguage = .plainText
    var previewMode = false
    var project: ProjectFolder?
    var errorMessage: String?
    private(set) var localProjects: [ProjectFolder] = []
    private(set) var iCloudProjects: [ProjectFolder] = []
    private(set) var isICloudAvailable = false
    private(set) var gitSnapshot = GitSnapshot.empty
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init() {
        do {
            try FileManager.default.createDirectory(at: Self.projectsRoot, withIntermediateDirectories: true)
            refreshProjects()
            if localProjects.isEmpty {
                try createProject(named: "My Project")
            } else if let first = localProjects.first {
                project = first
                if let file = first.files.first { openSynchronously(file.url) }
            }
        } catch { errorMessage = error.localizedDescription }
        Task { await discoverICloudStorage() }
    }

    static var projectsRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "SmartStore/Projects", directoryHint: .isDirectory)
    }

    private var preferredRoot: URL {
        let wantsCloud = UserDefaults.standard.string(forKey: "storage.default") != StorageLocation.local.rawValue
        return wantsCloud ? (Self.iCloudProjectsRoot ?? Self.projectsRoot) : Self.projectsRoot
    }

    static var iCloudProjectsRoot: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appending(path: "Documents/Schreiber/Projects", directoryHint: .isDirectory)
    }

    func discoverICloudStorage() async {
        guard let root = Self.iCloudProjectsRoot else { isICloudAvailable = false; return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            isICloudAvailable = true
            refreshProjects()
        } catch { isICloudAvailable = false }
    }

    func refreshProjects() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        localProjects = urls.compactMap { try? ProjectFolder(url: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let root = Self.iCloudProjectsRoot {
            let cloudURLs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            iCloudProjects = cloudURLs.compactMap { try? ProjectFolder(url: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func createProject(named rawName: String, location: StorageLocation? = nil) throws {
        let name = Self.safeName(rawName, fallback: "Untitled Project")
        let root = location == .local ? Self.projectsRoot : (location == .iCloud ? (Self.iCloudProjectsRoot ?? Self.projectsRoot) : preferredRoot)
        let url = Self.uniqueURL(in: root, name: name, extension: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let readme = url.appending(path: "README.md")
        try "# \(name)\n\nStart writing.\n".write(to: readme, atomically: true, encoding: .utf8)
        refreshProjects()
        project = try ProjectFolder(url: url)
        openSynchronously(readme)
    }

    func importFile(_ source: URL) async {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            if project == nil { try createProject(named: "Imported") }
            guard let project else { return }
            let destination = Self.uniqueURL(in: project.url, name: source.deletingPathExtension().lastPathComponent, extension: source.pathExtension.isEmpty ? nil : source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            reloadProject()
            openSynchronously(destination)
        } catch { errorMessage = error.localizedDescription }
    }

    func importProject(_ source: URL) async {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            let destination = Self.uniqueURL(in: preferredRoot, name: source.lastPathComponent, extension: nil)
            try FileManager.default.copyItem(at: source, to: destination)
            refreshProjects()
            project = try ProjectFolder(url: destination)
            if let first = project?.files.first { openSynchronously(first.url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func createFolder(named rawName: String) throws {
        guard let project else { return }
        let name = Self.safeName(rawName, fallback: "Folder")
        try FileManager.default.createDirectory(at: Self.uniqueURL(in: project.url, name: name, extension: nil), withIntermediateDirectories: true)
        reloadProject()
    }

    func createFile(named rawName: String) throws {
        guard let project else { return }
        let name = Self.safeName(rawName, fallback: "untitled.txt")
        let components = name.split(separator: "/").map(String.init)
        let fileName = components.last ?? "untitled.txt"
        let folder = components.dropLast().reduce(project.url) { $0.appending(path: $1, directoryHint: .isDirectory) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        let url = Self.uniqueURL(in: folder, name: stem, extension: ext.isEmpty ? nil : ext)
        try "".write(to: url, atomically: true, encoding: .utf8)
        reloadProject()
        openSynchronously(url)
    }

    func apply(proposal: CodeEditProposal, range requestedRange: NSRange, document requestedDocument: URL?) {
        guard requestedDocument == documentURL else {
            errorMessage = "The file changed while the model was working. Run the edit again."
            return
        }
        let source = text as NSString
        let range = NSIntersectionRange(requestedRange, NSRange(location: 0, length: source.length))
        guard range == requestedRange else {
            errorMessage = "The proposed edit range is no longer valid."
            return
        }
        text = source.replacingCharacters(in: range, with: proposal.replacement)
        selection = NSRange(location: range.location, length: (proposal.replacement as NSString).length)
        if let documentURL { try? text.write(to: documentURL, atomically: true, encoding: .utf8) }
    }

    func goToLine(_ requestedLine: Int) {
        let target = max(1, requestedLine)
        let source = text as NSString
        var location = 0
        var line = 1
        while line < target, location < source.length {
            let search = source.range(of: "\n", range: NSRange(location: location, length: source.length - location))
            guard search.location != NSNotFound else { location = source.length; break }
            location = NSMaxRange(search)
            line += 1
        }
        selection = NSRange(location: location, length: 0)
    }

    var displayName: String {
        documentURL?.lastPathComponent ?? "Schreiber"
    }

    func open(_ url: URL) async {
        let scopeURL = project?.url ?? url
        let accessGranted = scopeURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                scopeURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            text = try String(contentsOf: url, encoding: .utf8)
            documentURL = url
            language = EditorLanguage(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSynchronously(_ url: URL) {
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            documentURL = url
            selection = NSRange(location: 0, length: 0)
            language = EditorLanguage(url: url)
            previewMode = false
        } catch { errorMessage = error.localizedDescription }
    }

    func save() async {
        guard let documentURL else {
            return
        }

        let scopeURL = project?.url ?? documentURL
        let accessGranted = scopeURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                scopeURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try text.write(to: documentURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard let documentURL else { return }
        let snapshot = text
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self?.documentURL == documentURL, self?.text == snapshot else { return }
            do { try snapshot.write(to: documentURL, atomically: true, encoding: .utf8) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func openProject(_ url: URL) async {
        do {
            project = try ProjectFolder(url: url)
            if let first = project?.files.first { await open(first.url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectProject(_ project: ProjectFolder) {
        self.project = project
        if let first = project.files.first { openSynchronously(first.url) }
    }

    private func reloadProject() {
        guard let project else { return }
        self.project = try? ProjectFolder(url: project.url)
        refreshProjects()
    }

    private static func safeName(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/:"))
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func uniqueURL(in folder: URL, name: String, extension fileExtension: String?) -> URL {
        let suffix = fileExtension.map { ".\($0)" } ?? ""
        var candidate = folder.appending(path: name + suffix)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(name) \(index)\(suffix)")
            index += 1
        }
        return candidate
    }

    func stageCurrentFile() async {
        guard let project, let documentURL else { return }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            try repository.add(file: documentURL)
            self.project = try ProjectFolder(url: project.url)
            loadGitSnapshot()
        } catch { errorMessage = error.localizedDescription }
    }

    func initializeGit() async {
        guard let project else { return }
        do {
            _ = try Repository(at: project.url, createIfNotExists: true)
            self.project = try ProjectFolder(url: project.url)
            refreshProjects()
            loadGitSnapshot()
        } catch { errorMessage = error.localizedDescription }
    }

    func loadGitSnapshot() {
        guard let project, project.isGitRepository else { gitSnapshot = .empty; return }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            let status = try repository.status()
            let trackedPatches = try repository.diff(to: [.workingTree, .index]).patches
            var patches: [(patch: Patch, path: String?)] = trackedPatches.map { ($0, nil) }
            let known = Set(trackedPatches.map { $0.delta.newFile.path })
            for entry in status {
                guard let delta = entry.workingTree ?? entry.index, !known.contains(delta.newFile.path),
                      let patch = try repository.patch(from: delta) else { continue }
                patches.append((patch, delta.newFile.path))
            }
            gitSnapshot = GitSnapshot(patches: patches)
        } catch { gitSnapshot = .empty; errorMessage = error.localizedDescription }
    }

    func commit(message: String) async {
        guard let project else { return }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            let configuredName = UserDefaults.standard.string(forKey: "git.user.name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuredEmail = UserDefaults.standard.string(forKey: "git.user.email")?.trimmingCharacters(in: .whitespacesAndNewlines)
            try repository.config.set("user.name", to: configuredName?.isEmpty == false ? configuredName! : "Schreiber User")
            try repository.config.set("user.email", to: configuredEmail?.isEmpty == false ? configuredEmail! : "schreiber@localhost")
            try repository.commit(message: message)
            self.project = try? ProjectFolder(url: project.url)
            loadGitSnapshot()
        } catch { errorMessage = error.localizedDescription }
    }

    func fetch() async {
        guard let project else { return }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            try await repository.fetch()
            self.project = try ProjectFolder(url: project.url)
        } catch { errorMessage = error.localizedDescription }
    }

    func push() async {
        guard let project else { return }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            try await repository.push()
            self.project = try ProjectFolder(url: project.url)
        } catch { errorMessage = error.localizedDescription }
    }

    func addRemote(name: String, url: String) async {
        guard let project, let remoteURL = URL(string: url), !name.isEmpty else {
            errorMessage = "Enter a valid remote name and URL."
            return
        }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            try repository.remote.add(named: name, at: remoteURL)
            self.project = try ProjectFolder(url: project.url)
        } catch { errorMessage = error.localizedDescription }
    }
}


enum StorageLocation: String, CaseIterable, Identifiable {
    case iCloud
    case local

    var id: String { rawValue }
    var title: String { self == .iCloud ? "iCloud Drive" : "On My iPhone" }
}

struct GitSnapshot: Equatable {
    struct FileChange: Identifiable, Equatable {
        struct Line: Identifiable, Equatable {
            let id = UUID()
            let number: Int
            let marker: String
            let content: String
        }

        let path: String
        let additions: Int
        let deletions: Int
        let lines: [Line]
        var id: String { path }
    }

    let files: [FileChange]
    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    static let empty = GitSnapshot(files: [])

    init(files: [FileChange]) { self.files = files }

    init(patches: [(patch: Patch, path: String?)]) {
        files = patches.map { item in
            let patch = item.patch
            let lines = patch.hunks.flatMap(\.lines).map { line in
                FileChange.Line(number: line.lineNumber, marker: line.type.rawValue, content: line.content)
            }
            return FileChange(
                path: item.path ?? patch.delta.newFile.path,
                additions: lines.filter { $0.marker == "+" || $0.marker == ">" }.count,
                deletions: lines.filter { $0.marker == "-" || $0.marker == "<" }.count,
                lines: lines
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

struct ProjectFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct ProjectFolder {
    let url: URL
    let files: [ProjectFile]
    let branch: String?
    let changeCount: Int
    let remotes: [String]
    let isGitRepository: Bool
    var name: String { url.lastPathComponent }

    init(url: URL) throws {
        self.url = url
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        files = (enumerator?.compactMap { value -> ProjectFile? in
            guard let file = value as? URL,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  ProjectFolder.isEditable(file) else { return nil }
            return ProjectFile(url: file)
        } ?? []).sorted { $0.url.path < $1.url.path }
        let head = url.appending(path: ".git/HEAD")
        if let value = try? String(contentsOf: head, encoding: .utf8), value.hasPrefix("ref: refs/heads/") {
            branch = value.replacingOccurrences(of: "ref: refs/heads/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else { branch = nil }
        if let repository = try? Repository(at: url, createIfNotExists: false) {
            isGitRepository = true
            changeCount = (try? repository.status().count) ?? 0
            remotes = (try? repository.remote.list().map(\.name).sorted()) ?? []
        } else { isGitRepository = false; changeCount = 0; remotes = [] }
    }

    private static func isEditable(_ url: URL) -> Bool {
        let extensions: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "js", "jsx", "mjs", "ts", "tsx",
            "py", "rb", "java", "kt", "go", "rs", "php", "json", "yaml", "yml", "toml",
            "xml", "html", "htm", "css", "scss", "sass", "md", "markdown", "sh", "bash",
            "zsh", "fish", "sql", "graphql", "txt", "rtf", "log", "gitignore",
        ]
        let names: Set<String> = ["README", "LICENSE", "Makefile", "Dockerfile", "Gemfile"]
        return url.pathExtension.isEmpty || extensions.contains(url.pathExtension.lowercased()) || names.contains(url.lastPathComponent)
    }
}

enum EditorLanguage: String, CaseIterable, Sendable {
    case swift, javascript, typescript, python, ruby, java, go, php
    case json, yaml, html, css, markdown, shell, plainText

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "swift": self = .swift
        case "js", "jsx", "mjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "py": self = .python
        case "rb": self = .ruby
        case "java": self = .java
        case "go": self = .go
        case "php": self = .php
        case "json": self = .json
        case "yaml", "yml": self = .yaml
        case "html", "htm": self = .html
        case "css", "scss": self = .css
        case "md", "markdown": self = .markdown
        case "sh", "zsh", "bash": self = .shell
        default: self = .plainText
        }
    }

    var canPreview: Bool { self == .markdown || self == .html }
    var isProse: Bool { self == .plainText || self == .markdown }
}
