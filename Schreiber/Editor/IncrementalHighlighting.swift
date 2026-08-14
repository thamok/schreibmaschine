import UIKit

struct EditorHighlightRule {
    let expression: NSRegularExpression
    let color: UIColor
}

final class IncrementalHighlightingEngine {
    private var pendingRange: NSRange?

    func invalidate(_ range: NSRange, in text: NSString) {
        guard text.length > 0 else {
            pendingRange = nil
            return
        }
        let boundedLocation = min(max(0, range.location), text.length)
        let boundedLength = min(max(0, range.length), text.length - boundedLocation)
        let paragraph = text.paragraphRange(for: NSRange(location: boundedLocation, length: boundedLength))
        let padding = 256
        let start = max(0, paragraph.location - padding)
        let end = min(text.length, NSMaxRange(paragraph) + padding)
        let expanded = text.paragraphRange(for: NSRange(location: start, length: end - start))
        pendingRange = pendingRange.map { NSUnionRange($0, expanded) } ?? expanded
    }

    func consume(in text: NSString) -> NSRange? {
        guard text.length > 0, let pendingRange else {
            self.pendingRange = nil
            return nil
        }
        self.pendingRange = nil
        return NSIntersectionRange(pendingRange, NSRange(location: 0, length: text.length))
    }

    func apply(
        to storage: NSTextStorage,
        range: NSRange,
        baseFont: UIFont,
        baseColor: UIColor,
        rules: [EditorHighlightRule]
    ) {
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: baseColor], range: range)
        let source = storage.string
        for rule in rules {
            rule.expression.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: match.range)
            }
        }
        storage.endEditing()
    }
}
