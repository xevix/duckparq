import AppKit
import SwiftUI

/// The value field of a filter that offers completions.
///
/// An `NSTextField` rather than SwiftUI's `TextField` for one reason: Tab. In a
/// SwiftUI text field it belongs to the focus system, which moves to the next
/// control before any view modifier is consulted — there is no supported way to
/// see it first. AppKit routes it through the field editor as `insertTab:`,
/// which a delegate can answer, and answering it is the whole point of the
/// control: Tab takes the first completion.
///
/// Returning false from `onTab` leaves Tab doing its usual job, so when there is
/// nothing to complete the key still moves focus rather than going nowhere.
struct FilterValueField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Accept the first completion. True when it took the key.
    var onTab: () -> Bool
    /// Return, which applies the filter — the same as clicking Apply.
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        // The completion list is the only completion here. macOS's own would
        // draw a second menu over this one, offering words rather than values.
        field.isAutomaticTextCompletionEnabled = false
        context.coordinator.takeFocus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder

        // Only when the change came from outside — accepting a completion. The
        // caret goes to the end, because what was just inserted is a whole value
        // and the next thing typed continues past it.
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }

        // Retried here because `makeNSView` may have run before the popover had
        // a window to be first responder in. Idempotent, and gives up once the
        // field has had its turn — re-taking focus on a later update would
        // yank the caret back mid-edit.
        context.coordinator.takeFocus(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Main-actor isolated: every member touches the field, and AppKit delivers
    /// these callbacks on the main thread regardless.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterValueField
        private var hasTakenFocus = false

        init(_ parent: FilterValueField) {
            self.parent = parent
        }

        /// Put the caret in the field, once. A popover holding a text field
        /// exists to type in, and Tab-to-complete is only reachable from there.
        ///
        /// On the next runloop turn rather than now: this is called from inside
        /// SwiftUI's update pass, and making a view first responder there sends
        /// AppKit editing notifications back into a view that is mid-update.
        func takeFocus(_ field: NSTextField) {
            guard !hasTakenFocus else { return }
            DispatchQueue.main.async { [weak field] in
                guard !self.hasTakenFocus, let field, let window = field.window else { return }
                self.hasTakenFocus = true
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// A filter value is matched against stored text exactly, so the
        /// substitutions that make prose nicer make this wrong: smart quotes
        /// would turn a value containing `'` into one containing `’`, and the
        /// spell checker would underline every identifier in the column.
        ///
        /// Set on the field editor, which is the window's and shared, so it has
        /// to be set each time this field starts editing rather than once.
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView
            else { return }
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}
