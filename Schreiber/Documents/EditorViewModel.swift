import Foundation
import Observation
import SwiftGitX

@MainActor
@Observable
final class EditorViewModel {
    var text = """
    // Schreiber
    // Open a source file or start typing.

    """

    var documentURL: URL?
    var selection = NSRange(location: 0, length: 0)
    var language: EditorLanguage = .plainText
    var previewMode = false
    var project: ProjectFolder?
    var errorMessage: String?

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

    func openProject(_ url: URL) async {
        do {
            project = try ProjectFolder(url: url)
            if let first = project?.files.first { await open(first.url) }
        } catch { errorMessage = error.localizedDescription }
    }

    func stageCurrentFile() async {
        guard let project, let documentURL else { return }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            try repository.add(file: documentURL)
            self.project = try ProjectFolder(url: project.url)
        } catch { errorMessage = error.localizedDescription }
    }

    func commit(message: String) async {
        guard let project else { return }
        let accessGranted = project.url.startAccessingSecurityScopedResource()
        defer { if accessGranted { project.url.stopAccessingSecurityScopedResource() } }
        do {
            let repository = try Repository(at: project.url, createIfNotExists: false)
            try repository.commit(message: message)
            self.project = try ProjectFolder(url: project.url)
        } catch { errorMessage = error.localizedDescription }
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
            changeCount = (try? repository.status().count) ?? 0
        } else { changeCount = 0 }
    }

    private static func isEditable(_ url: URL) -> Bool {
        let extensions: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "js", "jsx", "mjs", "ts", "tsx",
            "py", "rb", "java", "kt", "go", "rs", "php", "json", "yaml", "yml", "toml",
            "xml", "html", "htm", "css", "scss", "sass", "md", "markdown", "sh", "bash",
            "zsh", "fish", "sql", "graphql", "txt", "log", "gitignore",
        ]
        let names: Set<String> = ["README", "LICENSE", "Makefile", "Dockerfile", "Gemfile"]
        return extensions.contains(url.pathExtension.lowercased()) || names.contains(url.lastPathComponent)
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
}
