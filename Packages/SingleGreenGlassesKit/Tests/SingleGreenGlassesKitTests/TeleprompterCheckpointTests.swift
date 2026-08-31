import Foundation
@testable import SingleGreenGlassesKit
import XCTest

final class TeleprompterCheckpointTests: XCTestCase {
    func testCodecRoundTripContainsOnlyVersionIdentityAndNumericPosition() throws {
        let checkpoint = TeleprompterPositionCheckpoint(
            scriptIdentity: .init(rawValue: "script-fixture-id"),
            contentVersion: .init(rawValue: 42),
            sentenceIndex: 3,
            originalUTF16Offset: 7
        )

        let data = try TeleprompterCheckpointCodec.encode(checkpoint)
        XCTAssertEqual(TeleprompterCheckpointCodec.decode(data), .loaded(checkpoint))

        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("稿件正文不应进入位置记录"))
        XCTAssertFalse(encoded.contains("识别原文不应进入位置记录"))
        XCTAssertFalse(encoded.contains("provider"))
        XCTAssertFalse(encoded.contains("credential"))
    }

    func testResolverRestoresOnlyMatchingSchemaIdentityVersionAndBounds() throws {
        let identity = TeleprompterScriptIdentity(rawValue: "stable-script")
        let script = try TeleprompterScript("第一句。第二句。", identity: identity)
        let valid = TeleprompterPositionCheckpoint(
            scriptIdentity: identity,
            contentVersion: script.version,
            sentenceIndex: 1,
            originalUTF16Offset: 2
        )

        XCTAssertEqual(
            TeleprompterCheckpointResolver.resolve(.loaded(valid), for: script),
            .restored(.init(sentenceIndex: 1, utf16Offset: 2))
        )

        let cases: [(TeleprompterPositionCheckpoint, TeleprompterCheckpointRejectionReason)] = [
            (
                .init(
                    schemaVersion: 99,
                    scriptIdentity: identity,
                    contentVersion: script.version,
                    sentenceIndex: 1,
                    originalUTF16Offset: 2
                ),
                .unsupportedSchema(99)
            ),
            (
                .init(
                    scriptIdentity: .init(rawValue: "other-script"),
                    contentVersion: script.version,
                    sentenceIndex: 1,
                    originalUTF16Offset: 2
                ),
                .scriptIdentityMismatch
            ),
            (
                .init(
                    scriptIdentity: identity,
                    contentVersion: .init(rawValue: script.version.rawValue &+ 1),
                    sentenceIndex: 1,
                    originalUTF16Offset: 2
                ),
                .contentVersionMismatch
            ),
            (
                .init(
                    scriptIdentity: identity,
                    contentVersion: script.version,
                    sentenceIndex: 99,
                    originalUTF16Offset: 2
                ),
                .invalidPosition
            ),
            (
                .init(
                    scriptIdentity: identity,
                    contentVersion: script.version,
                    sentenceIndex: 0,
                    originalUTF16Offset: 999
                ),
                .invalidPosition
            )
        ]

        for (checkpoint, expected) in cases {
            XCTAssertEqual(
                TeleprompterCheckpointResolver.resolve(.loaded(checkpoint), for: script),
                .rejected(expected)
            )
        }
    }

    func testContentRevisionWithStableIdentityRejectsOldCheckpoint() throws {
        let identity = TeleprompterScriptIdentity(rawValue: "stable-across-edits")
        let oldScript = try TeleprompterScript("旧稿第一句。", identity: identity)
        let revisedScript = try TeleprompterScript("新稿第一句。", identity: identity)
        let checkpoint = try XCTUnwrap(TeleprompterCheckpointResolver.makeCheckpoint(
            script: oldScript,
            anchor: .init(sentenceIndex: 0, utf16Offset: 2)
        ))

        XCTAssertEqual(oldScript.identity, revisedScript.identity)
        XCTAssertNotEqual(oldScript.version, revisedScript.version)
        XCTAssertEqual(
            TeleprompterCheckpointResolver.resolve(.loaded(checkpoint), for: revisedScript),
            .rejected(.contentVersionMismatch)
        )
    }

    func testCorruptDataAndMissingDataFailClosedWithTypedResults() throws {
        let script = try TeleprompterScript("安全默认位置。")
        let corrupt = TeleprompterCheckpointCodec.decode(Data([0x00, 0x01, 0x02]))

        XCTAssertEqual(corrupt, .rejected(.corruptData))
        XCTAssertEqual(
            TeleprompterCheckpointResolver.resolve(corrupt, for: script),
            .rejected(.corruptData)
        )
        XCTAssertEqual(
            TeleprompterCheckpointResolver.resolve(.missing, for: script),
            .noCheckpoint
        )
    }
}
