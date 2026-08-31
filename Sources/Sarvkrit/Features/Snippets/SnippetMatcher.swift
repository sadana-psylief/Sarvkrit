import Foundation

/// Decides whether what has just been typed completes a snippet trigger.
///
/// Pure, and holding the buffer itself, so the whole of this feature's behaviour — including every
/// privacy rule — is table-testable without a live event tap. That matters more here than anywhere
/// else in the app: this is the one feature that sees every character the user types, so "what does
/// it hold, and for how long" has to be checkable rather than argued about.
struct SnippetMatcher {

    /// What the feature should do about the keystroke just seen.
    enum Decision: Equatable {
        case ignore
        /// Delete `deleteCount` characters, then type `expansion`.
        ///
        /// `deleteCount` counts the characters the *user typed*, which for `.wordBoundary` includes
        /// the delimiter that triggered it — the delimiter is re-emitted as part of the expansion so
        /// the user doesn't lose the space they typed.
        case expand(snippet: Snippet, deleteCount: Int, expansion: String)
    }

    /// Everything that ends the current word and therefore the buffer's usefulness.
    enum Interruption {
        /// A different app came forward.
        case appChanged
        /// The caret moved somewhere we can't predict — arrows, Return, Tab, Escape, a click.
        case caretMoved
        /// A shortcut, not typing.
        case modifierChord
        /// Nothing typed for a while.
        case idle
        /// A password field took focus, or the feature was switched off.
        case secureInput
    }

    /// Held characters. **Never persisted, never logged.**
    ///
    /// `private(set)` so only this type can grow it, and capped in `append` at
    /// `longestTrigger + 2` — structurally incapable of holding a sentence, which is a far stronger
    /// guarantee than a promise not to read one.
    ///
    /// **Why +2, stated precisely, because widening this is a privacy cost and should be
    /// justified rather than convenient:**
    ///
    /// - **+1 for the delimiter.** A `.wordBoundary` trigger completes *on* a delimiter, so the
    ///   delimiter has to fit alongside the trigger.
    /// - **+1 for one character of left context.** Without it `myaddr ` is indistinguishable from
    ///   `addr `: the cap would have trimmed `my` away, leaving exactly the trigger, and the
    ///   expansion would fire in the middle of a longer word — the precise false-fire that
    ///   `.wordBoundary` exists to prevent.
    ///
    /// Delimiters are kept in the buffer rather than clearing it, for two reasons: that left
    /// context, and the fact that `;` is itself punctuation — clearing on delimiters meant a `;addr`
    /// trigger could never accumulate at all.
    private(set) var buffer: String = ""

    private var snippets: [Snippet] = []
    private var longestTrigger: Int = 0
    /// Cached so it isn't recomputed per keystroke.
    private var prefixSnippets: [Snippet] = []
    private var wordBoundarySnippets: [Snippet] = []

    /// Rebuilt whenever the snippet table changes.
    mutating func setSnippets(_ snippets: [Snippet]) {
        self.snippets = snippets.filter { $0.isEnabled && $0.validationProblem == nil }
        longestTrigger = self.snippets.map(\.trigger.count).max() ?? 0
        // Longest first, once: with both `;a` and `;ab` defined, a shorter trigger checked first
        // would fire on the way to the longer one and the longer could never be reached.
        prefixSnippets = self.snippets.filter { $0.style == .prefix }
            .sorted { $0.trigger.count > $1.trigger.count }
        wordBoundarySnippets = self.snippets.filter { $0.style == .wordBoundary }
            .sorted { $0.trigger.count > $1.trigger.count }
        // A shorter table means the old buffer may exceed the new cap.
        trimToCap()
    }

    /// The cap, exposed so a test can assert the buffer never exceeds it. Zero with no snippets —
    /// an enabled feature with an empty table holds nothing at all.
    var capacity: Int { longestTrigger == 0 ? 0 : longestTrigger + 2 }

    mutating func interrupt(_ reason: Interruption) {
        _ = reason   // Every reason clears; the cases exist to make call sites self-documenting.
        buffer.removeAll(keepingCapacity: false)
    }

    /// Feeds one typed character.
    ///
    /// - Parameter character: what the keystroke produced. Pass nil for a key that types nothing but
    ///   doesn't move the caret either (a bare modifier press), which neither appends nor clears.
    mutating func typed(_ character: Character?, context: SnippetPattern.Context = .init()) -> Decision {
        guard let character else { return .ignore }
        guard longestTrigger > 0 else { return .ignore }

        append(character)

        // A prefix trigger can end on any character, including a delimiter.
        if let decision = matchPrefix(context: context) {
            buffer.removeAll(keepingCapacity: false)
            return decision
        }

        // A word-boundary trigger completes only on a delimiter.
        if character.isSnippetDelimiter,
           let decision = matchWordBoundary(delimiter: character, context: context) {
            buffer.removeAll(keepingCapacity: false)
            return decision
        }

        return .ignore
    }

    // MARK: - Matching

    private func matchPrefix(context: SnippetPattern.Context) -> Decision? {
        for snippet in prefixSnippets where buffer.hasSuffix(snippet.trigger) {
            return .expand(
                snippet: snippet,
                deleteCount: snippet.trigger.count,
                expansion: SnippetPattern.expand(snippet.expansion, context: context)
            )
        }
        return nil
    }

    private func matchWordBoundary(
        delimiter: Character,
        context: SnippetPattern.Context
    ) -> Decision? {
        // The delimiter is already in the buffer; the trigger is what sits immediately before it.
        let beforeDelimiter = buffer.dropLast()

        for snippet in wordBoundarySnippets {
            guard beforeDelimiter.hasSuffix(snippet.trigger) else { continue }

            // What precedes the trigger decides whether this is a word of its own. Nothing at all
            // means the trigger is everything we hold, which — given the +1 of left context — means
            // it really was the start of the typing. Anything else must be a delimiter, or we are
            // looking at the tail of a longer word.
            let preceding = beforeDelimiter.dropLast(snippet.trigger.count).last
            guard preceding.map(\.isSnippetDelimiter) ?? true else { continue }

            return .expand(
                snippet: snippet,
                // +1 for the delimiter, which the expansion re-emits so the user keeps their space.
                deleteCount: snippet.trigger.count + 1,
                expansion: SnippetPattern.expand(snippet.expansion, context: context)
                    + String(delimiter)
            )
        }
        return nil
    }

    // MARK: - Buffer

    private mutating func append(_ character: Character) {
        buffer.append(character)
        trimToCap()
    }

    private mutating func trimToCap() {
        let cap = capacity
        guard cap > 0 else {
            buffer.removeAll(keepingCapacity: false)
            return
        }
        while buffer.count > cap {
            buffer.removeFirst()
        }
    }
}

extension Character {
    /// What ends a word for snippet purposes.
    ///
    /// Whitespace and punctuation both count: people type `addr,` and `addr.` as readily as
    /// `addr `, and a trigger that only fired on space would feel arbitrarily broken.
    var isSnippetDelimiter: Bool {
        isWhitespace || isPunctuation || isSymbol || isNewline
    }
}
