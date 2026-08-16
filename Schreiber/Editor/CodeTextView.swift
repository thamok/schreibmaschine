import UIKit

final class CodeTextView: UITextView {
    var language: EditorLanguage = .plainText {
        didSet {
            guard oldValue != language else { return }
            rehighlight()
            updateKeyboardTraits()
        }
    }

    var theme: EditorTheme = .codex {
        didSet {
            guard oldValue != theme else { return }
            applyTheme()
            rehighlight()
            refreshGhostLabel()
        }
    }

    // Kept on the public editor surface for compatibility with the current settings UI.
    // The old custom long-press cursor controller was intentionally removed.
    var hapticsEnabled = true

    var typeface: EditorTypeface = .systemMono {
        didSet {
            guard oldValue != typeface else { return }
            applyEditorTypography()
        }
    }

    var editorFontSize: Double = 14 {
        didSet {
            guard oldValue != editorFontSize else { return }
            applyEditorTypography()
        }
    }

    var wrapsLines = true {
        didSet {
            guard oldValue != wrapsLines else { return }
            applyWrapping()
        }
    }

    // Kept for source compatibility. AI edits are currently driven by ContentView.
    var requestAIEdit: ((String) -> Void)?

    var logicalText: String { text ?? "" }
    var isPerformingGhostMutation: Bool { false }

    private var completionTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var completionAlternative = 0
    private var ghostText = ""
    private var keepGhostAfterEdit = false
    private var ignoreSelectionChange = false

    private var findQuery = ""
    private var findMatches: [NSRange] = []
    private var currentFindIndex = 0

    private var modifierState: EditorModifierState = []
    private var showsSymbolsKeyboard = false

    private let ghostLabel = UILabel()

    private lazy var symbolsKeyboard = SymbolsKeyboardView { [weak self] command in
        self?.perform(command)
    }

    private static let wordExpression = try! NSRegularExpression(
        pattern: "\\b[A-Za-z_][A-Za-z0-9_]{1,79}\\b"
    )

    private static let stringExpression = try! NSRegularExpression(
        pattern: "\\\"(?:\\\\.|[^\\\"\\\\])*\\\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
    )

    private static let commentExpression = try! NSRegularExpression(
        pattern: "(?m)//.*$|#(?![A-Fa-f0-9]{3,8}\\b).*$|/\\*[\\s\\S]*?\\*/|<!--[\\s\\S]*?-->"
    )

    private static let keywordExpression = try! NSRegularExpression(
        pattern: "\\b(?:class|struct|enum|protocol|extension|func|let|var|if|else|for|while|return|import|async|await|throws|try|switch|case|public|private|internal|actor|const|function|def|from|in|new|true|false|null|nil|self|this)\\b"
    )

    private static let typeExpression = try! NSRegularExpression(
        pattern: "\\b(?:Int|String|Bool|Double|Float|Void|Any|URL|Array|Dictionary|Promise|number|string|boolean|object)\\b"
    )

    private static let numberExpression = try! NSRegularExpression(
        pattern: "\\b(?:0x[0-9A-Fa-f]+|\\d+(?:\\.\\d+)?)\\b"
    )

    private static let markupExpression = try! NSRegularExpression(
        pattern: "</?[A-Za-z][^>]*>|(?m)^#{1,6}\\s.*$|\\*\\*[^*]+\\*\\*"
    )

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var inputAccessoryView: UIView? {
        get { nil }
        set {}
    }

