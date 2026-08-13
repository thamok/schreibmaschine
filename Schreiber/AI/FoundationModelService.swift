import Foundation
import FoundationModels

actor FoundationModelService {
    static let shared = FoundationModelService()

    private let model = SystemLanguageModel.default

    var isAvailable: Bool {
        model.isAvailable
    }

    func proposeEdit(
        file: String,
        instruction: String
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

        let prompt = """
        USER INSTRUCTION:
        \(instruction)

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
