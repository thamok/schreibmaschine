import FoundationModels

@Generable(description: "A proposed source-code edit.")
struct CodeEditProposal {
    @Guide(description: "A concise description of what changed.")
    var summary: String

    @Guide(description: "The complete replacement contents of the source file. Return code only.")
    var replacement: String
}
