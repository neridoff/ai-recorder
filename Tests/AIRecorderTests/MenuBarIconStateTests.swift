import XCTest
@testable import AIRecorder

/// Состояние значка меню-бара (E4.2, дизайн значков ai-recorder-icons.md в документах проекта).
final class MenuBarIconStateTests: XCTestCase {
    private func icon(_ phase: RecorderController.Phase, _ transcription: RecorderController.Transcription,
                      failure: Bool = false) -> MenuBarIconState {
        .resolve(phase: phase, transcription: transcription, showsFailure: failure)
    }

    func testIdleWithoutProcessing() {
        XCTAssertEqual(icon(.idle, .none), .idle)
        XCTAssertEqual(icon(.idle, .done(segments: 3, speakers: 1)), .idle)
    }

    func testStartingAndStoppingShowRecording() {
        for phase in [RecorderController.Phase.starting, .recording, .stopping] {
            XCTAssertEqual(icon(phase, .none), .recording)
        }
        XCTAssertEqual(icon(.paused, .none), .paused)
    }

    func testRecordingWinsOverProcessingAndError() {
        XCTAssertEqual(icon(.recording, .running(0.4)), .recording)
        XCTAssertEqual(icon(.paused, .diarizing(0.1)), .paused)
        XCTAssertEqual(icon(.recording, .failed("x"), failure: true), .recording)
        XCTAssertEqual(icon(.paused, .failed("x"), failure: true), .paused)
    }

    func testProcessingWinsOverError() {
        XCTAssertEqual(icon(.idle, .running(0)), .processing)
        XCTAssertEqual(icon(.idle, .diarizing(0.5)), .processing)
        // флаг ещё не сброшен, но обработка уже идёт
        XCTAssertEqual(icon(.idle, .running(0), failure: true), .processing)
    }

    func testErrorOnlyWhenFailureShown() {
        XCTAssertEqual(icon(.idle, .failed("нет модели"), failure: true), .error)
        // отмена или ошибку сбросила новая запись: значок «Ожидание», текст в меню остаётся
        XCTAssertEqual(icon(.idle, .failed("расшифровка отменена"), failure: false), .idle)
        XCTAssertEqual(icon(.idle, .done(segments: 1, speakers: nil), failure: true), .idle)
    }

    func testOnlyProcessingAnimates() {
        XCTAssertEqual(MenuBarIconState.processing.frameCount, 2)
        for state in [MenuBarIconState.idle, .recording, .paused, .error] {
            XCTAssertEqual(state.frameCount, 1)
        }
    }
}
