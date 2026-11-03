import XCTest
@testable import RecorderCore

/// Проверка обновлений (FR-27, ADR-007): разбор фиктивных ответов, без сети.
final class UpdateCheckTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testParseTakesOnlyTagAndPage() throws {
        let release = try UpdateCheck.parse(json("""
            {"tag_name":"v1.2.0","html_url":"https://github.com/o/r/releases/tag/v1.2.0","body":"secret","assets":[]}
            """))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.pageURL?.absoluteString, "https://github.com/o/r/releases/tag/v1.2.0")
    }

    func testPageOnlyOnGitHub() throws {
        let other = try UpdateCheck.parse(json(#"{"tag_name":"1.0.1","html_url":"https://evil.example/x"}"#))
        XCTAssertNil(other.pageURL)
        let http = try UpdateCheck.parse(json(#"{"tag_name":"1.0.1","html_url":"http://github.com/o/r"}"#))
        XCTAssertNil(http.pageURL)
        let sub = try UpdateCheck.parse(json(#"{"tag_name":"1.0.1","html_url":"https://github.com.evil.example/"}"#))
        XCTAssertNil(sub.pageURL)
        let none = try UpdateCheck.parse(json(#"{"tag_name":"1.0.1"}"#))
        XCTAssertNil(none.pageURL)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try UpdateCheck.parse(json("not json"))) { XCTAssertEqual($0 as? UpdateCheck.ParseError, .notJSON) }
        XCTAssertThrowsError(try UpdateCheck.parse(json("[]"))) { XCTAssertEqual($0 as? UpdateCheck.ParseError, .notJSON) }
        XCTAssertThrowsError(try UpdateCheck.parse(json(#"{"name":"x"}"#))) { XCTAssertEqual($0 as? UpdateCheck.ParseError, .missingTag) }
        XCTAssertThrowsError(try UpdateCheck.parse(json(#"{"tag_name":"v1.2-beta"}"#))) {
            XCTAssertEqual($0 as? UpdateCheck.ParseError, .badVersion("v1.2-beta"))
        }
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))   // по числам, не по строке
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.0.9", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("abc", than: "0.1.0"))
    }

    func testOutcome() {
        let newer = json(#"{"tag_name":"v0.2.0","html_url":"https://github.com/o/r/releases/tag/v0.2.0"}"#)
        guard case .available(let release, let installed) = UpdateCheck.outcome(status: 200, data: newer, installed: "0.1.0") else {
            return XCTFail()
        }
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(installed, "0.1.0")
        XCTAssertEqual(UpdateCheck.outcome(status: 200, data: json(#"{"tag_name":"v0.1.0"}"#), installed: "0.1.0"),
                       .upToDate(installed: "0.1.0"))
        XCTAssertEqual(UpdateCheck.outcome(status: 404, data: Data(), installed: "0.1.0"), .failed("релиз не найден (ответ 404)"))
        XCTAssertEqual(UpdateCheck.outcome(status: 403, data: Data(), installed: "0.1.0"), .failed("ответ сервера 403"))
        XCTAssertEqual(UpdateCheck.outcome(status: 200, data: json("<html>"), installed: "0.1.0"), .failed("неожиданный ответ сервера"))
    }

    func testRequestURL() {
        XCTAssertNil(UpdateCheck.latestReleaseURL(owner: "", repository: "r"))
        XCTAssertEqual(UpdateCheck.latestReleaseURL(owner: "o", repository: "r")?.absoluteString,
                       "https://api.github.com/repos/o/r/releases/latest")
    }

    func testUpdateCommand() {
        let path = "/Volumes/Data/AI Recorder/source"
        XCTAssertEqual(UpdateCheck.updateCommand(sourcePath: path + "\n").command,
                       "cd \"\(path)\" && git pull && ./install.sh")
        XCTAssertNil(UpdateCheck.updateCommand(sourcePath: path).hint)
        let none = UpdateCheck.updateCommand(sourcePath: nil)
        XCTAssertEqual(none.command, "git pull && ./install.sh")
        XCTAssertEqual(none.hint, "выполните в папке проекта")
        XCTAssertEqual(UpdateCheck.updateCommand(sourcePath: "  ").command, "git pull && ./install.sh")
        // кавычки и $ в пути не ломают команду
        XCTAssertEqual(UpdateCheck.updateCommand(sourcePath: #"/a "b" $c"#).command, #"cd "/a \"b\" \$c" && git pull && ./install.sh"#)
    }
}
