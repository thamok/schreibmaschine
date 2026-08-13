# Schreibmaschine

A native, local-first source editor for iPhone and iPad (iOS 26+).

## Editor

- TextKit-backed editing with a canonical UTF-16 selection/caret state
- syntax highlighting for Swift, JavaScript/TypeScript, Python, Ruby, Java, Go,
  PHP, JSON, YAML, HTML, CSS, Markdown, shell scripts, and plain text
- Markdown and HTML rich-text previews
- coding keyboard accessory and hardware-keyboard commands

## On-device completion

Apple Foundation Models generates inline ghost completions entirely on device.
Requests debounce for 180 ms, cancel as soon as the buffer or selection changes,
and are discarded unless both the source snapshot and caret still match. Press
Option-Tab to accept a completion. Tree-sitter extracts in-file symbols for the
completion context without uploading project contents.

Tree-sitter grammars currently provide structural context for Swift, Python,
Ruby, Java, Go, PHP, JSON, HTML, CSS, and Markdown. Other detected languages use
the same completion pipeline without a syntax tree until a grammar is added.

## Projects and Git

Open a local folder from the document picker to browse and edit its source files.
If it is a Git worktree, the toolbar shows the current branch and change count.
The source-control menu can stage the current file and commit staged changes via
SwiftGitX/libgit2; the app does not try to spawn a nonexistent `git` process on
iOS.

Package resolution and a full build require Xcode 26 because the app uses the
iOS 26 Foundation Models framework.
