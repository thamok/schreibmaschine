import AVFoundation
import MediaPlayer
import UIKit
import WebKit

final class CodeTextView: UITextView {
    private static let ghostAttribute = NSAttributedString.Key("SchreiberGhostCompletion")
    var language: EditorLanguage = .plainText {
        didSet { if oldValue != language { rehighlight(); updateKeyboardTraits() } }
    }
    var theme: EditorTheme = .codex {
        didSet { if oldValue != theme { applyTheme(); rehighlight() } }
    }
    var hapticsEnabled = true
    var typeface: EditorTypeface = .systemMono { didSet { if oldValue != typeface { applyEditorTypography() } } }
    var editorFontSize: Double = 14 { didSet { if oldValue != editorFontSize { applyEditorTypography() } } }
    var wrapsLines = true { didSet { if oldValue != wrapsLines { applyWrapping() } } }
    var requestAIEdit: ((String) -> Void)?
    private var showsSymbolsKeyboard = false
    private var completionTask: Task<Void, Never>?
    private var completionRange = NSRange(location: 0, length: 0)
    private var completionAlternatives: [String] = []
    private var completionIndex = 0
    private var alternativeSeed = 0
    private var highlightTask: Task<Void, Never>?
    private var volumeObservation: NSKeyValueObservation?
    private var lastCursorControllerPoint: CGPoint?
    private var cursorControllerOrigin: CGPoint?
    private var tapCount = 0
    private var lastTapTime: TimeInterval = 0
    private var tapResolutionWorkItem: DispatchWorkItem?
    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
    private var restoringVolume = false
    private var stableVolume: Float = AVAudioSession.sharedInstance().outputVolume
    private var ghostText = ""
    private var findMatches: [NSRange] = []
    private var currentFindIndex = 0
    private var ghostDisplayRange: NSRange?
    private var isMutatingGhost = false
    private var modifierState: EditorModifierState = [] {
        didSet {
            codingAccessoryView.setModifierState(modifierState)
        }
    }

