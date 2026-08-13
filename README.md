# Schreibmaschine

A native, local-first source editor for iPhone and iPad (iOS 27+).

## Editor

- persistent app-owned `Documents/SmartStore/Projects` storage with a real starter
  project, local project/folder/file creation, autosave, and Files visibility
- explicit Files and iCloud Drive project/file import as secondary storage sources
- TextKit-backed editing with a canonical UTF-16 selection/caret state
- five intentionally dark editor palettes: Codex, Vercel, Cloudflare, Midnight,
  and Copilot (plus dark app chrome)
- syntax highlighting for Swift, JavaScript/TypeScript, Python, Ruby, Java, Go,
  PHP, JSON, YAML, HTML, CSS, Markdown, shell scripts, and plain text
- Markdown and HTML rich-text previews
- coding keyboard accessory, hardware-keyboard commands, word-first taps,
  double-tap completion, triple-tap structural closing, and long-press cursor control
- volume-button caret movement while this editor owns keyboard focus (the system still
  changes the device volume; iOS offers no public API to suppress that)

## On-device completion

Apple Foundation Models generates inline ghost completions entirely on device.
Deterministic lexical suggestions appear immediately; model requests debounce for
70 ms, cancel as soon as the buffer or selection changes, and are discarded unless
both the source snapshot and caret still match. Tab accepts a visible completion
before it inserts indentation. The accessory checkmark accepts and its regenerate
button (or a double tap) requests another longer completion. Tree-sitter extracts in-file symbols for the
completion context without uploading project contents.

Tree-sitter grammars currently provide structural context for Swift, Python,
Ruby, Java, Go, PHP, JSON, HTML, CSS, and Markdown. Other detected languages use
the same completion pipeline without a syntax tree until a grammar is added.

## Projects and Git

Open a local folder from the document picker to browse and edit its source files.
If it is a Git worktree, the toolbar shows the current branch and change count.
The source-control menu stages, commits, adds HTTPS/SSH remotes, fetches, and pushes
via SwiftGitX/libgit2; the app does not try to spawn a nonexistent `git` process on
iOS. Credentials are handled by the system/provider and are never stored in the app.

Package resolution and a full build require Xcode 27 because the app uses the
iOS 27 Foundation Models framework.
