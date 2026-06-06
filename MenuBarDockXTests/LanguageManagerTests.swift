import XCTest

/// `LanguageManager` と `L()` ヘルパーの言語切替を検証する。
///
/// 言語設定は UserDefaults("appLanguage") に永続化される。
/// テストは元の値を保存・復元してグローバル状態を汚さない。
final class LanguageManagerTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = LanguageManager.shared.current
    }

    override func tearDown() {
        LanguageManager.shared.current = savedLanguage
        super.tearDown()
    }

    func testAppLanguageRawValues() {
        XCTAssertEqual(AppLanguage.english.rawValue, "en")
        XCTAssertEqual(AppLanguage.japanese.rawValue, "ja")
    }

    func testLReturnsEnglishWhenEnglish() {
        LanguageManager.shared.current = .english
        XCTAssertTrue(LanguageManager.shared.isEnglish)
        XCTAssertEqual(L("Quit", "終了"), "Quit")
    }

    func testLReturnsJapaneseWhenJapanese() {
        LanguageManager.shared.current = .japanese
        XCTAssertFalse(LanguageManager.shared.isEnglish)
        XCTAssertEqual(L("Quit", "終了"), "終了")
    }

    func testCurrentPersistsAcrossReads() {
        LanguageManager.shared.current = .japanese
        XCTAssertEqual(LanguageManager.shared.current, .japanese)
        LanguageManager.shared.current = .english
        XCTAssertEqual(LanguageManager.shared.current, .english)
    }
}