    private lazy var codingAccessoryView = CodingAccessoryView { [weak self] action in
        self?.handleAccessoryAction(action)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var inputAccessoryView: UIView? {
        get { nil }
        set {}
    }

    override var inputView: UIView? {
        get {
            guard showsSymbolsKeyboard else { return nil }
            return SymbolsKeyboardView { [weak self] action in self?.handleAccessoryAction(action) }
        }
        set {}
    }

    override func insertText(_ text: String) {
        discardGhostCompletion()
        guard !modifierState.isEmpty, text.count == 1 else { super.insertText(text); return }
        let active = modifierState
        if active.contains(.command) {
            performCommandEquivalent(text)
            return
        }
        if active.contains(.control), let scalar = text.lowercased().unicodeScalars.first, scalar.value >= 97, scalar.value <= 122 {
            super.insertText(String(UnicodeScalar(scalar.value - 96)!))
            return
        }
        super.insertText(active.contains(.shift) ? text.uppercased() : text)
    }

    override func deleteBackward() {
        discardGhostCompletion()
        super.deleteBackward()
    }

    var logicalText: String {
        guard let range = ghostDisplayRange, NSMaxRange(range) <= textStorage.length else { return text ?? "" }
        return (textStorage.string as NSString).replacingCharacters(in: range, with: "")
    }

    var isPerformingGhostMutation: Bool { isMutatingGhost }

    func prepareForExternalTextUpdate() {
        clearCompletion()
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Accept Completion or Indent", action: #selector(insertTab), input: "\t"),
            UIKeyCommand(title: "Outdent", action: #selector(outdent), input: "\t", modifierFlags: [.shift]),
            UIKeyCommand(
                title: "Dismiss Keyboard",
                action: #selector(escape),
                input: UIKeyCommand.inputEscape
            ),
        ]
    }

    private func configure() {
        applyTheme()

        applyEditorTypography()
        applyWrapping()
        updateKeyboardTraits()

        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        textContainerInset = UIEdgeInsets(
            top: 16,
            left: 48,
            bottom: 32,
            right: 12
        )
        volumeView.alpha = 0.001
        addSubview(volumeView)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleEditorTap(_:)))
        singleTap.cancelsTouchesInView = false
        addGestureRecognizer(singleTap)
        let cursorController = UILongPressGestureRecognizer(target: self, action: #selector(handleCursorController(_:)))
        cursorController.minimumPressDuration = 0.35
        cursorController.cancelsTouchesInView = false
        addGestureRecognizer(cursorController)

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(true)
        volumeObservation = audioSession.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isFirstResponder else { self.stableVolume = new; return }
                guard !self.restoringVolume else { return }
                self.moveCaretVertically(by: new > old ? -1 : 1)
                self.restoreVolume()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(handleToolNotification(_:)), name: .editorToolAction, object: nil)
    }

    @objc private func handleToolNotification(_ notification: Notification) {
        guard window != nil, let action = notification.object as? EditorToolAction else { return }
        switch action {
        case .command(let command): perform(command)
        case .modifier(let modifier): handleAccessoryAction(.modifier(modifier))
        case .find(let query, let index): showFind(query, index: index)
        case .replace(let query, let replacement, let index, let all): replaceFind(query, replacement: replacement, index: index, all: all)
        }
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let source = textStorage.string as NSString
        var location = 0
        var line = 1
        while location <= source.length {
            let charRange = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: min(glyphRange.location, max(0, layoutManager.numberOfGlyphs - 1)), effectiveRange: nil)
            let drawRect = CGRect(x: 4, y: textContainerInset.top + fragment.minY, width: 34, height: fragment.height)
            if drawRect.intersects(rect) {
                ("\(line)" as NSString).draw(in: drawRect, withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: theme.palette.comment.withAlphaComponent(0.7)])
            }
            guard NSMaxRange(charRange) > location, NSMaxRange(charRange) < source.length else { break }
            location = NSMaxRange(charRange); line += 1
        }
    }

    private func applyEditorTypography() { font = typeface.font(size: editorFontSize); rehighlight(); setNeedsDisplay() }
    private func applyWrapping() {
        textContainer.widthTracksTextView = wrapsLines
        textContainer.lineBreakMode = wrapsLines ? .byWordWrapping : .byClipping
        textContainer.size = CGSize(width: wrapsLines ? bounds.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        alwaysBounceHorizontal = !wrapsLines
        setNeedsLayout(); setNeedsDisplay()
    }

    private func applyTheme() {
        let palette = theme.palette
        backgroundColor = palette.background
        textColor = palette.text
        tintColor = palette.caret
    }

    func requestCompletion() {
        completionTask?.cancel()
        clearCompletion()
        let snapshot = logicalText
        let caret = selectedRange.location
        let range = selectedRange
        let currentLanguage = language
        if range.length == 0, let lexical = lexicalCompletion(in: snapshot, caret: caret) {
            showCompletion(lexical, range: range, append: false)
        }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            let value = range.length == 0
                ? await FoundationModelService.shared.complete(file: snapshot, caretUTF16: caret, language: currentLanguage)
                : await FoundationModelService.shared.suggestReplacement(file: snapshot, selection: range, language: currentLanguage)
            guard !Task.isCancelled, !value.isEmpty, let self,
                  self.logicalText == snapshot, self.selectedRange == range else { return }
            showCompletion(value, range: range, append: false)
        }
    }

    private func lexicalCompletion(in source: String, caret: Int) -> String? {
        let prefix = (source as NSString).substring(to: min(caret, (source as NSString).length))
        let token = prefix.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.last.map(String.init) ?? ""
        let candidates = ["function", "return", "struct", "class", "const", "continue", "import", "private", "public", "async", "await", "throws", "true", "false"]
        guard token.count >= 2, let match = candidates.first(where: { $0.hasPrefix(token) && $0 != token }) else { return nil }
        return String(match.dropFirst(token.count))
    }

    private func showCompletion(_ value: String, range: NSRange, append: Bool) {
        removeGhostRun()
        if append, !completionAlternatives.contains(value) { completionAlternatives.append(value) }
        else if !append { completionAlternatives = [value]; completionIndex = 0 }
        ghostText = value
        completionRange = range
        if range.length == 0 {
            let insertion = NSAttributedString(string: value, attributes: [
                .font: font ?? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                .foregroundColor: theme.palette.comment.withAlphaComponent(0.72),
                Self.ghostAttribute: true,
            ])
            isMutatingGhost = true
            textStorage.insert(insertion, at: range.location)
            ghostDisplayRange = NSRange(location: range.location, length: insertion.length)
            selectedRange = range
            isMutatingGhost = false
        } else {
            codingAccessoryView.setCorrectionSuggestions([value])
        }
        codingAccessoryView.setCompletionAvailable(true)
    }

    func didEdit() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.rehighlight() }
        }
        updateKeyboardTraits()
        requestCompletion()
    }

    func selectionDidChange() {
        guard !isMutatingGhost else { return }
        completionTask?.cancel()
        clearCompletion()
        updateCorrectionSuggestions()
        updateKeyboardTraits()
    }

    private func clearCompletion() {
        removeGhostRun()
        ghostText = ""
        completionRange = NSRange(location: 0, length: 0)
        codingAccessoryView.setCompletionAvailable(false)
    }

    private func removeGhostRun() {
        guard let range = ghostDisplayRange, NSMaxRange(range) <= textStorage.length else {
            ghostDisplayRange = nil
            return
        }
        isMutatingGhost = true
        let caret = selectedRange.location
        textStorage.deleteCharacters(in: range)
        selectedRange = NSRange(location: min(caret, textStorage.length), length: 0)
        ghostDisplayRange = nil
        isMutatingGhost = false
    }

    private func discardGhostCompletion() {
        guard ghostDisplayRange != nil else { return }
        clearCompletion()
    }

    private func updateCorrectionSuggestions() {
        guard selectedRange.length > 0, selectedRange.location != NSNotFound,
              NSMaxRange(selectedRange) <= textStorage.length else {
            codingAccessoryView.setCorrectionSuggestions([])
            return
        }
        let word = (textStorage.string as NSString).substring(with: selectedRange)
        guard word.rangeOfCharacter(from: .letters) != nil else {
            codingAccessoryView.setCorrectionSuggestions([])
            return
        }
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        let guesses = UITextChecker().guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: languageCode) ?? []
        codingAccessoryView.setCorrectionSuggestions(Array(guesses.prefix(3)))
    }

    private func updateKeyboardTraits() {
        let prose = language.isProse
        let source = logicalText as NSString
        let caret = min(selectedRange.location, source.length)
        let prefix = source.substring(to: caret).components(separatedBy: .whitespacesAndNewlines).last ?? ""
        let hasSyntax = prefix.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted) != nil
        // iOS 27 beta composites the prediction strip over custom editor accessories.
        // Keep spell checking, but let the editor-owned correction UI use this row.
        let correction: UITextAutocorrectionType = .no
        guard autocorrectionType != correction || spellCheckingType != (prose ? .yes : (hasSyntax ? .no : .default)) else { return }
        autocorrectionType = correction
        inlinePredictionType = .no
        spellCheckingType = prose ? .yes : (hasSyntax ? .no : .default)
        autocapitalizationType = prose ? .sentences : .none
        smartQuotesType = prose ? .yes : .no
        smartDashesType = prose ? .yes : .no
        smartInsertDeleteType = prose ? .yes : .no
        keyboardType = prose ? .default : .asciiCapable
        reloadInputViews()
    }

    @objc private func acceptCompletion() {
        guard !ghostText.isEmpty else { return }
        let insertion = ghostText
        let replacementRange = completionRange
        if let displayRange = ghostDisplayRange {
            isMutatingGhost = true
            textStorage.removeAttribute(Self.ghostAttribute, range: displayRange)
            textStorage.addAttribute(.foregroundColor, value: theme.palette.text, range: displayRange)
            selectedRange = NSRange(location: NSMaxRange(displayRange), length: 0)
            ghostDisplayRange = nil
            ghostText = ""
            completionRange = NSRange(location: 0, length: 0)
            codingAccessoryView.setCompletionAvailable(false)
            isMutatingGhost = false
            delegate?.textViewDidChange?(self)
        } else if replacementRange.length > 0 {
            clearCompletion()
            textStorage.replaceCharacters(in: replacementRange, with: insertion)
            selectedRange = NSRange(location: replacementRange.location, length: (insertion as NSString).length)
            delegate?.textViewDidChange?(self)
        } else {
            clearCompletion()
            insertText(insertion)
        }
    }

    private func forceAlternativeCompletion() {
        guard !ghostText.isEmpty else { requestCompletion(); return }
        if completionIndex + 1 < completionAlternatives.count {
            completionIndex += 1
            showCompletion(completionAlternatives[completionIndex], range: completionRange, append: true)
            return
        }
        alternativeSeed += 1
        let snapshot = logicalText
        let range = selectedRange
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            let value = await FoundationModelService.shared.complete(file: snapshot, caretUTF16: range.location, language: language, alternative: alternativeSeed)
            guard !Task.isCancelled, !value.isEmpty, self.logicalText == snapshot, self.selectedRange == range else { return }
            self.completionIndex = self.completionAlternatives.count
            self.showCompletion(value, range: range, append: true)
        }
    }

    func rehighlight() {
        let selection = selectedRange
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: typeface.font(size: editorFontSize),
            .foregroundColor: theme.palette.text,
        ], range: full)
        highlight("\\\"(?:\\\\.|[^\\\"\\\\])*\\\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`", color: theme.palette.string)
        highlight("(?m)//.*$|#(?![A-Fa-f0-9]{3,8}\\b).*$|/\\*[\\s\\S]*?\\*/|<!--[\\s\\S]*?-->", color: theme.palette.comment)
        highlight("\\b(?:class|struct|enum|protocol|extension|func|let|var|if|else|for|while|return|import|async|await|throws|try|switch|case|public|private|internal|actor|const|function|def|from|in|new|true|false|null|nil|self|this)\\b", color: theme.palette.keyword)
        highlight("\\b(?:Int|String|Bool|Double|Float|Void|Any|URL|Array|Dictionary|Promise|number|string|boolean|object)\\b", color: theme.palette.type)
        highlight("\\b(?:0x[0-9A-Fa-f]+|\\d+(?:\\.\\d+)?)\\b", color: theme.palette.number)
        if language == .html || language == .markdown {
            highlight("</?[A-Za-z][^>]*>|(?m)^#{1,6}\\s.*$|\\*\\*[^*]+\\*\\*", color: theme.palette.type)
        }
        if let ghostDisplayRange, NSMaxRange(ghostDisplayRange) <= textStorage.length {
            textStorage.addAttributes([
                .foregroundColor: theme.palette.comment.withAlphaComponent(0.72),
                Self.ghostAttribute: true,
            ], range: ghostDisplayRange)
        }
        textStorage.endEditing()
        selectedRange = selection
    }

    private func highlight(_ pattern: String, color: UIColor) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        for match in expression.matches(in: textStorage.string, range: range) {
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private func handleAccessoryAction(_ action: CodingAccessoryAction) {
        switch action {
        case .modifier(let modifier):
            if modifierState.contains(modifier) {
                modifierState.remove(modifier)
            } else {
                modifierState.insert(modifier)
            }

        case .correction(let value):
            guard selectedRange.length > 0 else { return }
            let range = selectedRange
            textStorage.replaceCharacters(in: range, with: value)
            selectedRange = NSRange(location: range.location + (value as NSString).length, length: 0)
            codingAccessoryView.setCorrectionSuggestions([])
            delegate?.textViewDidChange?(self)

        case .ai(let instruction):
            requestAIEdit?(instruction)

        case .find(let query, let replacement):
            performFind(query, replacement: replacement)

        case .command(let command):
            perform(command)
        }
    }

    private func performFind(_ query: String, replacement: String?) {
        if let replacement, !replacement.isEmpty { replaceFind(query, replacement: replacement, index: currentFindIndex, all: false) }
        else { showFind(query, index: currentFindIndex) }
    }

    private func showFind(_ query: String, index: Int) {
        findMatches.removeAll()
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.backgroundColor, range: full)
        guard !query.isEmpty else { return }
        let source = logicalText as NSString
        var location = 0
        while location < source.length {
            let match = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: location, length: source.length - location))
            guard match.location != NSNotFound else { break }
            findMatches.append(match)
            location = max(NSMaxRange(match), location + 1)
        }
        guard !findMatches.isEmpty else { return }
        currentFindIndex = min(max(0, index), findMatches.count - 1)
        for (matchIndex, match) in findMatches.enumerated() {
            textStorage.addAttribute(.backgroundColor, value: matchIndex == currentFindIndex ? UIColor.systemOrange.withAlphaComponent(0.75) : UIColor.systemYellow.withAlphaComponent(0.38), range: match)
        }
        let match = findMatches[currentFindIndex]
        selectedRange = match
        scrollRangeToVisible(match)
    }

    private func replaceFind(_ query: String, replacement: String, index: Int, all: Bool) {
        showFind(query, index: index)
        guard !findMatches.isEmpty else { return }
        if all { for match in findMatches.reversed() { textStorage.replaceCharacters(in: match, with: replacement) } }
        else { textStorage.replaceCharacters(in: findMatches[currentFindIndex], with: replacement) }
        findMatches.removeAll()
        delegate?.textViewDidChange?(self)
    }

    private func perform(_ command: EditorCommand) {
        switch command {
        case .indent:
            insertText("\t")

        case .outdent:
            outdentSelection()

        case .escape:
            resignFirstResponder()

        case .moveLeft:
            moveCaret(by: -1)

        case .moveRight:
            moveCaret(by: 1)

        case .moveUp:
            if modifierState.contains(.command) { selectedRange = NSRange(location: 0, length: 0) }
            else if modifierState.contains(.option) { moveToParagraphBoundary(end: false) }
            else { moveCaretVertically(by: -1) }

        case .moveDown:
            if modifierState.contains(.command) { selectedRange = NSRange(location: textStorage.length, length: 0) }
            else if modifierState.contains(.option) { moveToParagraphBoundary(end: true) }
            else { moveCaretVertically(by: 1) }

        case .moveBeginning:
            selectedRange = NSRange(location: 0, length: 0)

        case .moveEnd:
            selectedRange = NSRange(location: textStorage.length, length: 0)

        case .deleteBackward:
            deleteBackward()

        case .copy:
            if let range = selectedTextRange, let value = text(in: range), !value.isEmpty { UIPasteboard.general.string = value }

        case .paste:
            if let value = UIPasteboard.general.string { insertText(value) }

        case .selectAll:
            selectAll(nil)

        case .closeStructure:
            closeStructure()

        case .acceptCompletion:
            if ghostText.isEmpty { insertText("\t") } else { acceptCompletion() }

        case .alternativeCompletion:
            forceAlternativeCompletion()

        case .find:
            break

        case .ai:
            break

        case .toggleSymbolsKeyboard:
            showsSymbolsKeyboard.toggle()
            reloadInputViews()

        case .snippets:
            presentSnippetLibrary()

        case .insert(let text):
            if modifierState.contains(.command) { performCommandEquivalent(text) }
            else { insertText(modifierState.contains(.shift) ? text.uppercased() : text) }
        }
    }

    private func moveToParagraphBoundary(end: Bool) {
        let source = textStorage.string as NSString
        let location = min(selectedRange.location, source.length)
        let range = source.paragraphRange(for: NSRange(location: location, length: 0))
        selectedRange = NSRange(location: end ? NSMaxRange(range) : range.location, length: 0)
    }

    private func presentSnippetLibrary() {
        guard let controller = window?.rootViewController?.topmostPresentedController else { return }
        controller.present(SnippetLibraryViewController(textView: self), animated: true)
    }

    private func performCommandEquivalent(_ key: String) {
        switch key.lowercased() {
        case "a": selectAll(nil)
        case "c": perform(.copy)
        case "x": cut(nil)
        case "v": perform(.paste)
        case "z": undoManager?.undo()
        default: break
        }
    }

    private func restoreVolume() {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        restoringVolume = true
        slider.setValue(stableVolume, animated: false)
        slider.sendActions(for: .touchUpInside)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.restoringVolume = false }
    }

    private func moveCaret(by offset: Int) {
        guard let range = selectedTextRange,
              let position = position(from: range.end, offset: offset),
              let collapsedRange = textRange(from: position, to: position) else {
            return
        }

        selectedTextRange = collapsedRange
    }

    private func moveCaretVertically(by direction: Int) {
        guard let current = selectedTextRange else { return }
        let rect = caretRect(for: current.end)
        let target = CGPoint(x: rect.midX, y: rect.midY + CGFloat(direction) * max(rect.height, font?.lineHeight ?? 20))
        guard let position = closestPosition(to: target), let range = textRange(from: position, to: position) else { return }
        selectedTextRange = range
    }

    private func closeStructure() {
        let source = text as NSString
        let caret = min(selectedRange.location, source.length)
        let line = source.substring(with: source.lineRange(for: NSRange(location: caret, length: 0)))
        var closers: [Character] = []
        for character in line {
            switch character {
            case "{": closers.append("}")
            case "(": closers.append(")")
            case "[": closers.append("]")
            case "}", ")", "]": if !closers.isEmpty { closers.removeLast() }
            default: break
            }
        }
        guard let closer = closers.last else { return }
        insertText(String(closer))
    }

    @objc private func handleEditorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        tapCount = now - lastTapTime < 0.38 ? tapCount + 1 : 1
        lastTapTime = now
        becomeFirstResponder()
        tapResolutionWorkItem?.cancel()
        if tapCount >= 3 {
            tapCount = 0
            closeStructure()
            return
        }
        let point = recognizer.location(in: self)
        let count = tapCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tapCount = 0
            if count == 2 {
                if self.ghostText.isEmpty { self.requestCompletion() } else { self.acceptCompletion() }
            } else {
                self.handleSingleTap(at: point)
            }
        }
        tapResolutionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func handleSingleTap(at point: CGPoint) {
        guard let position = closestPosition(to: point) else { return }
        let offset = offset(from: beginningOfDocument, to: position)
        if selectedRange.length > 0, !NSLocationInRange(offset, selectedRange) {
            selectedTextRange = textRange(from: position, to: position)
            codingAccessoryView.setCorrectionSuggestions([])
            return
        }
        guard let range = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection.storage(.forward)) else {
            selectedTextRange = textRange(from: position, to: position)
            return
        }
        selectedTextRange = range
        updateCorrectionSuggestions()
        requestCompletion()
    }

    @objc private func handleCursorController(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            becomeFirstResponder()
            if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7) }
            lastCursorControllerPoint = point
            cursorControllerOrigin = point
            CursorDirectionHUD.show(over: self, at: point)
        case .changed:
            guard let previous = lastCursorControllerPoint else { return }
            let translation = CGPoint(x: point.x - previous.x, y: point.y - previous.y)
            guard max(abs(translation.x), abs(translation.y)) >= 8 else { return }
            let speed = min(8, max(1, Int(max(abs(point.x - (cursorControllerOrigin?.x ?? point.x)), abs(point.y - (cursorControllerOrigin?.y ?? point.y))) / 20)))
            if abs(translation.x) > abs(translation.y) { moveCaret(by: (translation.x > 0 ? 1 : -1) * speed) }
            else { for _ in 0..<speed { moveCaretVertically(by: translation.y > 0 ? 1 : -1) } }
            lastCursorControllerPoint = point
        default:
            lastCursorControllerPoint = nil
            cursorControllerOrigin = nil
            CursorDirectionHUD.hide()
        }
    }

    private func outdentSelection() {
        let nsText = text as NSString
        let location = min(selectedRange.location, nsText.length)
        let lineRange = nsText.lineRange(
            for: NSRange(location: location, length: 0)
        )

        guard lineRange.location < nsText.length else {
            return
        }

        let line = nsText.substring(with: lineRange)
        let count: Int

        if line.hasPrefix("\t") {
            count = 1
        } else if line.hasPrefix("    ") {
            count = 4
        } else {
            return
        }

        let oldSelection = selectedRange
        textStorage.replaceCharacters(
            in: NSRange(location: lineRange.location, length: count),
            with: ""
        )

        selectedRange = NSRange(
            location: max(oldSelection.location - count, lineRange.location),
            length: oldSelection.length
        )

        delegate?.textViewDidChange?(self)
    }

    @objc private func insertTab() {
        perform(.acceptCompletion)
    }

    @objc private func outdent() {
        perform(.outdent)
    }

    @objc private func escape() {
        perform(.escape)
    }
}

