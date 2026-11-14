import SwiftUI

extension View {
    /// Shows `full` as a tooltip, but only while this view is truncated: narrower than it would be laid out
    /// on one line at its ideal size. Apply it to the text itself (or an HStack of texts), before any frame
    /// that widens it. For text that wraps over several lines before it truncates, use `.help` instead: this
    /// compares one-line widths, so it would call wrapped-but-whole text truncated.
    func truncationHelp(_ full: String) -> some View { modifier(TruncationHelp(full: full)) }
}

private struct TruncationHelp: ViewModifier {
    let full: String
    @State private var truncated = false

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { shown in
                    // The same view at its ideal size, never drawn: wider than what's shown means truncated.
                    content.fixedSize().hidden().allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .background {
                            GeometryReader { ideal in
                                Color.clear.preference(key: TruncatedKey.self,
                                                       value: ideal.size.width > shown.size.width + 0.5)
                            }
                        }
                }
            }
            .onPreferenceChange(TruncatedKey.self) { truncated = $0 }
            .transformPreference(TruncatedKey.self) { $0 = false }   // don't leak into an enclosing one
            .help(truncated ? full : "")
    }
}

private struct TruncatedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
