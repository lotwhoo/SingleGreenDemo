import Foundation
import XCTest
@testable import VoiceChatCore

final class ASRClientTests: XCTestCase {
    func testMalformedFinalResponseTerminatesLegacyAndDirectPathsExactlyOnce() async {
        let client = ASRClient(config: .init(apiKey: "test-key"))
        let legacyFailures = ASRClientFailureRecorder()
        let legacyObservation = Task {
            for await event in client.events {
                if case .state(.failed(let failure)) = event {
                    await legacyFailures.append(failure)
                }
            }
        }
        let directEvents = await client.replaceDirectEventStream()
        let directObservation = Task {
            var events: [StreamingASRTransportEvent] = []
            for await event in directEvents { events.append(event) }
            return events
        }

        let malformedFinal = makeMalformedFinalResponseFrame()
        await client.handleServerData(malformedFinal)
        await client.handleServerData(malformedFinal)

        let direct = await directObservation.value
        await waitUntil { await legacyFailures.count == 1 }
        let legacy = await legacyFailures.values
        legacyObservation.cancel()

        XCTAssertEqual(direct, [.failed(.categorized(.protocolFailure))])
        XCTAssertEqual(legacy.map(\.code), [.protocolFailure])
    }

    func testLegacyChunkSendFailureTerminatesOnceAndSkipsFinalFrame() async {
        await assertLegacyPumpFailure(
            failingCall: 1,
            finishInput: false,
            expectedFinalFlags: [false]
        )
    }

    func testLegacyFinalSendFailureTerminatesOnceAfterSuccessfulChunks() async {
        await assertLegacyPumpFailure(
            failingCall: 2,
            finishInput: true,
            expectedFinalFlags: [false, true]
        )
    }

    private func assertLegacyPumpFailure(
        failingCall: Int,
        finishInput: Bool,
        expectedFinalFlags: [Bool],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let sender = FailingASRFrameSender(failingCall: failingCall)
        let client = ASRClient(
            config: .init(apiKey: "test-key"),
            frameSender: { data, final in
                try await sender.send(data: data, final: final)
            }
        )
        let terminals = ASRClientTerminalRecorder()
        let observation = Task {
            for await event in client.events {
                await terminals.record(event)
            }
        }

        let pump = await client.startLegacyAudioPumpForTesting()
        await client.pushAudio(Data([1, 2, 3]))
        if finishInput { await client.finish() }
        await pump.value
        await client.handleServerData(Data([0x00]))
        await client.handleServerData(Data([0x00]))
        await waitUntil { await terminals.failureCount == 1 }

        let recordedFailures = await terminals.failures
        let finishedCount = await terminals.finishedCount
        let finalFlags = await sender.finalFlags
        let resourcesReleased = await client.connectionResourcesReleasedForTesting
        observation.cancel()

        XCTAssertEqual(recordedFailures.map(\.code), [.connectionLost], file: file, line: line)
        XCTAssertEqual(finishedCount, 0, file: file, line: line)
        XCTAssertEqual(finalFlags, expectedFinalFlags, file: file, line: line)
        XCTAssertTrue(resourcesReleased, file: file, line: line)
    }

    private func makeMalformedFinalResponseFrame() -> Data {
        let malformedJSON = Data("{".utf8)
        var frame = Data([0x11, 0x93, 0x10, 0x00])
        var sequence = Int32(-1).bigEndian
        withUnsafeBytes(of: &sequence) { frame.append(contentsOf: $0) }
        var size = UInt32(malformedJSON.count).bigEndian
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        frame.append(malformedJSON)
        return frame
    }
}

private actor FailingASRFrameSender {
    private let failingCall: Int
    private var callCount = 0
    private(set) var finalFlags: [Bool] = []

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func send(data: Data, final: Bool) throws {
        _ = data
        callCount += 1
        finalFlags.append(final)
        if callCount == failingCall {
            throw URLError(.networkConnectionLost)
        }
    }
}

private actor ASRClientTerminalRecorder {
    private(set) var failures: [ASRFailure] = []
    private(set) var finishedCount = 0

    var failureCount: Int { failures.count }

    func record(_ event: ASRClient.Event) {
        guard case .state(let state) = event else { return }
        switch state {
        case .failed(let failure):
            failures.append(failure)
        case .finished:
            finishedCount += 1
        case .idle, .connecting, .streaming:
            break
        }
    }
}

private actor ASRClientFailureRecorder {
    private var failures: [ASRFailure] = []

    var count: Int { failures.count }
    var values: [ASRFailure] { failures }

    func append(_ failure: ASRFailure) {
        failures.append(failure)
    }
}

private func waitUntil(
    maxYields: Int = 20_000,
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<maxYields {
        if await predicate() { return }
        await Task.yield()
    }
}
