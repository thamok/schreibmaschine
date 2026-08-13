import Foundation
import FoundationModels
import TreeSitter
import TreeSitterResource

actor FoundationModelService {
    static let shared = FoundationModelService()

    private let model = SystemLanguageModel.default

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

        let session = LanguageModelSession(model: model) {
            """
            You are the editing engine inside a native code editor.
            Apply the user's instruction to the supplied source file.
            Preserve unrelated code, formatting, comments, and naming.
            Never wrap source code in Markdown fences.
            Return a complete replacement for the file.
            """
        }

        let source = file as NSString
        let validSelection = NSIntersectionRange(selection, NSRange(location: 0, length: source.length))
        let selected = validSelection.length > 0
            ? source.substring(with: validSelection)
            : "<caret at UTF-16 offset \(validSelection.location)>"
        let prompt = """
        USER INSTRUCTION:
        \(instruction)

        ACTIVE SELECTION:
        \(selected)

        CURRENT FILE:
        <file>
        \(file)
        </file>
        """

        let response = try await session.respond(
            to: prompt,
            generating: CodeEditProposal.self
        )

        return response.content
    }

    func complete(file: String, caretUTF16: Int, language: EditorLanguage) async -> String {
        guard model.isAvailable else { return "" }
        let source = file as NSString
        let offset = min(caretUTF16, source.length)
        let session = LanguageModelSession(model: model) {
            "Complete source at the cursor. Return only the smallest useful insertion and never Markdown fences."
        }
        let symbols = TreeSitterContext.symbols(in: file, language: language).prefix(80).joined(separator: ", ")
        do {
            let response = try await session.respond(to: "Language: \(language.rawValue)\nVISIBLE SYMBOLS: \(symbols)\nBEFORE:\n\(source.substring(to: offset).suffix(6000))\n<CURSOR>\nAFTER:\n\(source.substring(from: offset).prefix(2000))")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return "" }
    }
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