    override var inputView: UIView? {
        get { showsSymbolsKeyboard ? symbolsKeyboard : nil }
        set {}
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: "Accept Completion or Indent",
                action: #selector(insertTab),
                input: "\t"
            ),
            UIKeyCommand(
                title: "Outdent",
                action: #selector(outdent),
                input: "\t",
                modifierFlags: [.shift]
            ),
            UIKeyCommand(
                title: "Dismiss Keyboard",
                action: #selector(escape),
                input: UIKeyCommand.inputEscape
            ),
        ]
    }

    override func insertText(_ text: String) {
        if modifierState.contains(.command), text.count == 1 {
            cancelCompletion()
            performCommandEquivalent(text)
            return
        }

        if modifierState.contains(.control),
           let scalar = text.lowercased().unicodeScalars.first,
           scalar.value >= 97,
           scalar.value <= 122,
           let control = UnicodeScalar(scalar.value - 96) {
            cancelCompletion()
            markSelectionChangeAsTextInput()
            super.insertText(String(control))
            return
        }

        let insertion = modifierState.contains(.shift) ? text.uppercased() : text

        if selectedRange.length == 0,
           !ghostText.isEmpty,
           ghostText.hasPrefix(insertion) {
            completionTask?.cancel()
            completionTask = nil
            keepGhostAfterEdit = true
            markSelectionChangeAsTextInput()
            super.insertText(insertion)
            ghostText.removeFirst(insertion.count)
            refreshGhostLabel()
            return
        }

        cancelCompletion()
        markSelectionChangeAsTextInput()
        super.insertText(insertion)
    }

    override func deleteBackward() {
        cancelCompletion()
        markSelectionChangeAsTextInput()
        super.deleteBackward()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGhostFrame()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawLineNumbers(in: rect)
    }

    func prepareForExternalTextUpdate() {
        cancelCompletion()
    }

    func didEdit() {
        setNeedsDisplay()

        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            self?.rehighlight()
        }

        if keepGhostAfterEdit {
            keepGhostAfterEdit = false
            updateGhostFrame()
            return
        }

        requestCompletion()
    }

    func selectionDidChange() {
        if ignoreSelectionChange {
            updateGhostFrame()
            return
        }

        cancelCompletion()
    }

    func requestCompletion() {
        completionTask?.cancel()
        completionTask = nil
        clearGhost()
        completionAlternative = 0

        guard selectedRange.length == 0 else { return }

        let snapshot = logicalText
        let caret = min(selectedRange.location, (snapshot as NSString).length)
        let currentLanguage = language

        if let lexical = lexicalCompletion(in: snapshot, caret: caret) {
            showCompletion(lexical)
        }

        guard shouldAskModel(snapshot: snapshot, caret: caret) else { return }

        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }

            let value = await FoundationModelService.shared.complete(
                file: snapshot,
                caretUTF16: caret,
                language: currentLanguage
            )

            guard !Task.isCancelled,
                  !value.isEmpty,
                  let self,
                  self.logicalText == snapshot,
                  self.selectedRange == NSRange(location: caret, length: 0) else {
                return
            }

            self.showCompletion(value)
        }
    }

    func rehighlight() {
        let full = NSRange(location: 0, length: textStorage.length)
        let baseFont = typeface.font(size: editorFontSize)
        let palette = theme.palette

        typingAttributes = [
            .font: baseFont,
            .foregroundColor: palette.text,
        ]

        guard full.length > 0 else {
            setNeedsDisplay()
            return
        }

        textStorage.beginEditing()
        textStorage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: palette.text,
            ],
            range: full
        )

        apply(Self.stringExpression, color: palette.string, range: full)
        apply(Self.commentExpression, color: palette.comment, range: full)
        apply(Self.keywordExpression, color: palette.keyword, range: full)
        apply(Self.typeExpression, color: palette.type, range: full)
        apply(Self.numberExpression, color: palette.number, range: full)

        if language == .html || language == .markdown {
            apply(Self.markupExpression, color: palette.type, range: full)
        }

        applyFindHighlights()
        textStorage.endEditing()
        setNeedsDisplay()
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

        ghostLabel.numberOfLines = 6
        ghostLabel.isUserInteractionEnabled = false
        ghostLabel.backgroundColor = .clear
        ghostLabel.lineBreakMode = .byClipping
        ghostLabel.isHidden = true
        addSubview(ghostLabel)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolNotification(_:)),
            name: .editorToolAction,
            object: nil
        )
    }

    private func applyTheme() {
        let palette = theme.palette
        backgroundColor = palette.background
        textColor = palette.text
        tintColor = palette.caret
    }

    private func applyEditorTypography() {
        font = typeface.font(size: editorFontSize)
        rehighlight()
        refreshGhostLabel()
        setNeedsDisplay()
    }

    private func applyWrapping() {
        textContainer.widthTracksTextView = wrapsLines
        textContainer.lineBreakMode = wrapsLines ? .byWordWrapping : .byClipping
        textContainer.size = CGSize(
            width: wrapsLines ? bounds.width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        alwaysBounceHorizontal = !wrapsLines
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func updateKeyboardTraits() {
        let prose = language.isProse
        autocorrectionType = prose ? .default : .no
        inlinePredictionType = .no
        spellCheckingType = prose ? .yes : .no
        autocapitalizationType = prose ? .sentences : .none
        smartQuotesType = prose ? .yes : .no
        smartDashesType = prose ? .yes : .no
        smartInsertDeleteType = prose ? .yes : .no
        keyboardType = prose ? .default : .asciiCapable
        reloadInputViews()
    }

    private func apply(
        _ expression: NSRegularExpression,
        color: UIColor,
        range: NSRange
    ) {
        expression.enumerateMatches(in: textStorage.string, range: range) { [weak self] match, _, _ in
            guard let self, let match else { return }
            self.textStorage.addAttribute(
                .foregroundColor,
                value: color,
                range: match.range
            )
        }
    }

    private func shouldAskModel(snapshot: String, caret: Int) -> Bool {
        guard caret > 0 else { return false }
        let before = (snapshot as NSString).substring(to: caret)
        return before.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private func lexicalCompletion(in source: String, caret: Int) -> String? {
        let text = source as NSString
        let caret = min(max(0, caret), text.length)
        guard caret > 0 else { return nil }

        var tokenStart = caret
        let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        while tokenStart > 0 {
            let scalarRange = text.rangeOfComposedCharacterSequence(at: tokenStart - 1)
            let scalar = text.substring(with: scalarRange)
            if scalar.rangeOfCharacter(from: valid.inverted) != nil {
                break
            }
            tokenStart = scalarRange.location
        }

        let tokenRange = NSRange(location: tokenStart, length: caret - tokenStart)
        guard tokenRange.length >= 2 else { return nil }
        let token = text.substring(with: tokenRange)

        let windowStart = max(0, caret - 8000)
        let windowEnd = min(text.length, caret + 2000)
        let windowRange = NSRange(location: windowStart, length: windowEnd - windowStart)

        var scores: [String: Int] = [:]
        Self.wordExpression.enumerateMatches(in: source, range: windowRange) { match, _, _ in
            guard let match,
                  NSIntersectionRange(match.range, tokenRange).length == 0 else {
                return
            }

            let candidate = text.substring(with: match.range)
            guard candidate.count > token.count,
                  candidate.hasPrefix(token) else {
                return
            }

            let distance = abs(match.range.location - caret)
            let proximity = max(0, 1000 - min(1000, distance))
            scores[candidate, default: 0] += 100 + proximity / 20
        }

        guard let candidate = scores.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.count > rhs.key.count
            }
            return lhs.value < rhs.value
        })?.key else {
            return nil
        }

        return String(candidate.dropFirst(token.count))
    }

    private func showCompletion(_ value: String) {
        guard selectedRange.length == 0, !value.isEmpty else { return }
        ghostText = value
        refreshGhostLabel()
    }

    private func clearGhost() {
        ghostText = ""
        ghostLabel.text = nil
        ghostLabel.attributedText = nil
        ghostLabel.isHidden = true
    }

    private func cancelCompletion() {
        completionTask?.cancel()
        completionTask = nil
        completionAlternative = 0
        clearGhost()
    }

    private func refreshGhostLabel() {
        guard !ghostText.isEmpty else {
            ghostLabel.isHidden = true
            return
        }

        let font = typeface.font(size: editorFontSize)
        ghostLabel.attributedText = NSAttributedString(
            string: displayedGhostText,
            attributes: [
                .font: font,
                .foregroundColor: theme.palette.comment.withAlphaComponent(0.72),
            ]
        )
        ghostLabel.isHidden = false
        updateGhostFrame()
    }

    private var displayedGhostText: String {
        ghostText.hasPrefix("\n") ? String(ghostText.dropFirst()) : ghostText
    }

    private func updateGhostFrame() {
        guard !ghostText.isEmpty,
              !ghostLabel.isHidden,
              let selectedTextRange else {
            return
        }

        let caret = caretRect(for: selectedTextRange.end)
        let startsOnNextLine = ghostText.hasPrefix("\n")
        let x = startsOnNextLine ? textContainerInset.left : caret.maxX
        let y = startsOnNextLine ? caret.maxY : caret.minY
        let availableWidth = max(
            80,
            bounds.width - x - textContainerInset.right - 8
        )
        let lineHeight = font?.lineHeight ?? 20
        let size = ghostLabel.sizeThatFits(
            CGSize(
                width: availableWidth,
                height: lineHeight * 6
            )
        )

        ghostLabel.frame = CGRect(
            x: x,
            y: y,
            width: min(availableWidth, max(8, ceil(size.width) + 4)),
            height: min(lineHeight * 6, max(lineHeight, ceil(size.height)))
        )
    }

    private func markSelectionChangeAsTextInput() {
        ignoreSelectionChange = true
        DispatchQueue.main.async { [weak self] in
            self?.ignoreSelectionChange = false
        }
    }

    @objc private func acceptCompletion() {
        guard !ghostText.isEmpty else {
            insertText("\t")
            return
        }

        let insertion = ghostText
        completionTask?.cancel()
        completionTask = nil
        clearGhost()
        markSelectionChangeAsTextInput()
        super.insertText(insertion)
    }

    private func forceAlternativeCompletion() {
        guard selectedRange.length == 0 else { return }

        completionAlternative += 1
        let alternative = completionAlternative
        let snapshot = logicalText
        let caret = selectedRange.location
        let currentLanguage = language

        completionTask?.cancel()
        completionTask = Task { [weak self] in
            let value = await FoundationModelService.shared.complete(
                file: snapshot,
                caretUTF16: caret,
                language: currentLanguage,
                alternative: alternative
            )

            guard !Task.isCancelled,
                  !value.isEmpty,
                  let self,
                  self.logicalText == snapshot,
                  self.selectedRange == NSRange(location: caret, length: 0) else {
                return
            }

            self.showCompletion(value)
        }
    }

    @objc private func handleToolNotification(_ notification: Notification) {
        guard window != nil,
              let action = notification.object as? EditorToolAction else {
            return
        }

        switch action {
        case .command(let command):
            perform(command)
        case .modifier(let modifier):
            if modifierState.contains(modifier) {
                modifierState.remove(modifier)
            } else {
                modifierState.insert(modifier)
            }
        case .find(let query, let index):
            showFind(query, index: index)
        case .replace(let query, let replacement, let index, let all):
            replaceFind(query, replacement: replacement, index: index, all: all)
        }
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
            if modifierState.contains(.command) {
                selectedRange = NSRange(location: 0, length: 0)
            } else if modifierState.contains(.option) {
                moveToParagraphBoundary(end: false)
            } else {
                moveCaretVertically(by: -1)
            }

        case .moveDown:
            if modifierState.contains(.command) {
                selectedRange = NSRange(location: textStorage.length, length: 0)
            } else if modifierState.contains(.option) {
                moveToParagraphBoundary(end: true)
            } else {
                moveCaretVertically(by: 1)
            }

        case .moveBeginning:
            selectedRange = NSRange(location: 0, length: 0)

        case .moveEnd:
            selectedRange = NSRange(location: textStorage.length, length: 0)

        case .deleteBackward:
            deleteBackward()

        case .copy:
            if let range = selectedTextRange,
               let value = text(in: range),
               !value.isEmpty {
                UIPasteboard.general.string = value
            }

        case .paste:
            if let value = UIPasteboard.general.string {
                insertText(value)
            }

        case .selectAll:
            selectAll(nil)

        case .acceptCompletion:
            acceptCompletion()

        case .alternativeCompletion:
            forceAlternativeCompletion()

        case .toggleSymbolsKeyboard:
            showsSymbolsKeyboard.toggle()
            reloadInputViews()

        case .insert(let value):
            insertText(value)

        case .closeStructure, .find, .ai, .snippets:
            break
        }
    }

    private func showFind(_ query: String, index: Int) {
        findQuery = query
        findMatches.removeAll()
        currentFindIndex = 0

        guard !query.isEmpty else {
            rehighlight()
            return
        }

        let source = logicalText as NSString
        var location = 0
        while location < source.length {
            let match = source.range(
                of: query,
                options: [.caseInsensitive],
                range: NSRange(
                    location: location,
                    length: source.length - location
                )
            )
            guard match.location != NSNotFound else { break }
            findMatches.append(match)
            location = max(NSMaxRange(match), location + 1)
        }

        guard !findMatches.isEmpty else {
            rehighlight()
            return
        }

        currentFindIndex = min(max(0, index), findMatches.count - 1)
        rehighlight()
        let match = findMatches[currentFindIndex]
        selectedRange = match
        scrollRangeToVisible(match)
    }

    private func replaceFind(
        _ query: String,
        replacement: String,
        index: Int,
        all: Bool
    ) {
        showFind(query, index: index)
        guard !findMatches.isEmpty else { return }

        cancelCompletion()
        if all {
            for match in findMatches.reversed() {
                textStorage.replaceCharacters(in: match, with: replacement)
            }
        } else {
            let match = findMatches[currentFindIndex]
            textStorage.replaceCharacters(in: match, with: replacement)
            selectedRange = NSRange(
                location: match.location + (replacement as NSString).length,
                length: 0
            )
        }

        findQuery = ""
        findMatches.removeAll()
        delegate?.textViewDidChange?(self)
    }

    private func applyFindHighlights() {
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.backgroundColor, range: full)

        for (index, match) in findMatches.enumerated()
        where NSMaxRange(match) <= textStorage.length {
            let color = index == currentFindIndex
                ? UIColor.systemOrange.withAlphaComponent(0.75)
                : UIColor.systemYellow.withAlphaComponent(0.38)
            textStorage.addAttribute(
                .backgroundColor,
                value: color,
                range: match
            )
        }
    }

    private func moveToParagraphBoundary(end: Bool) {
        let source = logicalText as NSString
        let location = min(selectedRange.location, source.length)
        let range = source.paragraphRange(
            for: NSRange(location: location, length: 0)
        )
        selectedRange = NSRange(
            location: end ? NSMaxRange(range) : range.location,
            length: 0
        )
    }

    private func moveCaret(by offset: Int) {
        guard let range = selectedTextRange,
              let position = position(from: range.end, offset: offset),
              let collapsed = textRange(from: position, to: position) else {
            return
        }
        selectedTextRange = collapsed
    }

    private func moveCaretVertically(by direction: Int) {
        guard let current = selectedTextRange else { return }
        let rect = caretRect(for: current.end)
        let target = CGPoint(
            x: rect.midX,
            y: rect.midY + CGFloat(direction) * max(rect.height, font?.lineHeight ?? 20)
        )
        guard let position = closestPosition(to: target),
              let range = textRange(from: position, to: position) else {
            return
        }
        selectedTextRange = range
    }

    private func outdentSelection() {
        let source = logicalText as NSString
        let location = min(selectedRange.location, source.length)
        let lineRange = source.lineRange(
            for: NSRange(location: location, length: 0)
        )
        guard lineRange.location < source.length else { return }

        let line = source.substring(with: lineRange)
        let count: Int
        if line.hasPrefix("\t") {
            count = 1
        } else if line.hasPrefix("    ") {
            count = 4
        } else {
            return
        }

        let previous = selectedRange
        cancelCompletion()
        textStorage.replaceCharacters(
            in: NSRange(location: lineRange.location, length: count),
            with: ""
        )
        selectedRange = NSRange(
            location: max(previous.location - count, lineRange.location),
            length: previous.length
        )
        delegate?.textViewDidChange?(self)
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

    private func drawLineNumbers(in rect: CGRect) {
        let source = logicalText as NSString
        let numberFont = UIFont.monospacedDigitSystemFont(
            ofSize: 10,
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: theme.palette.comment.withAlphaComponent(0.7),
        ]

        if source.length == 0 || layoutManager.numberOfGlyphs == 0 {
            ("1" as NSString).draw(
                in: CGRect(
                    x: 4,
                    y: textContainerInset.top,
                    width: 34,
                    height: font?.lineHeight ?? 20
                ),
                withAttributes: attributes
            )
            return
        }

        var location = 0
        var line = 1
        while location < source.length {
            let characterRange = source.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )

            if glyphRange.length > 0 {
                let fragment = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
                let drawRect = CGRect(
                    x: 4,
                    y: textContainerInset.top + fragment.minY,
                    width: 34,
                    height: fragment.height
                )
                if drawRect.intersects(rect) {
                    ("\(line)" as NSString).draw(
                        in: drawRect,
                        withAttributes: attributes
                    )
                }
            }

            let next = NSMaxRange(characterRange)
            guard next > location else { break }
            location = next
            line += 1
        }
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

private final class SymbolsKeyboardView: UIInputView {
    private let handler: (EditorCommand) -> Void

    init(handler: @escaping (EditorCommand) -> Void) {
        self.handler = handler
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: 220),
            inputViewStyle: .keyboard
        )
        allowsSelfSizing = false
        backgroundColor = .secondarySystemBackground
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7

        let rows = [
            ["{", "}", "(", ")", "[", "]", "<", ">"],
            ["`", "|", "\\", "/", ":", ";", "=", "_"],
            ["!", "?", "&", "*", "+", "-", "$", "%"],
            ["\"", "'", "#", "@", ".", ",", "=>", "${}"],
        ]

        for values in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually

            for value in values {
                let button = UIButton(configuration: .gray())
                button.configuration?.title = value
                button.addAction(
                    UIAction { [weak self] _ in
                        self?.handler(.insert(value))
                    },
                    for: .touchUpInside
                )
                row.addArrangedSubview(button)
            }

            stack.addArrangedSubview(row)
        }

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 6
        bottom.distribution = .fillEqually

        for (title, command) in [
            ("ABC", EditorCommand.toggleSymbolsKeyboard),
            ("←", EditorCommand.moveLeft),
            ("Tab", EditorCommand.acceptCompletion),
            ("→", EditorCommand.moveRight),
        ] {
            let button = UIButton(configuration: .filled())
            button.configuration?.title = title
            button.addAction(
                UIAction { [weak self] _ in self?.handler(command) },
                for: .touchUpInside
            )
            bottom.addArrangedSubview(button)
        }

        stack.addArrangedSubview(bottom)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }
}
