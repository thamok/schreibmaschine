import UIKit

final class CodeTextView: UITextView {
    var language: EditorLanguage = .plainText {
        didSet { if oldValue != language { rehighlight() } }
    }
    private var completionTask: Task<Void, Never>?
    private var ghostText = ""
    private let ghostLabel = UILabel()
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
        get { codingAccessoryView }
        set {}
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [.alternate], action: #selector(acceptCompletion), discoverabilityTitle: "Accept Completion"),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(insertTab)),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(outdent)),
            UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(escape)
            ),
        ]
    }

    private func configure() {
        backgroundColor = .systemBackground
        textColor = .label
        tintColor = .systemBlue

        font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no

        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        textContainerInset = UIEdgeInsets(
            top: 16,
            left: 12,
            bottom: 32,
            right: 12
        )
        ghostLabel.font = font
        ghostLabel.textColor = .tertiaryLabel
        ghostLabel.isHidden = true
        ghostLabel.isUserInteractionEnabled = false
        addSubview(ghostLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !ghostText.isEmpty,
              let position = position(from: beginningOfDocument, offset: selectedRange.location),
              let range = textRange(from: position, to: position) else { ghostLabel.isHidden = true; return }
        let caret = firstRect(for: range)
        ghostLabel.frame = CGRect(x: caret.minX, y: caret.minY, width: max(0, bounds.maxX - caret.minX - 12), height: max(22, caret.height))
        ghostLabel.isHidden = false
    }

    func requestCompletion() {
        completionTask?.cancel()
        clearCompletion()
        guard selectedRange.length == 0 else { return }
        let snapshot = text ?? ""
        let caret = selectedRange.location
        let currentLanguage = language
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let value = await FoundationModelService.shared.complete(file: snapshot, caretUTF16: caret, language: currentLanguage)
            guard !Task.isCancelled, !value.isEmpty, let self,
                  self.text == snapshot, self.selectedRange == NSRange(location: caret, length: 0) else { return }
            ghostText = value
            ghostLabel.text = value.components(separatedBy: .newlines).first
            setNeedsLayout()
        }
    }

    func didEdit() {
        rehighlight()
        requestCompletion()
    }

    func selectionDidChange() {
        completionTask?.cancel()
        clearCompletion()
        requestCompletion()
    }

    private func clearCompletion() {
        ghostText = ""
        ghostLabel.text = nil
        ghostLabel.isHidden = true
    }

    @objc private func acceptCompletion() {
        guard !ghostText.isEmpty else { return }
        let insertion = ghostText
        clearCompletion()
        insertText(insertion)
    }

    func rehighlight() {
        let selection = selectedRange
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular),
            .foregroundColor: UIColor.label,
        ], range: full)
        highlight("\\\"(?:\\\\.|[^\\\"\\\\])*\\\"|'(?:\\\\.|[^'\\\\])*'", color: .systemRed)
        highlight("(?m)//.*$|#(?![A-Fa-f0-9]{3,8}\\b).*$|/\\*[\\s\\S]*?\\*/|<!--[\\s\\S]*?-->", color: .systemGray)
        highlight("\\b(?:class|struct|enum|protocol|extension|func|let|var|if|else|for|while|return|import|async|await|throws|try|switch|case|public|private|const|function|def|from|in|new|true|false|null|nil)\\b", color: .systemPurple)
        highlight("\\b\\d+(?:\\.\\d+)?\\b", color: .systemOrange)
        if language == .html || language == .markdown {
            highlight("</?[A-Za-z][^>]*>|(?m)^#{1,6}\\s.*$|\\*\\*[^*]+\\*\\*", color: .systemBlue)
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

        case .command(let command):
            perform(command)
            modifierState = []
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

        case .insert(let text):
            insertText(text)
        }
    }

    private func moveCaret(by offset: Int) {
        guard let range = selectedTextRange,
              let position = position(from: range.end, offset: offset),
              let collapsedRange = textRange(from: position, to: position) else {
            return
        }

        selectedTextRange = collapsedRange
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
        perform(.indent)
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
}

private final class CodingAccessoryView: UIView {
    private let handler: (CodingAccessoryAction) -> Void
    private let stack = UIStackView()
    private var modifierButtons: [EditorModifierState: UIButton] = [:]

    init(handler: @escaping (CodingAccessoryAction) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
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

    private func configure() {
        backgroundColor = .secondarySystemBackground

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true

        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: 4,
            left: 8,
            bottom: 4,
            right: 8
        )

        addSubview(scroll)
        scroll.addSubview(stack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        addCommand("esc", .escape)
        addCommand("tab", .indent)
        addModifier("⇧", .shift)
        addModifier("⌃", .control)
        addModifier("⌥", .option)
        addModifier("⌘", .command)
        addCommand("←", .moveLeft)
        addCommand("→", .moveRight)
        addCommand("{", .insert("{"))
        addCommand("}", .insert("}"))
        addCommand("(", .insert("("))
        addCommand(")", .insert(")"))
        addCommand("[", .insert("["))
        addCommand("]", .insert("]"))
        addCommand("`", .insert("`"))
        addCommand("|", .insert("|"))
    }

    private func addCommand(_ title: String, _ command: EditorCommand) {
        let button = makeButton(title)

        button.addAction(UIAction { [weak self] _ in
            self?.handler(.command(command))
        }, for: .touchUpInside)

        stack.addArrangedSubview(button)
    }

    private func addModifier(
        _ title: String,
        _ modifier: EditorModifierState
    ) {
        let button = makeButton(title)

        button.addAction(UIAction { [weak self] _ in
            self?.handler(.modifier(modifier))
        }, for: .touchUpInside)

        modifierButtons[modifier] = button
        stack.addArrangedSubview(button)
    }

    private func makeButton(_ title: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6,
            leading: 10,
            bottom: 6,
            trailing: 10
        )

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = UIFont.monospacedSystemFont(
            ofSize: 14,
            weight: .medium
        )
        return button
    }
}