enum CodingAccessoryAction {
    case modifier(EditorModifierState)
    case command(EditorCommand)
    case correction(String)
    case ai(String)
    case find(String, String?)
}

private final class CodingAccessoryView: UIView {
    private let handler: (CodingAccessoryAction) -> Void
    private let toolStack = UIStackView()
    private let expansionStack = UIStackView()
    private let findField = UITextField()
    private let replaceField = UITextField()
    private let aiField = UITextField()
    private var expandedMode: ExpandedMode?
    private var modifierButtons: [EditorModifierState: UIButton] = [:]
    private var completionButtons: [UIButton] = []
    private var correctionButtons: [UIButton] = []

    private enum ExpandedMode { case find, replace, ai }

    init(handler: @escaping (CodingAccessoryAction) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: expandedMode == nil ? 52 : 98)
    }

    func setModifierState(_ state: EditorModifierState) {
        for (modifier, button) in modifierButtons {
            var configuration = button.configuration
            configuration?.baseBackgroundColor = state.contains(modifier)
                ? .secondarySystemFill
                : .clear
            button.configuration = configuration
        }
    }

    func setCompletionAvailable(_ available: Bool) {
        completionButtons.forEach { $0.isEnabled = available; $0.alpha = available ? 1 : 0.35 }
    }

    func setCorrectionSuggestions(_ values: [String]) {
        correctionButtons.forEach { $0.removeFromSuperview() }
        correctionButtons.removeAll()
        for value in values.prefix(3) {
            let button = makeButton(value)
            button.accessibilityLabel = "Replace with \(value)"
            button.addAction(UIAction { [weak self] _ in self?.handler(.correction(value)) }, for: .touchUpInside)
            correctionButtons.append(button)
            toolStack.addArrangedSubview(button)
        }
    }

    private func configure() {
        backgroundColor = .secondarySystemBackground

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true

        toolStack.axis = .horizontal
        toolStack.spacing = 6
        toolStack.alignment = .center
        toolStack.isLayoutMarginsRelativeArrangement = true
        toolStack.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        expansionStack.axis = .horizontal
        expansionStack.spacing = 6
        expansionStack.isHidden = true
        [findField, replaceField, aiField].forEach {
            $0.borderStyle = .roundedRect
            $0.clearButtonMode = .whileEditing
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
        }
        findField.placeholder = "Find"
        replaceField.placeholder = "Replace"
        aiField.placeholder = "Ask the on-device model…"
        findField.addTarget(self, action: #selector(findChanged), for: .editingChanged)
        replaceField.addTarget(self, action: #selector(findChanged), for: .editingDidEndOnExit)
        aiField.addTarget(self, action: #selector(submitAI), for: .editingDidEndOnExit)

        addSubview(scroll)
        addSubview(expansionStack)
        scroll.addSubview(toolStack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        expansionStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 52),

            toolStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            toolStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            toolStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            toolStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            toolStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),

            expansionStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            expansionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expansionStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            expansionStack.heightAnchor.constraint(equalToConstant: 40),
        ])

        addTool(symbol: "magnifyingglass", label: "Find") { [weak self] in self?.toggleFind() }
        addTool(symbol: "arrow.right.to.line.compact", label: "Tab") { [weak self] in self?.handler(.command(.acceptCompletion)) }
        addModifierTool(symbol: "command", label: "Command", modifier: .command)
        addModifierTool(symbol: "option", label: "Option", modifier: .option)
        addModifierTool(symbol: "shift", label: "Caps Lock", modifier: .shift)
        addTool(symbol: "sparkles", label: "AI Edit") { [weak self] in self?.show(.ai) }
        addTool(symbol: "keyboard", label: "Symbols Keyboard") { [weak self] in self?.handler(.command(.toggleSymbolsKeyboard)) }
    }

    private func toggleFind() {
        switch expandedMode {
        case nil: show(.find)
        case .find: show(.replace)
        case .replace: hideExpansion()
        case .ai: show(.find)
        }
    }

    private func show(_ mode: ExpandedMode) {
        expandedMode = mode
        expansionStack.arrangedSubviews.forEach { expansionStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        expansionStack.addArrangedSubview(mode == .ai ? aiField : findField)
        if mode == .replace { expansionStack.addArrangedSubview(replaceField) }
        if mode == .ai {
            let send = UIButton(type: .system)
            send.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
            send.addTarget(self, action: #selector(submitAI), for: .touchUpInside)
            expansionStack.addArrangedSubview(send)
        }
        expansionStack.isHidden = false
        invalidateIntrinsicContentSize()
        (mode == .ai ? aiField : findField).becomeFirstResponder()
    }

    private func hideExpansion() {
        expandedMode = nil
        expansionStack.isHidden = true
        invalidateIntrinsicContentSize()
    }

    @objc private func submitAI() {
        let value = aiField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return }
        handler(.ai(value))
        aiField.text = ""
        hideExpansion()
    }

    @objc private func findChanged() { handler(.find(findField.text ?? "", replaceField.text)) }

    private func addTool(symbol: String, label: String, action: @escaping () -> Void) {
        let button = makeSymbolButton(symbol: symbol, label: label)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        toolStack.addArrangedSubview(button)
    }

    private func addModifierTool(symbol: String, label: String, modifier: EditorModifierState) {
        let button = makeSymbolButton(symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in self?.handler(.modifier(modifier)) }, for: .touchUpInside)
        modifierButtons[modifier] = button
        toolStack.addArrangedSubview(button)
    }

    private func makeSymbolButton(symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .medium))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return button
    }

    private func addCommand(_ title: String, _ command: EditorCommand) {
        let button = makeButton(title)

        button.addAction(UIAction { [weak self] _ in
            self?.handler(.command(command))
        }, for: .touchUpInside)

        toolStack.addArrangedSubview(button)
    }

    private func addPrimaryCommand(_ title: String, _ command: EditorCommand) {
        let button = makeButton(title, compact: true)
        button.addAction(UIAction { [weak self] _ in self?.handler(.command(command)) }, for: .touchUpInside)
        toolStack.addArrangedSubview(button)
    }

    private func addPrimaryCompletionCommand(_ title: String, _ command: EditorCommand) {
        let button = makeButton(title, compact: true)
        button.isEnabled = false
        button.alpha = 0.35
        button.addAction(UIAction { [weak self] _ in self?.handler(.command(command)) }, for: .touchUpInside)
        completionButtons.append(button)
        toolStack.addArrangedSubview(button)
    }

    private func addPrimaryModifier(
        _ title: String,
        _ modifier: EditorModifierState
    ) {
        let button = makeButton(title, compact: true)

        button.addAction(UIAction { [weak self] _ in
            self?.handler(.modifier(modifier))
        }, for: .touchUpInside)

        modifierButtons[modifier] = button
        toolStack.addArrangedSubview(button)
    }

    private func makeButton(_ title: String, compact: Bool = false) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6,
            leading: compact ? 3 : 10,
            bottom: 6,
            trailing: compact ? 3 : 10
        )

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = UIFont.monospacedSystemFont(
            ofSize: 14,
            weight: .medium
        )
        return button
    }
}

