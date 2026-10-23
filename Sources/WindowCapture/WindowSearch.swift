import Foundation

/// ウィンドウ一覧のインクリメンタル検索。
/// 空白区切りの各語がアプリ名・アプリのファイル名・ウィンドウタイトルのどれかに含まれれば一致とする (AND 検索)。
/// 大文字小文字、全角半角、ひらがなとカタカナの違いは無視する。
enum WindowSearch {
    nonisolated static func matches(_ texts: [String], query: String) -> Bool {
        let terms = normalize(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystacks = texts.map(normalize)
        return terms.allSatisfy { term in
            haystacks.contains { $0.contains(term) }
        }
    }

    nonisolated static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}
