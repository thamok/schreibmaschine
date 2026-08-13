import Foundation
import Observation

@MainActor
@Observable
final class EditorViewModel {
    var text = """
    // Schreiber
    // Open a source file or start typing.

    """

    var documentURL: URL?
    var errorMessage: String?

    var displayName: String {
        documentURL?.lastPathComponent ?? "Schreiber"
    }

    func open(_ url: URL) async {
        let accessGranted = url.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            text = try String(contentsOf: url, encoding: .utf8)
            documentURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        guard let documentURL else {
            return
        }

        let accessGranted = documentURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                documentURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try text.write(to: documentURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