@MainActor
private enum CursorDirectionHUD {
    private static var view: UIVisualEffectView?

    static func show(over textView: UIView, at point: CGPoint) {
        hide()
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        effect.frame = CGRect(x: point.x - 44, y: point.y - 44, width: 88, height: 88)
        effect.layer.cornerRadius = 44
        effect.clipsToBounds = true
        let label = UILabel(frame: effect.bounds)
        label.text = "↑\n←  →\n↓"
        label.numberOfLines = 3
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        effect.contentView.addSubview(label)
        textView.addSubview(effect)
        view = effect
    }

    static func hide() {
        view?.removeFromSuperview()
        view = nil
    }
}

private final class SymbolsKeyboardView: UIInputView {
    init(handler: @escaping (CodingAccessoryAction) -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 260), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        backgroundColor = .secondarySystemBackground

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 7
        let rows = [
            ["{", "}", "(", ")", "[", "]", "<", ">"],
            ["`", "|", "\\", "/", ":", ";", "=", "_"],
            ["!", "?", "&", "*", "+", "-", "$", "%"],
            ["\"", "'", "#", "@", ".", ",", "=>", "${}"],
        ]
        let navigation = UIStackView()
        navigation.axis = .horizontal
        navigation.spacing = 6
        navigation.distribution = .fillEqually
        let navigationItems: [(String, EditorCommand)] = [
            ("esc", .escape), ("←", .moveLeft), ("→", .moveRight), ("↑", .moveUp),
            ("↓", .moveDown), ("⌫", .deleteBackward), ("home", .moveBeginning), ("end", .moveEnd),
        ]
        for (title, command) in navigationItems {
            let button = UIButton(configuration: .filled())
            button.configuration?.title = title
            button.configuration?.baseBackgroundColor = .tertiarySystemFill
            button.addAction(UIAction { _ in handler(.command(command)) }, for: .touchUpInside)
            navigation.addArrangedSubview(button)
        }
        grid.addArrangedSubview(navigation)
        for values in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
            for value in values {
                let button = UIButton(configuration: .filled())
                button.configuration?.title = value
                button.configuration?.baseBackgroundColor = .tertiarySystemFill
                button.addAction(UIAction { _ in handler(.command(.insert(value))) }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            grid.addArrangedSubview(row)
        }

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 8
        bottom.distribution = .fillEqually
        for (title, symbol, command) in [
            ("Snippets", "curlybraces.square", EditorCommand.snippets),
            ("Undo", "arrow.uturn.backward", EditorCommand.insert("")),
            ("Tab", "arrow.right.to.line.compact", EditorCommand.acceptCompletion),
            ("Keyboard", "keyboard.chevron.compact.down", EditorCommand.toggleSymbolsKeyboard),
        ] {
            let button = UIButton(configuration: .gray())
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.title = title
            button.configuration?.imagePlacement = .top
            if title == "Undo" {
                button.addAction(UIAction { _ in handler(.modifier(.command)); handler(.command(.insert("z"))) }, for: .touchUpInside)
            } else { button.addAction(UIAction { _ in handler(.command(command)) }, for: .touchUpInside) }
            bottom.addArrangedSubview(button)
        }
        grid.addArrangedSubview(bottom)
        addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private struct EditorSnippet: Codable {
    var name: String
    var content: String
}

private final class SnippetLibraryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private weak var textView: CodeTextView?
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var snippets: [EditorSnippet] = []
    private static let storageKey = "editor.snippets"

    init(textView: CodeTextView) {
        self.textView = textView
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let data = UserDefaults.standard.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode([EditorSnippet].self, from: data) { snippets = saved }
        else {
            snippets = [
                .init(name: "HTML document", content: "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>Document</title>\n</head>\n<body>\n  \n</body>\n</html>"),
                .init(name: "HTML body", content: "<body>\n  \n</body>"),
                .init(name: "Markdown code block", content: "```\n\n```"),
                .init(name: "Swift initializer", content: "init() {\n    \n}"),
                .init(name: "If / else", content: "if condition {\n    \n} else {\n    \n}"),
                .init(name: "Do / catch", content: "do {\n    try operation()\n} catch {\n    \n}"),
                .init(name: "JavaScript try / catch", content: "try {\n  \n} catch (error) {\n  \n}"),
            ]
        }
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Snippets"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.showCreateMenu() })
        table.dataSource = self; table.delegate = self
        view.addSubview(table); table.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor), table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        if let sheet = sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { snippets.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let snippet = snippets[indexPath.row]
        cell.textLabel?.text = snippet.name
        cell.detailTextLabel?.text = snippet.content.replacingOccurrences(of: "\n", with: " ↵ ")
        cell.detailTextLabel?.lineBreakMode = .byTruncatingTail
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        textView?.insertText(snippets[indexPath.row].content)
        dismiss(animated: true)
    }

    private func showCreateMenu() {
        let menu = UIAlertController(title: "New Snippet", message: nil, preferredStyle: .actionSheet)
        let selected = textView.flatMap { $0.selectedRange.length > 0 ? ($0.textStorage.string as NSString).substring(with: $0.selectedRange) : nil }
        if let selected { menu.addAction(UIAlertAction(title: "From Selection", style: .default) { [weak self] _ in self?.previewAndName(selected) }) }
        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty { menu.addAction(UIAlertAction(title: "From Clipboard", style: .default) { [weak self] _ in self?.previewAndName(clipboard) }) }
        menu.addAction(UIAlertAction(title: "Create with AI", style: .default) { [weak self] _ in self?.askAIForSnippet() })
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(menu, animated: true)
    }

    private func previewAndName(_ content: String) {
        let preview = SnippetPreviewController(content: content) { [weak self] name in
            guard let self else { return }
            snippets.append(.init(name: name, content: content)); save(); table.reloadData()
        }
        present(UINavigationController(rootViewController: preview), animated: true)
    }

    private func askAIForSnippet() {
        let alert = UIAlertController(title: "Create with AI", message: "Describe the snippet", preferredStyle: .alert)
        alert.addTextField()
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let prompt = alert?.textFields?.first?.text, !prompt.isEmpty else { return }
            self?.textView?.requestAIEdit?("Insert a reusable snippet for: \(prompt)")
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
    private func save() { if let data = try? JSONEncoder().encode(snippets) { UserDefaults.standard.set(data, forKey: Self.storageKey) } }
}

private final class SnippetPreviewController: UIViewController {
    private let content: String
    private let completion: (String) -> Void
    init(content: String, completion: @escaping (String) -> Void) { self.content = content; self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Preview"
        let web = WKWebView(); web.isOpaque = false; web.backgroundColor = .clear
        let escaped = content.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        web.loadHTMLString("<meta name='viewport' content='width=device-width'><style>body{background:#0e1014;color:#f2f4f8;font:15px ui-monospace;white-space:pre-wrap;padding:16px}</style><body>\(escaped)</body>", baseURL: nil)
        view.addSubview(web); web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor), web.topAnchor.constraint(equalTo: view.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Name & Save", primaryAction: UIAction { [weak self] _ in self?.askName() })
    }
    private func askName() {
        let alert = UIAlertController(title: "Snippet Name", message: nil, preferredStyle: .alert); alert.addTextField()
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            completion(name); dismiss(animated: true)
        }); present(alert, animated: true)
    }
}

private extension UIViewController {
    var topmostPresentedController: UIViewController { presentedViewController?.topmostPresentedController ?? self }
}
