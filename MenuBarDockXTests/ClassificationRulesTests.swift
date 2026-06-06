import XCTest

/// `ClassificationRulesManager` の照合ロジックを検証する。
///
/// 照合は純粋関数 `match(bundleID:rules:prefixRules:)` に切り出してあり、
/// バンドル/ファイルシステムに依存せずテストできる。
/// 仕様: 完全一致を優先し、なければプレフィックス一致、どちらもなければ nil。
final class ClassificationRulesTests: XCTestCase {

    private let rules = [
        ClassificationRule(bundleID: "com.docker.docker", category: "開発"),
        ClassificationRule(bundleID: "com.dropbox.client2", category: "クラウド"),
    ]
    private let prefixRules = [
        PrefixRule(prefix: "com.apple.", category: "システム"),
        PrefixRule(prefix: "com.jetbrains.", category: "開発"),
    ]

    func testExactMatch() {
        let r = ClassificationRulesManager.match(
            bundleID: "com.docker.docker", rules: rules, prefixRules: prefixRules)
        XCTAssertEqual(r, "開発")
    }

    func testPrefixMatch() {
        let r = ClassificationRulesManager.match(
            bundleID: "com.jetbrains.toolbox", rules: rules, prefixRules: prefixRules)
        XCTAssertEqual(r, "開発")
    }

    func testExactMatchTakesPrecedenceOverPrefix() {
        // "com.apple.special" はプレフィックス "com.apple." に一致するが、
        // 完全一致ルールがあればそちらが優先される。
        let withExact = rules + [ClassificationRule(bundleID: "com.apple.special", category: "ユーティリティ")]
        let r = ClassificationRulesManager.match(
            bundleID: "com.apple.special", rules: withExact, prefixRules: prefixRules)
        XCTAssertEqual(r, "ユーティリティ")
    }

    func testNoMatchReturnsNil() {
        let r = ClassificationRulesManager.match(
            bundleID: "io.unknown.app", rules: rules, prefixRules: prefixRules)
        XCTAssertNil(r)
    }

    func testNilBundleIDReturnsNil() {
        let r = ClassificationRulesManager.match(
            bundleID: nil, rules: rules, prefixRules: prefixRules)
        XCTAssertNil(r)
    }

    func testCategoryNameMapsToPresetUUID() {
        // 自動分類で使う「カテゴリ名 → プリセット UUID」マッピングの健全性。
        // match が返す名前は必ずプリセットの UUID に解決できなければならない。
        let name = ClassificationRulesManager.match(
            bundleID: "com.docker.docker", rules: rules, prefixRules: prefixRules)
        let id = Category.presets.first(where: { $0.name == name })?.id
        XCTAssertNotNil(id)
        XCTAssertEqual(Category.presets.first(where: { $0.id == id })?.name, "開発")
    }
}
