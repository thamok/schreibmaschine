import UIKit

enum EditorTypeface: String, CaseIterable, Identifiable {
    case systemMono, sfMono, menlo, courierNew
    var id: String { rawValue }
    var title: String {
        switch self { case .systemMono: "System Monospace"; case .sfMono: "SF Mono"; case .menlo: "Menlo"; case .courierNew: "Courier New" }
    }
    func font(size: CGFloat) -> UIFont {
        switch self {
        case .systemMono: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfMono: UIFont(name: "SFMono-Regular", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo: UIFont(name: "Menlo-Regular", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .courierNew: UIFont(name: "CourierNewPSMT", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// Editor colours deliberately stay independent of the surrounding SwiftUI colour scheme.
/// This keeps a source file legible when a project uses a high-contrast code theme.
enum EditorTheme: String, CaseIterable, Identifiable, Sendable {
    case codex, vercel, cloudflare, midnight, copilot

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var palette: EditorPalette {
        switch self {
        case .codex:
            EditorPalette(background: .init(hex: 0x101114), text: .init(hex: 0xE6E6E6), caret: .init(hex: 0x67E8F9), comment: .init(hex: 0x7C8595), string: .init(hex: 0xA7F3D0), keyword: .init(hex: 0xC4B5FD), number: .init(hex: 0xFCD34D), type: .init(hex: 0x7DD3FC), selection: .init(hex: 0x26465A))
        case .vercel:
            EditorPalette(background: .init(hex: 0x000000), text: .init(hex: 0xEDEDED), caret: .white, comment: .init(hex: 0x737373), string: .init(hex: 0xA3E635), keyword: .init(hex: 0xFFFFFF), number: .init(hex: 0xF5F5F5), type: .init(hex: 0xD4D4D4), selection: .init(hex: 0x303030))
        case .cloudflare:
            EditorPalette(background: .init(hex: 0x17120F), text: .init(hex: 0xF8EDE3), caret: .init(hex: 0xF6821F), comment: .init(hex: 0xA88F7C), string: .init(hex: 0xF9AE58), keyword: .init(hex: 0xF6821F), number: .init(hex: 0xFCD58A), type: .init(hex: 0xF5C3A7), selection: .init(hex: 0x4D2A18))
        case .midnight:
            EditorPalette(background: .init(hex: 0x0B1020), text: .init(hex: 0xDDE7FF), caret: .init(hex: 0x60A5FA), comment: .init(hex: 0x7180A6), string: .init(hex: 0x86EFAC), keyword: .init(hex: 0xC4B5FD), number: .init(hex: 0xFBBF24), type: .init(hex: 0x7DD3FC), selection: .init(hex: 0x1E3A6B))
        case .copilot:
            EditorPalette(background: .init(hex: 0x0D1117), text: .init(hex: 0xE6EDF3), caret: .init(hex: 0x58A6FF), comment: .init(hex: 0x8B949E), string: .init(hex: 0xA5D6FF), keyword: .init(hex: 0xD2A8FF), number: .init(hex: 0x79C0FF), type: .init(hex: 0xFFA657), selection: .init(hex: 0x1F6FEB))
        }
    }
}

struct EditorPalette: Sendable {
    let background: UIColor
    let text: UIColor
    let caret: UIColor
    let comment: UIColor
    let string: UIColor
    let keyword: UIColor
    let number: UIColor
    let type: UIColor
    let selection: UIColor
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
