import Foundation
import FoundationModels
import TreeSitter
import TreeSitterResource

actor FoundationModelService {
    static let shared = FoundationModelService()

    private let model = SystemLanguageModel.default
    private lazy var completionSession = LanguageModelSession(model: model, instructions: "Produce only new text that belongs exactly at the cursor. Never quote, summarize, explain, or reproduce the supplied context. Prefer a useful 2-12 line continuation when the intent is clear; otherwise return a short insertion.")
    private lazy var correctionSession = LanguageModelSession(model: model, instructions: "Return only the smallest corrected replacement for the selected text. Never reproduce the rest of the file or explain the change.")

    var isAvailable: Bool {
        model.isAvailable
    }

    func proposeEdit(
        file: String,
        instruction: String,
        selection: NSRange
    ) async throws -> CodeEditProposal {
        guard model.isAvailable else {
            throw FoundationModelServiceError.unavailable
        }

        let session = LanguageModelSession(model: model, instructions: """
            You are the editing engine inside a native code editor.
            Apply the user's instruction to the supplied source selection, or produce an insertion when given a caret.
            Preserve unrelated code, formatting, comments, and naming.
            Never wrap source code in Markdown fences.
            Return only the replacement for that selection or the source to insert at the caret.
            """)

        let source = file as NSString
        let validSelection = NSIntersectionRange(selection, NSRange(location: 0, length: source.length))
        let selected = validSelection.length > 0
            ? source.substring(with: validSelection)
            : "<caret at UTF-16 offset \(validSelection.location)>"
        let prompt = """
        USER INSTRUCTION:
        \(instruction)

        SOURCE SELECTION:
        \(selected)

        FILE CONTEXT:
        \(file)
        """

        let response = try await session.respond(
            to: prompt,
            generating: CodeEditProposal.self
        )

        return response.content
    }

    func complete(file: String, caretUTF16: Int, language: EditorLanguage, alternative: Int = 0) async -> String {
        guard model.isAvailable else { return "" }
        let source = file as NSString
        let offset = min(caretUTF16, source.length)
        let symbols = TreeSitterContext.symbols(in: file, language: language).prefix(80).joined(separator: ", ")
        do {
            let options = GenerationOptions(
                samplingMode: alternative == 0 ? .random(top: 8, seed: 0) : .random(top: 32, seed: UInt64(alternative)),
                temperature: alternative == 0 ? 0.25 : 0.7,
                maximumResponseTokens: 240
            )
            let before = source.substring(to: offset)
            let after = source.substring(from: offset)
            let response = try await completionSession.respond(
                to: "Language: \(language.rawValue)\nLocal symbols: \(symbols)\nText before cursor:\n\(before.suffix(2600))\n<INSERT HERE>\nText after cursor:\n\(after.prefix(700))",
                generating: InlineCompletion.self,
                options: options
            )
            return sanitize(response.content.insertion, before: before, language: language)
        } catch { return "" }
    }

    func suggestReplacement(file: String, selection: NSRange, language: EditorLanguage) async -> String {
        guard model.isAvailable else { return "" }
        let source = file as NSString
        let range = NSIntersectionRange(selection, NSRange(location: 0, length: source.length))
        guard range.length > 0 else { return "" }
        do {
            let selected = source.substring(with: range)
            let response = try await correctionSession.respond(
                to: "Language: \(language.rawValue)\nSelected text:\n\(selected)\nNearby file context:\n\(file.prefix(5000))",
                generating: InlineCompletion.self,
                options: GenerationOptions(samplingMode: .random(top: 8, seed: 1), temperature: 0.2, maximumResponseTokens: 160)
            )
            let replacement = sanitize(response.content.insertion, before: "", language: language)
            return replacement == selected ? "" : replacement
        } catch { return "" }
    }

    private func sanitize(_ raw: String, before: String, language: EditorLanguage) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            let lines = value.components(separatedBy: .newlines)
            if lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                value = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }
        if language.isProse {
            value = value.replacingOccurrences(of: "\\r\\n", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
        }

        let forbidden = ["<CURSOR>", "<INSERT HERE>", "VISIBLE SYMBOLS:", "Text before cursor:", "Text after cursor:"]
        guard !forbidden.contains(where: { value.localizedCaseInsensitiveContains($0) }) else { return "" }

        let contextTail = String(before.suffix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        if contextTail.count >= 60, value.contains(contextTail) { return "" }

        let maximumOverlap = min(400, min(before.count, value.count))
        if maximumOverlap >= 8 {
            for length in stride(from: maximumOverlap, through: 8, by: -1) {
                let repeated = before.suffix(length)
                if value.hasPrefix(repeated) {
                    value.removeFirst(length)
                    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        guard !value.isEmpty, value.components(separatedBy: .newlines).count <= 12 else { return "" }
        return value
    }
}

@Generable(description: "Text to insert directly into the editor at the cursor, with no explanation or surrounding context.")
private struct InlineCompletion {
    @Guide(description: "Only the exact new text to insert. Use real line breaks, never escaped newline text. Do not repeat any supplied context.")
    var insertion: String
}

private enum TreeSitterContext {
    static func symbols(in source: String, language: EditorLanguage) -> [String] {
        guard let grammar = grammar(for: language), let parser = ts_parser_new() else { return [] }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, grammar.parser) else { return [] }
        let bytes = Array(source.utf8)
        let tree = bytes.withUnsafeBytes { buffer in
            ts_parser_parse_string(parser, nil, buffer.bindMemory(to: CChar.self).baseAddress, UInt32(buffer.count))
        }
        guard let tree else { return [] }
        defer { ts_tree_delete(tree) }
        var result: [String] = []
        walk(ts_tree_root_node(tree), bytes: bytes, into: &result)
        return Array(Set(result)).sorted()
    }

    private static func walk(_ node: TSNode, bytes: [UInt8], into result: inout [String]) {
        let type = String(cString: ts_node_type(node))
        if ["identifier", "type_identifier", "property_identifier", "function_name", "class_name"].contains(type) {
            let lower = Int(ts_node_start_byte(node))
            let upper = Int(ts_node_end_byte(node))
            if lower >= 0, upper <= bytes.count, lower < upper,
               let value = String(bytes: bytes[lower..<upper], encoding: .utf8), value.count < 80 {
                result.append(value)
            }
        }
        for index in 0..<ts_node_named_child_count(node) {
            walk(ts_node_named_child(node, index), bytes: bytes, into: &result)
        }
    }

    private static func grammar(for language: EditorLanguage) -> TreeSitterLanguage? {
        switch language {
        case .swift: .swift
        case .python: .python
        case .ruby: .ruby
        case .java: .java
        case .go: .go
        case .php: .php
        case .json: .json
        case .html: .html
        case .css: .css
        case .markdown: .markdown
        default: nil
        }
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
