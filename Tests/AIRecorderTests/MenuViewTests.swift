import XCTest
@testable import AIRecorder

/// Верхний блок меню (E5.1, ADR-006 решение 8): запуска расшифровки там нет, только
/// «Отменить расшифровку» и «Показать расшифровку в Finder».
final class MenuViewTests: XCTestCase {
    func testTopBlockHasNoLaunchButtons() {
        let states: [RecorderController.Transcription] = [.none, .running(0.3), .diarizing(0.5),
                                                          .done(segments: 3, speakers: 1), .empty, .failed("x")]
        for state in states {
            let titles = MenuView.processingActions(state).map(\.rawValue)
            XCTAssertTrue(titles.allSatisfy { ["Отменить расшифровку", "Показать расшифровку в Finder"].contains($0) }, "\(state)")
            XCTAssertFalse(titles.contains { $0.contains("Расшифровать") || $0.contains("Повторить") }, "\(state)")
        }
        XCTAssertEqual(MenuView.processingActions(.running(0)), [.cancel])
        XCTAssertEqual(MenuView.processingActions(.done(segments: 1, speakers: 1)), [.reveal])
        XCTAssertEqual(MenuView.processingActions(.failed("x")), [])
    }

    func testEmptyResultDoesNotShowErrorIcon() {
        XCTAssertEqual(MenuBarIconState.resolve(phase: .idle, transcription: .empty, showsFailure: false), .idle)
    }
}
