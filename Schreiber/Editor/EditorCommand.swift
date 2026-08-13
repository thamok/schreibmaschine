import UIKit

enum EditorCommand {
    case indent
    case outdent
    case escape
    case moveLeft
    case moveRight
    case insert(String)
}

struct EditorModifierState: OptionSet, Hashable {
    let rawValue: Int

    static let shift = EditorModifierState(rawValue: 1 << 0)
    static let control = EditorModifierState(rawValue: 1 << 1)
    static let option = EditorModifierState(rawValue: 1 << 2)
    static let command = EditorModifierState(rawValue: 1 << 3)
}
