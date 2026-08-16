import Foundation
import FoundationModels

actor FoundationModelService {
    static let shared = FoundationModelService()

    private let model = SystemLanguageModel.default

    func proposeEdit(
        file: String,
        instruction: String,
        selection: NSRange
    ) async throws -> CodeEditProposal {
        guard model.isAvailable else {
            throw FoundationModelServiceError.unavailable
        }

        let source = file as NSString
        let range = clamped(selection, to: source.length)
        let before = source.substring(to: range.location)
        let selected = range.length > 0 ? source.substring(with: range) : "<caret>"
        let after = source.substring(from: NSMaxRange(range))

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are the editing engine inside a native text editor.
            Apply the user's instruction only at the supplied selection or caret.
            Preserve naming, formatting, comments, and unrelated code.
            Never wrap source in Markdown fences.
            The replacement field must contain only text that replaces the selection or is inserted at the caret.
            """
        )

        let response = try await session.respond(
            to: """
            USER INSTRUCTION:
            \(instruction)

            BEFORE SELECTION:
            \(before.suffix(2200))

            SELECTION:
            \(selected)

            AFTER SELECTION:
            \(after.prefix(1000))
            """,
            generating: CodeEditProposal.self,
            options: GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: 512
            )
        )

        return response.content
    }

    func complete(
        file: String,
        caretUTF16: Int,
        language: EditorLanguage,
        alternative: Int = 0
    ) async -> String {
        guard model.isAvailable else { return "" }

        let source = file as NSString
        let caret = min(max(0, caretUTF16), source.length)
        let before = source.substring(to: caret)
        let after = source.substring(from: caret)

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are inline autocomplete inside a native text editor.
            Continue exactly at the cursor between PREFIX and SUFFIX.
            Return only new text to insert at the cursor.
            Never repeat PREFIX or SUFFIX.
            Never explain, quote the context, or use Markdown fences.
            Prefer the shortest obvious continuation. Use multiple lines only when the continuation is very clear.
            """
        )

        let options: GenerationOptions
        if alternative == 0 {
            options = GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: 96
            )
        } else {
            options = GenerationOptions(
                samplingMode: .random(top: 16, seed: UInt64(alternative)),
                temperature: 0.55,
                maximumResponseTokens: 120
            )
        }

        do {
            let response = try await session.respond(
                to: """
                Language: \(language.rawValue)

                PREFIX:
                \(before.suffix(1800))

                <CURSOR>

                SUFFIX:
                \(after.prefix(400))
                """,
                options: options
            )

            return sanitizeCompletion(
                response.content,
                before: before,
                after: after
            )
        } catch {
            return ""
        }
    }

    private func sanitizeCompletion(
        _ raw: String,
        before: String,
        after: String
    ) -> String {
        var value = stripFence(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")

        let forbidden = [
            "<CURSOR>",
            "PREFIX:",
            "SUFFIX:",
            "Text before cursor:",
            "Text after cursor:",
        ]
        guard !forbidden.contains(where: { value.localizedCaseInsensitiveContains($0) }) else {
            return ""
        }

        let explanationPrefixes = [
            "Here is", "Here's", "I would", "The continuation", "This code", "Sure,",
        ]
        if explanationPrefixes.contains(where: { value.hasPrefix($0) }) {
            return ""
        }

        removeLeadingOverlap(from: &value, before: before)
        removeTrailingOverlap(from: &value, after: after)

        guard !value.isEmpty,
              value.count <= 1000,
              value.components(separatedBy: .newlines).count <= 6 else {
            return ""
        }

        let contextTail = String(before.suffix(120))
        if contextTail.count >= 50, value.contains(contextTail) {
            return ""
        }

        return value
    }

    private func stripFence(_ raw: String) -> String {
        var value = raw
        guard value.hasPrefix("```") else { return value }

        let lines = value.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return "" }

        var body = Array(lines.dropFirst())
        if body.last?.trimmingCharacters(in: .whitespaces) == "```" {
            body.removeLast()
        }
        value = body.joined(separator: "\n")
        return value
    }

    private func removeLeadingOverlap(from value: inout String, before: String) {
        let maximum = min(240, min(before.count, value.count))
        guard maximum >= 8 else { return }

        for length in stride(from: maximum, through: 8, by: -1) {
            let repeated = before.suffix(length)
            if value.hasPrefix(repeated) {
                value.removeFirst(length)
                return
            }
        }
    }

    private func removeTrailingOverlap(from value: inout String, after: String) {
        let maximum = min(160, min(after.count, value.count))
        guard maximum >= 8 else { return }

        for length in stride(from: maximum, through: 8, by: -1) {
            let repeated = after.prefix(length)
            if value.hasSuffix(repeated) {
                value.removeLast(length)
                return
            }
        }
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let remaining = max(0, length - location)
        return NSRange(
            location: location,
            length: min(max(0, range.length), remaining)
        )
    }
}

enum FoundationModelServiceError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple's on-device model is unavailable on this device."
        }
    }
}
