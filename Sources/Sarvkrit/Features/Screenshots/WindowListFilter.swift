import Foundation

/// Ordering and filtering for the window picker list.
///
/// Pure, so "typing 'saf' should put Safari first" is a test rather than something to check by
/// opening the picker and typing — the same reason the rest of this feature's decisions are pure.
enum WindowListFilter {

    /// The smallest a window can be and still be something a person meant to capture.
    ///
    /// Measured against what the system actually reports: a status indicator is 28×29 and the
    /// menu bar is 33 points tall, while the smallest real window worth listing — a palette, a
    /// small alert — clears this comfortably.
    static let minimumSize = CGSize(width: 120, height: 90)

    /// Windows worth putting in a list.
    ///
    /// **Stricter than what is capturable**, and deliberately so. Hover-picking happens on a
    /// frozen screen, where whatever you point at is by definition something you can see; a list
    /// has no such grounding, and the raw enumeration is mostly system furniture — the first run
    /// of this offered "Display 1 Backstop", "Menubar", "StatusIndicator" and "underbelly" above
    /// any real window. Three rules remove all of it:
    ///
    /// - **Layer zero.** Ordinary application windows live there; system chrome does not.
    /// - **A real size**, which drops status items and one-line strips.
    /// - **A named owner**, because a row with no application to attribute it to is unreadable
    ///   even when it is genuine.
    static func presentable(_ windows: [CapturableWindow]) -> [CapturableWindow] {
        windows.filter { window in
            guard window.layer == 0 else { return false }
            guard window.frame.width >= minimumSize.width,
                  window.frame.height >= minimumSize.height else { return false }
            guard let app = window.owningAppName, !app.isEmpty else { return false }
            return true
        }
    }

    /// The order windows are offered in.
    ///
    /// Grouped by application, applications in alphabetical order, and each application's windows
    /// by title. **Not by z-order**, which is what `shareableWindows` returns: the list exists to
    /// be read, and a list that reshuffles itself every time you click something else is unusable
    /// for that.
    static func ordered(_ windows: [CapturableWindow]) -> [CapturableWindow] {
        windows.sorted { lhs, rhs in
            let leftApp = lhs.owningAppName ?? ""
            let rightApp = rhs.owningAppName ?? ""
            if leftApp.localizedCaseInsensitiveCompare(rightApp) != .orderedSame {
                return leftApp.localizedCaseInsensitiveCompare(rightApp) == .orderedAscending
            }
            let leftTitle = lhs.title ?? ""
            let rightTitle = rhs.title ?? ""
            if leftTitle.localizedCaseInsensitiveCompare(rightTitle) != .orderedSame {
                return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
            }
            // A stable tie-break, so two untitled windows of one app never swap places between
            // keystrokes and move the selection out from under the arrow keys.
            return lhs.id < rhs.id
        }
    }

    /// Windows matching what has been typed.
    ///
    /// Matches the application name *or* the window title, because people reach for either — "the
    /// Safari one" and "the one about invoices" are both how a window gets described. Empty query
    /// means everything, rather than nothing.
    static func matching(_ query: String, in windows: [CapturableWindow]) -> [CapturableWindow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return windows }
        return windows.filter { window in
            let haystack = [window.owningAppName, window.title].compactMap { $0 }.joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Where the selection lands after moving `delta` rows in a list of `count`.
    ///
    /// Clamped rather than wrapped. Wrapping means holding the down-arrow silently returns you to
    /// the top, and in a picker that takes a screenshot on Return that is a wrong window captured.
    static func moving(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}
