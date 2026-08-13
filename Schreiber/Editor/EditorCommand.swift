import UIKit

enum EditorCommand {
    case indent
    case outdent
    case escape
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveBeginning
    case moveEnd
    case deleteBackward
    case copy
    case paste
    case selectAll
    case closeStructure
    case acceptCompletion
    case alternativeCompletion
    case find
    case ai
    case toggleSymbolsKeyboard
    case snippets
    case insert(String)
}

struct EditorModifierState: OptionSet, Hashable {
    let rawValue: Int

    static let shift = EditorModifierState(rawValue: 1 << 0)
    static let control = EditorModifierState(rawValue: 1 << 1)
    static let option = EditorModifierState(rawValue: 1 << 2)
    static let command = EditorModifierState(rawValue: 1 << 3)
}

enum EditorToolAction {
    case command(EditorCommand)
    case modifier(EditorModifierState)
    case find(String, Int)
    case replace(String, String, Int, Bool)
}

extension Notification.Name {
    static let editorToolAction = Notification.Name("Schreiber.EditorToolAction")
}
