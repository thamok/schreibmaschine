import SwiftUI

struct AIAssistantBar: View {
    @Bindable var editor: EditorViewModel

    @State private var instruction = ""
    @State private var proposal: CodeEditProposal?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 8) {
            if let proposal {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proposed edit")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(proposal.summary)
                            .font(.subheadline)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button("Reject", role: .cancel) {
                        self.proposal = nil
                    }

                    Button("Apply") {
                        editor.text = proposal.replacement
                        self.proposal = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                TextField(
                    "Ask the on-device model to edit this file…",
                    text: $instruction,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit(runEdit)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Run", systemImage: "sparkles", action: runEdit)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            instruction
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.bar)
    }

    private func runEdit() {
        let request = instruction.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !request.isEmpty, !isWorking else {
            return
        }

        isWorking = true

        Task {
            defer { isWorking = false }

            do {
                proposal = try await FoundationModelService.shared.proposeEdit(
                    file: editor.text,
                    instruction: request
                )
                instruction = ""
            } catch {
                editor.errorMessage = error.localizedDescription
            }
        }
    }
}
