import AppKit
import DuckParqCore
import SwiftUI

/// The SQL editing surface.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor`, because `TextEditor`
/// renders a plain `String` and gives no way to attach colour to ranges of it.
///
/// Beyond highlighting, a plain text view is the right control for SQL for a
/// duller reason: macOS text substitutions are off here. Smart quotes would
/// turn `'abc'` into `’abc’` as you type it, which DuckDB rejects.
struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    /// Which of DuckDB's two palettes to use.
    var isDark: Bool
    /// Flipped once the engine's keyword list replaces the bootstrap one, so
    /// the view re-highlights with the full set.
    var keywordsLoaded: Bool

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    /// Above this, highlighting is skipped rather than run on every keystroke.
    /// Hand-written queries are nowhere near it; a pasted dump might be.
    private static let highlightLimit = 200_000

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.backgroundColor = .textBackgroundColor

        // Every one of these mangles SQL if left on: straight quotes become
        // curly, `--` becomes an em dash, and the spell checker underlines
        // every identifier in the file.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        textView.string = text
        context.coordinator.highlight(textView, isDark: isDark, keywordsLoaded: keywordsLoaded)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        // Only replace the contents when the change came from outside — seeding
        // from the view, loading a .sql file. Assigning the same string back
        // would drop the selection and the undo stack on every keystroke.
        if textView.string != text {
            let caret = textView.selectedRange().location
            textView.string = text
            let clamped = min(caret, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
        context.coordinator.highlight(textView, isDark: isDark, keywordsLoaded: keywordsLoaded)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Main-actor isolated: every member touches the text view, and AppKit
    /// delivers `textDidChange` on the main thread regardless.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextView
        /// What the last highlight pass was for. Highlighting is idempotent, so
        /// this only exists to skip redundant work — the view is asked to
        /// re-highlight from both `textDidChange` and `updateNSView`.
        private var lastPass: (text: String, isDark: Bool, keywordsLoaded: Bool)?

        init(_ parent: SQLTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView, isDark: parent.isDark, keywordsLoaded: parent.keywordsLoaded)
        }

        func highlight(_ textView: NSTextView, isDark: Bool, keywordsLoaded: Bool) {
            let text = textView.string
            if let lastPass, lastPass == (text, isDark, keywordsLoaded) { return }
            lastPass = (text, isDark, keywordsLoaded)

            guard let storage = textView.textStorage else { return }
            let palette = SQLPalette.palette(dark: isDark)
            let whole = NSRange(location: 0, length: (text as NSString).length)
            let plain: [NSAttributedString.Key: Any] = [
                .font: SQLTextView.font,
                .foregroundColor: NSColor.labelColor,
            ]

            storage.beginEditing()
            defer { storage.endEditing() }

            storage.setAttributes(plain, range: whole)
            // Typing at the end of the document inherits the attributes at the
            // insertion point, which would carry a colour into the next token
            // until the next pass caught up.
            textView.typingAttributes = plain

            guard whole.length <= SQLTextView.highlightLimit else { return }

            for token in SQLSyntax.tokenize(text, keywords: SQLKeywords.shared.all) {
                let range = NSRange(location: token.location, length: token.length)
                guard NSMaxRange(range) <= whole.length else { continue }
                if let color = SQLTheme.color(for: token.kind, in: palette) {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
                if SQLTheme.isBold(token.kind, in: palette) {
                    storage.addAttribute(.font, value: SQLTextView.boldFont, range: range)
                }
            }
        }
    }
}
