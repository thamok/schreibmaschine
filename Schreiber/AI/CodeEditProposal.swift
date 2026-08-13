import FoundationModels

@Generable(description: "A proposed source-code edit.")
struct CodeEditProposal {
    @Guide(description: "A concise description of what changed.")
    var summary: String

    @Guide(description: "Only the replacement for the selected source range. Return code only.")
    var replacement: String
}
