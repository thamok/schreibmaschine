# Schreibmaschine

A native, local-first source editor for iPhone and iPad (iOS 27+).

## Editor

- app-owned local projects with Files visibility, plus Files/iCloud import
- TextKit-backed editing with UTF-16 caret and selection state
- dark editor themes, configurable monospace fonts, line wrapping, and line numbers
- lightweight syntax highlighting for common source, markup, and data formats
- Markdown and HTML preview
- find/replace, hardware-keyboard commands, virtual modifiers, and a compact symbols keyboard
- local Git operations through SwiftGitX/libgit2

## Ghost completion

Ghost completion intentionally has a small pipeline:

1. A document-local word completion appears immediately when the current token has a strong match elsewhere in the nearby buffer.
2. After a short idle debounce, Apple Foundation Models gets a small prefix/suffix window around the caret.
3. Every model request uses a fresh `LanguageModelSession`, so rejected completions never leak into later requests.
4. A completion is rendered as an overlay at the caret. It is never inserted into `NSTextStorage` until accepted.
5. Typing characters that match the visible ghost consumes those characters from the suggestion instead of throwing it away and regenerating.
6. Tab accepts a visible suggestion; otherwise Tab inserts indentation.

The completion path does not parse the project or build a symbol index. Tree-sitter is deliberately not a dependency. The on-device model is treated as a best-effort semantic fallback, not as the editor's source of truth.

## AI edits

Selection/caret-aware edits use Apple Foundation Models entirely on device. Edit requests also use fresh sessions and bounded local context. The editor shows the proposed replacement before applying it.

## Projects and Git

Open a local folder from the document picker to browse and edit its source files. If it is a Git worktree, the editor can show changes, stage the current file, commit, fetch, add remotes, and push through SwiftGitX/libgit2. The app does not spawn a `git` process on iOS.

Package resolution and a full build require Xcode 27 because the app uses the iOS 27 Foundation Models framework.
