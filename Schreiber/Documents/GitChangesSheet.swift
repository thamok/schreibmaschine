import SwiftUI
import WebKit

struct GitChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: GitSnapshot
    let projectName: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                VStack(spacing: 2) {
                    Text("Unstaged").font(.headline)
                    Text("+\(snapshot.additions) −\(snapshot.deletions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()
            GitDiffWebView(snapshot: snapshot, projectName: projectName)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct GitDiffWebView: UIViewRepresentable {
    let snapshot: GitSnapshot
    let projectName: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(Self.html(snapshot: snapshot, projectName: projectName), baseURL: nil)
    }

    private static func html(snapshot: GitSnapshot, projectName: String) -> String {
        let cards = snapshot.files.map { file in
            let lines = file.lines.prefix(240).map { line in
                let kind = line.marker == "+" || line.marker == ">" ? "add" : (line.marker == "-" || line.marker == "<" ? "del" : "ctx")
                return "<div class='line \(kind)'><span class='number'>\(line.number)</span><span class='marker'>\(escape(line.marker))</span><code>\(escape(line.content))</code></div>"
            }.joined()
            let directory = (file.path as NSString).deletingLastPathComponent
            return """
            <details class="card">
              <summary><span><b>\(escape((file.path as NSString).lastPathComponent))</b><small>\(escape(directory == "." ? projectName : directory))</small></span><span class="counts"><i>+\(file.additions)</i> <em>−\(file.deletions)</em></span></summary>
              <div class="diff">\(lines)</div>
            </details>
            """
        }.joined()
        let empty = snapshot.files.isEmpty ? "<div class='empty'>Working tree clean</div>" : ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}body{margin:0;padding:16px;background:#1c1c1e;color:#f5f5f7}.card{margin:0 0 12px;background:#2c2c2e;border-radius:14px;overflow:hidden}.card summary{list-style:none;display:flex;align-items:center;justify-content:space-between;min-height:64px;padding:12px 15px;cursor:pointer}.card summary::-webkit-details-marker{display:none}summary b,summary small{display:block}summary small{color:#aaa;font-size:12px;margin-top:3px}.counts{font:14px ui-monospace,SFMono-Regular,Menlo,monospace}.counts i{color:#34c759;font-style:normal}.counts em{color:#ff375f;font-style:normal}.diff{background:#090909;padding:8px 0;overflow:auto}.line{display:flex;min-height:20px;white-space:pre;font:12px/20px ui-monospace,SFMono-Regular,Menlo,monospace}.line.add{background:#153c24}.line.del{background:#481d25}.number{width:36px;text-align:right;color:#777;padding-right:8px;user-select:none}.marker{width:18px;color:#aaa}.line.add .marker{color:#30d158}.line.del .marker{color:#ff453a}code{padding-right:12px}.empty{text-align:center;color:#999;padding:80px 20px}</style></head><body>\(cards)\(empty)</body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
