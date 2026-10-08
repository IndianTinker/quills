import XCTest
@testable import quills

final class TranscriptEchoFilterTests: XCTestCase {
    private func span(_ speaker: String, _ text: String, _ start: Int = 1000, _ end: Int = 5000) -> Transcript.Segment {
        .init(speaker: speaker, start_ms: start, end_ms: end, text: text)
    }

    func testRemovesSimultaneousEchoAndKeepsSystemOriginal() {
        let text = "Great, I love that question."
        let input = [span("them", text), span("me", text, 1097, 5097)]
        let output = TranscriptEchoFilter.removingEcho(from: input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.speaker, "them")
    }

    func testKeepsLaterRepetitionShortAcknowledgmentsAndDifferentSpeech() {
        let input = [
            span("them", "Great, I love that question."),
            span("me", "Great, I love that question.", 6000, 10000),
            span("them", "Yes, of course."), span("me", "Yes, of course."),
            span("me", "I have a different question about pricing.")
        ]
        XCTAssertEqual(TranscriptEchoFilter.removingEcho(from: input).count, input.count)
    }

    func testMatchesDifferentSentenceBoundariesAndRecognitionVariation() {
        let input = [
            span("them", "We can meet tomorrow morning.", 1000, 3000),
            span("them", "Then review all the project details together.", 3000, 6000),
            span("me", "We can meet tomorrow morning then review all the project detail together.", 1150, 6150)
        ]
        XCTAssertEqual(TranscriptEchoFilter.removingEcho(from: input).count, 2)
    }

    func testKeepsUniqueMicContributionAndInsufficientTimeCoverage() {
        let input = [
            span("them", "Great, I love that question."),
            span("me", "Great, I love that question. My concern is the budget."),
            span("me", "Great, I love that question.", 1000, 15000)
        ]
        XCTAssertEqual(TranscriptEchoFilter.removingEcho(from: input).count, 3)
    }

    func testPreservesSameTrackRepetitionsAndUnicode() {
        let text = "Así que bueno, cosas que pasan."
        let input = [span("them", text), span("them", text, 6000, 10000),
                     span("me", "asi que bueno cosas que pasan", 1131, 5131)]
        let output = TranscriptEchoFilter.removingEcho(from: input)
        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output.allSatisfy { $0.speaker == "them" })
    }

    func testSystemOnlyAndMicOnlyAreUnchanged() {
        for speaker in ["me", "them"] {
            let input = [span(speaker, "Great, I love that question.")]
            XCTAssertEqual(TranscriptEchoFilter.removingEcho(from: input).count, 1)
        }
    }
}
