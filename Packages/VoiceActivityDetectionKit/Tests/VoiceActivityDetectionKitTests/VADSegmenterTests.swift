import XCTest
@testable import VoiceActivityDetectionKit

final class VADSegmenterTests: XCTestCase {
    func testAllSilenceNeverStartsAndPreRollStaysBounded() throws {
        var segmenter = VADSegmenter(policy: try SyntheticPCMFixture.policy(preRoll: 5))

        for sequence in 0 ..< 100 {
            let events = try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: UInt64(sequence)),
                observation: SyntheticPCMFixture.observation(isSpeech: false)
            )
            XCTAssertTrue(events.isEmpty)
            XCTAssertLessThanOrEqual(segmenter.bufferedPreRollFrameCount, 5)
        }

        XCTAssertFalse(segmenter.isSegmentActive)
        XCTAssertEqual(segmenter.bufferedPreRollFrameCount, 5)
    }

    func testOnsetForwardsExactPreRollOnceWithoutDuplicates() throws {
        var segmenter = VADSegmenter(policy: try SyntheticPCMFixture.policy(preRoll: 5))
        let decisions = [false, false, false, true, true]
        var events: [VADSegmentationEvent] = []
        for (sequence, decision) in decisions.enumerated() {
            events += try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: UInt64(sequence)),
                observation: SyntheticPCMFixture.observation(isSpeech: decision)
            )
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], .segmentStarted(segmentID: 4))
        guard case let .frames(segmentID, frames) = events[1] else {
            return XCTFail("Expected pre-roll frames")
        }
        XCTAssertEqual(segmentID, 4)
        XCTAssertEqual(frames.map(\.sequence), [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(frames.map(\.sequence)).count, frames.count)

        let nextEvents = try segmenter.consume(
            SyntheticPCMFixture.frame(sequence: 5, amplitude: 1_000),
            observation: SyntheticPCMFixture.observation(isSpeech: true)
        )
        XCTAssertEqual(nextEvents, [.frames(segmentID: 4, frames: [try SyntheticPCMFixture.frame(sequence: 5, amplitude: 1_000)])])
    }

    func testGoldenSyntheticTraceForInternalSilenceResumeAndEndpoint() throws {
        var segmenter = VADSegmenter(
            policy: try SyntheticPCMFixture.policy(
                preRoll: 4,
                endpointSilence: 2
            )
        )
        let decisions = [false, false, true, true, false, true, false, false]
        var trace: [String] = []

        for (sequence, decision) in decisions.enumerated() {
            let events = try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: UInt64(sequence)),
                observation: SyntheticPCMFixture.observation(isSpeech: decision)
            )
            trace.append(contentsOf: events.map(traceLine))
        }

        XCTAssertEqual(
            trace,
            [
                "start:3",
                "frames:3:0,1,2,3",
                "frames:3:4",
                "resume:3:1",
                "frames:3:5",
                "frames:3:6",
                "frames:3:7",
                "end:3:silence:2"
            ]
        )
    }

    func testMaximumDurationEndsExactlyOnce() throws {
        var segmenter = VADSegmenter(
            policy: try SyntheticPCMFixture.policy(
                preRoll: 3,
                endpointSilence: 10,
                maximumSegment: 5
            )
        )
        let decisions = [false, true, true, true, true, true]
        var events: [VADSegmentationEvent] = []
        for (sequence, decision) in decisions.enumerated() {
            events += try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: UInt64(sequence)),
                observation: SyntheticPCMFixture.observation(isSpeech: decision)
            )
        }

        let endpoints = events.compactMap { event -> VADEndpointReason? in
            guard case let .segmentEnded(_, reason) = event else { return nil }
            return reason
        }
        XCTAssertEqual(endpoints, [.maximumDuration(frameCount: 5)])
        XCTAssertFalse(segmenter.isSegmentActive)
    }

    func testSilenceWinsWhenSilenceAndDurationThresholdsCoincide() throws {
        var segmenter = VADSegmenter(
            policy: try SyntheticPCMFixture.policy(
                preRoll: 3,
                endpointSilence: 1,
                maximumSegment: 4
            )
        )
        for (sequence, decision) in [false, true, true].enumerated() {
            _ = try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: UInt64(sequence)),
                observation: SyntheticPCMFixture.observation(isSpeech: decision)
            )
        }

        let events = try segmenter.consume(
            SyntheticPCMFixture.frame(sequence: 3),
            observation: SyntheticPCMFixture.observation(isSpeech: false)
        )
        XCTAssertEqual(
            events,
            [
                .frames(segmentID: 2, frames: [try SyntheticPCMFixture.frame(sequence: 3)]),
                .segmentEnded(segmentID: 2, reason: .silence(silentFrameCount: 1))
            ]
        )
    }

    func testResetClearsBuffersActiveStateAndSequenceHistory() throws {
        var segmenter = VADSegmenter(policy: try SyntheticPCMFixture.policy())
        _ = try segmenter.consume(
            SyntheticPCMFixture.frame(sequence: 10),
            observation: SyntheticPCMFixture.observation(isSpeech: true)
        )
        XCTAssertEqual(segmenter.bufferedPreRollFrameCount, 1)

        segmenter.reset()

        XCTAssertEqual(segmenter.bufferedPreRollFrameCount, 0)
        XCTAssertFalse(segmenter.isSegmentActive)
        XCTAssertNoThrow(
            try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: 1),
                observation: SyntheticPCMFixture.observation(isSpeech: false)
            )
        )
    }

    func testRejectsDuplicateAndRegressingSequencesWithoutAdvancingState() throws {
        var segmenter = VADSegmenter(policy: try SyntheticPCMFixture.policy())
        _ = try segmenter.consume(
            SyntheticPCMFixture.frame(sequence: 10),
            observation: SyntheticPCMFixture.observation(isSpeech: false)
        )

        XCTAssertThrowsError(
            try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: 10),
                observation: SyntheticPCMFixture.observation(isSpeech: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? VADSegmentationError,
                .sequenceNotIncreasing(previous: 10, current: 10)
            )
        }
        XCTAssertThrowsError(
            try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: 9),
                observation: SyntheticPCMFixture.observation(isSpeech: true)
            )
        )
        XCTAssertEqual(segmenter.bufferedPreRollFrameCount, 1)
        XCTAssertNoThrow(
            try segmenter.consume(
                SyntheticPCMFixture.frame(sequence: 11),
                observation: SyntheticPCMFixture.observation(isSpeech: false)
            )
        )
    }

    func testDeterministicPropertySequencesKeepBuffersBoundedAndFramesUnique() throws {
        for seed in 0 ..< 32 {
            var generator = DeterministicGenerator(seed: UInt64(seed))
            var segmenter = VADSegmenter(
                policy: try SyntheticPCMFixture.policy(
                    preRoll: 8,
                    onsetWindow: 5,
                    onsetRequired: 3,
                    endpointSilence: 6,
                    maximumSegment: 30
                )
            )
            var forwarded = Set<UInt64>()
            var startCount = 0
            var endpointCount = 0

            for sequence in 0 ..< 400 {
                let events = try segmenter.consume(
                    SyntheticPCMFixture.frame(sequence: UInt64(sequence)),
                    observation: SyntheticPCMFixture.observation(isSpeech: generator.nextBool())
                )
                XCTAssertLessThanOrEqual(segmenter.bufferedPreRollFrameCount, 8)
                for event in events {
                    switch event {
                    case .segmentStarted:
                        startCount += 1
                    case let .frames(_, frames):
                        for frame in frames {
                            XCTAssertTrue(forwarded.insert(frame.sequence).inserted)
                        }
                    case .segmentEnded:
                        endpointCount += 1
                        XCTAssertLessThanOrEqual(endpointCount, startCount)
                    case .speechResumed:
                        break
                    }
                }
            }
            XCTAssertLessThanOrEqual(endpointCount, startCount)
        }
    }

    private func traceLine(_ event: VADSegmentationEvent) -> String {
        switch event {
        case let .segmentStarted(segmentID):
            return "start:\(segmentID)"
        case let .frames(segmentID, frames):
            return "frames:\(segmentID):\(frames.map(\.sequence).map(String.init).joined(separator: ","))"
        case let .speechResumed(segmentID, silentFrameCount):
            return "resume:\(segmentID):\(silentFrameCount)"
        case let .segmentEnded(segmentID, reason):
            switch reason {
            case let .silence(silentFrameCount):
                return "end:\(segmentID):silence:\(silentFrameCount)"
            case let .maximumDuration(frameCount):
                return "end:\(segmentID):maximum:\(frameCount)"
            }
        }
    }
}
