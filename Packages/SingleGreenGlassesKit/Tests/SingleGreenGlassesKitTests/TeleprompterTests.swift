import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class TeleprompterTests: XCTestCase {
    func testScriptSegmentationPreservesPunctuationAndParagraphs() throws {
        let script = try TeleprompterScript("第一句。第二句！\nThird line? Final line")

        XCTAssertEqual(
            script.sentences,
            ["第一句。", "第二句！", "Thirdline?", "Finalline"]
        )
    }

    func testScriptSegmentationIgnoresHardWrapsAndBlankLines() throws {
        let script = try TeleprompterScript(
            "没有标点的第一部分\n\n继续同一句。\r\n下一句结束。"
        )

        XCTAssertEqual(
            script.sentences,
            ["没有标点的第一部分继续同一句。", "下一句结束。"]
        )
        XCTAssertFalse(script.sentences.contains(where: { $0.isEmpty }))
    }

    func testScriptSegmentationRemovesAllWhitespaceAndEmptyParagraphs() throws {
        let script = try TeleprompterScript(
            "  第一 段\t继续  \n\n\r\n  第二段。  \n   第三 段结束。  "
        )

        XCTAssertEqual(script.sentences, ["第一段继续第二段。", "第三段结束。"])
        XCTAssertFalse(script.sentences.joined().contains(where: { $0.isWhitespace }))
    }

    func testAlignerMovesOnlyForwardAndHoldsAmbiguousOrAdLibSpeech() throws {
        let script = try TeleprompterScript("共同开场然后向左。共同开场然后向右。最后抵达终点。")
        let aligner = TeleprompterScriptAligner()

        XCTAssertEqual(
            aligner.proposedSentenceIndex(
                transcript: "这是临场发挥，不在稿件里面",
                script: script,
                anchor: 1
            ),
            1
        )
        XCTAssertEqual(
            aligner.proposedSentenceIndex(
                transcript: "共同开场然后",
                script: script,
                anchor: 0
            ),
            0
        )
        XCTAssertEqual(
            aligner.proposedSentenceIndex(
                transcript: "最后抵达终点",
                script: script,
                anchor: 1
            ),
            2
        )
        XCTAssertEqual(
            aligner.proposedSentenceIndex(
                transcript: "共同开场然后向左",
                script: script,
                anchor: 2
            ),
            2
        )
    }

    func testAlignerToleratesPunctuationFillersAndSmallRecognitionErrors() throws {
        let script = try TeleprompterScript(
            "第一句从这里开始。今天我们来聊人工智能如何改变创作。下一段讨论隐私和边界。"
        )
        let aligner = TeleprompterScriptAligner()

        XCTAssertEqual(
            aligner.bestMatch(
                transcript: "第一句，从这里开使",
                script: script,
                anchor: 0
            )?.sentenceIndex,
            0
        )
        XCTAssertEqual(
            aligner.bestMatch(
                transcript: "嗯，今天我们来聊人工智能怎样改变创作吧",
                script: script,
                anchor: 1
            )?.sentenceIndex,
            1
        )
        XCTAssertNil(
            aligner.bestMatch(
                transcript: "这是一段完全不相关的临场补充",
                script: script,
                anchor: 1
            )
        )
    }

    func testAlignerBoundsFuzzyWorkForLongUnpunctuatedSentence() throws {
        let sentence = String(repeating: "长", count: 9_999) + "文。"
        let transcript = String(repeating: "长", count: 9_999) + "闻"
        let script = try TeleprompterScript(sentence)

        XCTAssertEqual(
            TeleprompterScriptAligner().bestMatch(
                transcript: transcript,
                script: script,
                anchor: 0
            )?.sentenceIndex,
            0
        )
    }

    func testReadingProgressContinuesAcrossASRUtteranceRotations() {
        let aligner = TeleprompterScriptAligner()
        let sentence = "今天我们先介绍自动跟随然后继续展示未读文本直到最后结束。"
        let first = try! XCTUnwrap(aligner.readingProgress(
            transcript: "今天我们先介绍自动跟随",
            sentence: sentence,
            minimumUTF16Offset: 0
        ))
        let second = try! XCTUnwrap(aligner.readingProgress(
            transcript: "然后继续展示未读文本直到最后结束",
            sentence: sentence,
            minimumUTF16Offset: first.utf16Offset
        ))

        XCTAssertGreaterThan(first.fraction, 0.2)
        XCTAssertGreaterThan(second.utf16Offset, first.utf16Offset)
        XCTAssertGreaterThan(second.fraction, 0.9)
    }

    func testLongCumulativeTranscriptWithTailErrorDoesNotJumpAhead() {
        let tokens = (0..<220).map { "词\($0)" }
        let sentence = tokens.joined() + "。"
        let firstTranscript = tokens.prefix(150).joined()
        let correctSecondTranscript = tokens.prefix(155).joined()
        let secondTranscript = String(correctSecondTranscript.dropLast()) + "错"
        let aligner = TeleprompterScriptAligner()
        let first = try! XCTUnwrap(aligner.readingProgress(
            transcript: firstTranscript,
            sentence: sentence,
            minimumUTF16Offset: 0
        ))
        let second = try! XCTUnwrap(aligner.readingProgress(
            transcript: secondTranscript,
            sentence: sentence,
            minimumUTF16Offset: first.utf16Offset
        ))

        XCTAssertGreaterThan(second.utf16Offset, first.utf16Offset)
        XCTAssertLessThanOrEqual(
            second.utf16Offset,
            (correctSecondTranscript as NSString).length + 8
        )
    }

    func testPartialTranscriptMovesFocusInsideLongSentenceBeforeCompletion() async throws {
        let session = TeleprompterFakeSpeechSession()
        let script = try TeleprompterScript(
            "今天我们先介绍自动跟随然后继续展示未读文本直到最后结束。"
        )
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { session },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )

        await controller.toggleFollowing()
        session.emit(.transcript("今天我们先介绍自动跟随"))
        await settle()

        XCTAssertEqual(controller.state.sentenceIndex, 0)
        XCTAssertEqual(controller.state.phase, .listening)
        XCTAssertGreaterThan(controller.state.readingUTF16Offset, 0)
        let body = try XCTUnwrap(
            controller.snapshot.scene.elements.first { $0.id == "teleprompter_body" }
        )
        guard case .styledFlowingTextRuns(let runs, _, _, _) = body.content else {
            return XCTFail("Expected focused teleprompter runs")
        }
        XCTAssertTrue(runs.contains { $0.opacity == 0.32 && $0.text.contains("自动跟随") })
        XCTAssertTrue(runs.contains { $0.isFocused && $0.text.contains("继续展示未读文本") })

        session.emit(.utterance("然后继续展示未读文本直到最后结束"))
        await settle()
        XCTAssertEqual(controller.state.phase, .completed)
    }

    func testShortCompleteUtteranceStillAdvancesWithoutIntraSentenceScrolling() async throws {
        let session = TeleprompterFakeSpeechSession()
        let script = try TeleprompterScript("好的。继续前进。")
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { session },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )

        await controller.toggleFollowing()
        session.emit(.utterance("好的"))
        await settle()

        XCTAssertEqual(controller.state.sentenceIndex, 1)
        XCTAssertEqual(controller.state.phase, .listening)
    }

    func testOneUnstablePartialDoesNotAdvanceButRepeatedPartialDoes() async throws {
        let session = TeleprompterFakeSpeechSession()
        let controller = makeController(session: session)

        await controller.toggleFollowing()
        XCTAssertEqual(controller.state.phase, .listening)

        session.emit(.transcript("第一句从这里开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 0)

        session.emit(.transcript("完全不同的临场发挥"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 0)

        session.emit(.transcript("第一句从这里开始"))
        session.emit(.transcript("第一句从这里开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)
    }

    func testCloudRecognitionConsentDefaultsDeniedAndManualControlsRemainUsable() async throws {
        var permissionRequests = 0
        var sessionPreparations = 0
        let script = try TeleprompterScript("第一句。第二句。")
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: {
                    sessionPreparations += 1
                    return TeleprompterFakeSpeechSession()
                },
                requestMicrophonePermission: {
                    permissionRequests += 1
                    return true
                }
            )
        )

        await controller.toggleFollowing()

        XCTAssertEqual(sessionPreparations, 0)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(controller.state.phase, .manualFallback)
        XCTAssertEqual(controller.snapshot.controlState?.errorMessage, "未同意云端语音识别，已保持手动模式。")

        await controller.moveNext()
        XCTAssertEqual(controller.state.sentenceIndex, 1)
        await controller.movePrevious()
        XCTAssertEqual(controller.state.sentenceIndex, 0)
    }

    func testEnablingConsentClearsOnlyStaleConsentErrorAndWaitsForExplicitRetry() async throws {
        var isAllowed = false
        var permissionRequests = 0
        var sessionPreparations = 0
        let script = try TeleprompterScript("第一句。第二句。")
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: {
                    sessionPreparations += 1
                    return TeleprompterFakeSpeechSession()
                },
                requestMicrophonePermission: {
                    permissionRequests += 1
                    return true
                },
                cloudSpeechRecognitionAllowed: { isAllowed }
            )
        )

        await controller.toggleFollowing()
        XCTAssertEqual(controller.state.phase, .manualFallback)
        XCTAssertNotNil(controller.state.userSafeError)

        isAllowed = true
        await controller.updateCloudSpeechRecognitionConsent(true)

        XCTAssertEqual(controller.state.phase, .manualFallback)
        XCTAssertNil(controller.state.userSafeError)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(sessionPreparations, 0)

        await controller.toggleFollowing()
        XCTAssertEqual(controller.state.phase, .listening)
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(sessionPreparations, 1)
    }

    func testEnablingConsentDoesNotClearUnrelatedManualFallbackError() async throws {
        let script = try TeleprompterScript("第一句。第二句。")
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { TeleprompterFakeSpeechSession() },
                requestMicrophonePermission: { false },
                cloudSpeechRecognitionAllowed: { true }
            )
        )

        await controller.toggleFollowing()
        let microphoneError = controller.state.userSafeError
        XCTAssertEqual(controller.state.phase, .manualFallback)

        await controller.updateCloudSpeechRecognitionConsent(true)

        XCTAssertEqual(controller.state.phase, .manualFallback)
        XCTAssertEqual(controller.state.userSafeError, microphoneError)
    }

    func testFinalUtteranceAdvancesImmediatelyAndFailureKeepsAnchorInManualMode() async {
        let session = TeleprompterFakeSpeechSession()
        let controller = makeController(session: session)

        await controller.toggleFollowing()
        session.emit(.utterance("第一句从这里开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)

        session.emit(.failed(.init(code: .connectionLost)))
        await settle()
        XCTAssertEqual(controller.state.phase, .manualFallback)
        XCTAssertEqual(controller.state.sentenceIndex, 1)
        XCTAssertEqual(controller.snapshot.controlState?.errorMessage, "语音识别连接中断，已切换为手动模式。")

        session.emit(.utterance("第三句已经结束"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)
        XCTAssertEqual(controller.state.phase, .manualFallback)
    }

    func testRevokingCloudRecognitionConsentCancelsSessionAndRejectsLateEvents() async {
        let session = TeleprompterFakeSpeechSession()
        let controller = makeController(session: session)

        await controller.toggleFollowing()
        await controller.updateCloudSpeechRecognitionConsent(false)

        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.state.phase, .manualFallback)
        XCTAssertEqual(controller.state.sentenceIndex, 0)

        session.emit(.utterance("第一句从这里开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 0)
    }

    func testManualCorrectionRestartsSessionAndRejectsLateEventsFromOldSession() async {
        let first = TeleprompterFakeSpeechSession()
        let second = TeleprompterFakeSpeechSession()
        var sessions = [first, second]
        let controller = makeController {
            sessions.removeFirst()
        }

        await controller.toggleFollowing()
        await controller.moveNext()
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.startCount, 1)
        XCTAssertEqual(controller.state.sentenceIndex, 1)

        first.emit(.utterance("第三句已经结束"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)
    }

    func testActiveLifecycleDoesNotInvalidateRunningSessionAndBackgroundRejectsStaleEvents() async {
        let session = TeleprompterFakeSpeechSession()
        let controller = makeController(session: session)

        await controller.toggleFollowing()
        controller.updateHostLifecycle(.active)
        session.emit(.utterance("第一句从这里开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)
        XCTAssertEqual(controller.state.phase, .listening)

        controller.updateHostLifecycle(.background)
        await controller.waitForPendingHostLifecycleTransition()
        await settle()
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.pendingHostLifecycleCleanupCount, 0)
        XCTAssertEqual(controller.state.phase, .paused)

        session.emit(.utterance("第三句已经结束"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)
    }

    func testEachBackgroundStartsCurrentSessionCancellationWithoutWaitingForPriorCleanup() async {
        let first = TeleprompterFakeSpeechSession(blocksCancellation: true)
        let second = TeleprompterFakeSpeechSession(blocksCancellation: true)
        var sessions = [first, second]
        let controller = makeController { sessions.removeFirst() }

        await controller.toggleFollowing()
        controller.updateHostLifecycle(.background)
        await settle()
        XCTAssertTrue(first.cancelBegan)

        await controller.toggleFollowing()
        XCTAssertEqual(second.startCount, 1)
        controller.updateHostLifecycle(.background)
        await settle()
        XCTAssertTrue(second.cancelBegan)

        first.releaseCancellation()
        second.releaseCancellation()
        await controller.waitForPendingHostLifecycleTransition()
        await controller.shutdown()
    }

    func testLifecycleWaitAwaitsEarlierBlockedCleanupAfterNewerCleanupCompletes() async {
        let first = TeleprompterFakeSpeechSession(blocksCancellation: true)
        let second = TeleprompterFakeSpeechSession()
        var sessions = [first, second]
        let controller = makeController { sessions.removeFirst() }

        await controller.toggleFollowing()
        controller.updateHostLifecycle(.background)
        await settle()
        XCTAssertTrue(first.cancelBegan)

        await controller.toggleFollowing()
        controller.updateHostLifecycle(.background)
        await waitUntil {
            second.cancelCount == 1 && controller.pendingHostLifecycleCleanupCount == 1
        }
        XCTAssertEqual(second.cancelCount, 1)
        XCTAssertEqual(controller.pendingHostLifecycleCleanupCount, 1)

        let completion = TeleprompterCompletionFlag()
        let waiter = Task {
            await controller.waitForPendingHostLifecycleTransition()
            await completion.markFinished()
        }
        await settle()
        let finishedBeforeEarlierCleanup = await completion.isFinished()
        XCTAssertFalse(finishedBeforeEarlierCleanup)

        first.releaseCancellation()
        await waiter.value
        await settle()
        XCTAssertEqual(controller.pendingHostLifecycleCleanupCount, 0)
        await controller.shutdown()
    }

    func testShutdownStartsCurrentCancellationWhileEarlierBackgroundCleanupIsBlocked() async {
        let first = TeleprompterFakeSpeechSession(blocksCancellation: true)
        let second = TeleprompterFakeSpeechSession(blocksCancellation: true)
        var sessions = [first, second]
        let controller = makeController { sessions.removeFirst() }

        await controller.toggleFollowing()
        controller.updateHostLifecycle(.background)
        await settle()
        XCTAssertTrue(first.cancelBegan)

        await controller.toggleFollowing()
        let shutdown = Task { await controller.shutdown() }
        await settle()
        XCTAssertTrue(second.cancelBegan)

        first.releaseCancellation()
        second.releaseCancellation()
        await shutdown.value
    }

    func testFinishedSessionRotatesWithoutSelfAwaitAndRejectsOldSessionEvents() async {
        let first = TeleprompterFakeSpeechSession()
        let second = TeleprompterFakeSpeechSession()
        var sessions = [first, second]
        let controller = makeController { sessions.removeFirst() }

        await controller.toggleFollowing()
        first.emit(.finished)
        await settle()

        XCTAssertEqual(second.startCount, 1)
        XCTAssertEqual(controller.state.phase, .listening)
        first.emit(.utterance("第三句已经结束"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 0)
    }

    func testBackgroundTracksCancelledInFlightPreparationUntilItActuallyReturns() async {
        let preparedSession = TeleprompterFakeSpeechSession()
        let gate = TeleprompterPreparationGate(session: preparedSession)
        let completion = TeleprompterCompletionFlag()
        let script = try! TeleprompterScript("第一句。第二句。")
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { await gate.prepare() },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )

        let start = Task { await controller.toggleFollowing() }
        await gate.waitUntilPreparationBegins()
        XCTAssertEqual(controller.pendingPreparationTaskCount, 1)

        controller.updateHostLifecycle(.background)
        let shutdown = Task {
            await controller.shutdown()
            await completion.markFinished()
        }
        await settle()
        let shutdownFinishedWhilePreparationWasBlocked = await completion.isFinished()
        XCTAssertFalse(shutdownFinishedWhilePreparationWasBlocked)

        await gate.release()
        await start.value
        await shutdown.value

        let preparationObservedCancellation = await gate.observedCancellation()
        XCTAssertTrue(preparationObservedCancellation)
        XCTAssertEqual(preparedSession.startCount, 0)
        XCTAssertEqual(preparedSession.cancelCount, 1)
        XCTAssertEqual(controller.pendingPreparationTaskCount, 0)
    }

    func testShutdownDirectlyCancelsAndTracksInFlightPreparationUntilItReturns() async {
        let preparedSession = TeleprompterFakeSpeechSession()
        let gate = TeleprompterPreparationGate(session: preparedSession)
        let completion = TeleprompterCompletionFlag()
        let script = try! TeleprompterScript("第一句。第二句。")
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { await gate.prepare() },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )

        let start = Task { await controller.toggleFollowing() }
        await gate.waitUntilPreparationBegins()
        let shutdown = Task {
            await controller.shutdown()
            await completion.markFinished()
        }
        await settle()
        let shutdownFinishedWhilePreparationWasBlocked = await completion.isFinished()
        XCTAssertFalse(shutdownFinishedWhilePreparationWasBlocked)

        await gate.release()
        await start.value
        await shutdown.value

        let preparationObservedCancellation = await gate.observedCancellation()
        XCTAssertTrue(preparationObservedCancellation)
        XCTAssertEqual(preparedSession.startCount, 0)
        XCTAssertEqual(preparedSession.cancelCount, 1)
        XCTAssertEqual(controller.pendingPreparationTaskCount, 0)
    }

    func testBackgroundCancelsAndTracksBlockedAutomaticRotationPreparation() async {
        let first = TeleprompterFakeSpeechSession()
        let rotated = TeleprompterFakeSpeechSession()
        let gate = TeleprompterPreparationGate(session: rotated)
        var preparationCount = 0
        let controller = makeController {
            preparationCount += 1
            if preparationCount == 1 { return first }
            return await gate.prepare()
        }

        await controller.toggleFollowing()
        first.emit(.finished)
        await gate.waitUntilPreparationBegins()
        XCTAssertEqual(controller.pendingPreparationTaskCount, 1)

        controller.updateHostLifecycle(.background)
        await gate.release()
        await controller.waitForPendingHostLifecycleTransition()
        await settle()

        let rotationObservedCancellation = await gate.observedCancellation()
        XCTAssertTrue(rotationObservedCancellation)
        XCTAssertEqual(rotated.startCount, 0)
        XCTAssertEqual(rotated.cancelCount, 1)
        XCTAssertEqual(controller.pendingPreparationTaskCount, 0)
        XCTAssertEqual(controller.state.phase, .paused)
        await controller.shutdown()
    }

    func testResetAndShutdownRejectStaleEvents() async {
        let first = TeleprompterFakeSpeechSession()
        let second = TeleprompterFakeSpeechSession()
        var sessions = [first, second]
        let controller = makeController { sessions.removeFirst() }

        await controller.toggleFollowing()
        await controller.reset()
        first.emit(.utterance("第三句已经结束"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 0)

        await controller.toggleFollowing()
        await controller.shutdown()
        second.emit(.utterance("第二句现在开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 0)
    }

    func testReadingFinalSentenceCompletesAndUpRestartsFromBeginning() async {
        let first = TeleprompterFakeSpeechSession()
        let restarted = TeleprompterFakeSpeechSession()
        var sessions = [first, restarted]
        let controller = makeController { sessions.removeFirst() }

        await controller.toggleFollowing()
        first.emit(.utterance("第一句从这里开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 1)

        first.emit(.utterance("第二句现在开始"))
        await settle()
        XCTAssertEqual(controller.state.sentenceIndex, 2)

        first.emit(.utterance("第三句已经结束"))
        await settle()
        XCTAssertEqual(controller.state.phase, .completed)
        XCTAssertEqual(controller.state.progress, 1)
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(controller.snapshot.primaryActionTitle, "重新开始")

        await controller.toggleFollowing()
        XCTAssertEqual(controller.state.sentenceIndex, 0)
        XCTAssertEqual(controller.state.phase, .listening)
        XCTAssertEqual(restarted.startCount, 1)
    }

    func testHUDPublishesMeasuredThreeLineBodyAndFourDirectionActions() throws {
        let script = try TeleprompterScript("第一句。第二句。第三句。")
        let state = TeleprompterState(script: script, sentenceIndex: 1, phase: .listening)
        let scene = TeleprompterHUDMapper.scene(for: state, revision: 4)
        let body = try XCTUnwrap(scene.elements.first { $0.id == "teleprompter_body" })

        XCTAssertEqual(scene.sceneID, "teleprompter.asr")
        if case .styledFlowingTextRuns(let runs, _, _, let style) = body.content {
            XCTAssertEqual(runs.map(\.text).joined(), "第一句。\n▸第二句。\n第三句。")
            XCTAssertEqual(runs.map(\.opacity), [0.32, 1, 0.68])
            XCTAssertEqual(runs.map(\.isFocused), [false, true, false])
            XCTAssertEqual(style, .detail)
        } else {
            XCTFail("Expected measured flowing text")
        }


        let firstScene = TeleprompterHUDMapper.scene(
            for: TeleprompterState(script: script, sentenceIndex: 0, phase: .listening),
            revision: 5
        )
        let firstBody = try XCTUnwrap(
            firstScene.elements.first { $0.id == "teleprompter_body" }
        )
        if case .styledFlowingTextRuns(let runs, _, _, _) = firstBody.content {
            let text = runs.map(\.text).joined()
            XCTAssertFalse(text.hasPrefix("\n"))
            XCTAssertEqual(text, "尚未朗读\n▸第一句。\n第二句。")
            XCTAssertFalse(text.contains(" "))
            XCTAssertEqual(runs.map(\.isFocused), [false, true, false])
        } else {
            XCTFail("Expected focused text runs")
        }

        let completedScene = TeleprompterHUDMapper.scene(
            for: TeleprompterState(script: script, sentenceIndex: 2, phase: .completed),
            revision: 6
        )
        let completedBody = try XCTUnwrap(
            completedScene.elements.first { $0.id == "teleprompter_body" }
        )
        if case .styledFlowingTextRuns(let runs, _, _, _) = completedBody.content {
            XCTAssertEqual(runs.map(\.text).joined(), "第二句。\n✓第三句。\n已读完")
            XCTAssertEqual(runs.count, 3)
        } else {
            XCTFail("Expected completed three-line text runs")
        }

        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { throw TeleprompterFixtureError.unused },
                requestMicrophonePermission: { false }
            )
        )
        let experience = TeleprompterExperience(controller: controller)
        XCTAssertEqual(experience.descriptor.actions.map(\.id), ["left", "right", "up", "down"])
        XCTAssertEqual(experience.descriptor.actions.filter { $0.placement == .primary }.map(\.id), ["up"])
    }

    private func makeController(session: TeleprompterFakeSpeechSession) -> TeleprompterController {
        makeController { session }
    }

    private func makeController(
        prepare: @escaping () async -> any SpeechRecognitionSession
    ) -> TeleprompterController {
        let script = try! TeleprompterScript("第一句从这里开始。第二句现在开始。第三句已经结束。")
        return TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { await prepare() },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }
}

@MainActor
private final class TeleprompterFakeSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation
    private let cancellationEvents: AsyncStream<Void>?
    private let cancellationContinuation: AsyncStream<Void>.Continuation?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var cancelBegan = false

    init(blocksCancellation: Bool = false) {
        (events, continuation) = AsyncStream.makeStream()
        if blocksCancellation {
            (cancellationEvents, cancellationContinuation) = AsyncStream.makeStream()
        } else {
            cancellationEvents = nil
            cancellationContinuation = nil
        }
    }

    func emit(_ event: SpeechRecognitionEvent) { continuation.yield(event) }
    func start() async throws { startCount += 1 }
    func finish() async {}
    func cancel() async {
        cancelCount += 1
        cancelBegan = true
        if let cancellationEvents {
            for await _ in cancellationEvents { break }
        }
    }

    func releaseCancellation() {
        cancellationContinuation?.yield(())
        cancellationContinuation?.finish()
    }
}

private enum TeleprompterFixtureError: Error {
    case unused
}

private actor TeleprompterPreparationGate {
    private let session: TeleprompterFakeSpeechSession
    private var continuation: CheckedContinuation<TeleprompterFakeSpeechSession, Never>?
    private var didBegin = false
    private var wasCancelled = false

    init(session: TeleprompterFakeSpeechSession) {
        self.session = session
    }

    func prepare() async -> TeleprompterFakeSpeechSession {
        didBegin = true
        let prepared = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        wasCancelled = Task.isCancelled
        return prepared
    }

    func waitUntilPreparationBegins() async {
        while !didBegin { await Task.yield() }
    }

    func release() {
        continuation?.resume(returning: session)
        continuation = nil
    }

    func observedCancellation() -> Bool { wasCancelled }
}

private actor TeleprompterCompletionFlag {
    private var finished = false

    func markFinished() { finished = true }
    func isFinished() -> Bool { finished }
}
