import Foundation
import XCTest

final class WebRTCVADVendorIntegrityTests: XCTestCase {
    func testVerificationScriptValidatesEveryPinnedHashAndInventory() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [packageRoot.appendingPathComponent("Scripts/verify_webrtc_vad_vendor.sh").path]
        process.currentDirectoryURL = packageRoot
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: bytes, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(
            message.contains(
                "11 upstream C, 12 upstream headers, 12 project C, 1 project header, 5 legal files"
            )
        )
    }

    func testExternalConsumerCanOnlyCompileProjectFacade() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            packageRoot.appendingPathComponent(
                "Scripts/verify_webrtc_vad_public_surface.sh"
            ).path
        ]
        process.currentDirectoryURL = packageRoot
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: bytes, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, message)
        XCTAssertTrue(
            message.contains(
                "checked create imports Optional; upstream WebRtcVad_Create unavailable"
            )
        )
    }

    func testManifestPinsApprovedIdentityAndExactFileCounts() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.dependency, "webrtc-vad-minimal")
        XCTAssertEqual(manifest.remote, "https://webrtc.googlesource.com/src")
        XCTAssertEqual(manifest.commit, "1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1")
        XCTAssertEqual(manifest.tree, "9e1c614027e41b4885cb3712cd9b2444388fac73")
        XCTAssertEqual(manifest.sourceFiles.count, 11)
        XCTAssertEqual(manifest.headerFiles.count, 12)
        XCTAssertEqual(manifest.projectFiles.count, 13)
        XCTAssertEqual(manifest.legalFiles.count, 5)
        XCTAssertTrue(manifest.sourceFiles.allSatisfy(\.upstream))
        XCTAssertTrue(manifest.headerFiles.allSatisfy(\.upstream))
        XCTAssertTrue(manifest.projectFiles.allSatisfy { !$0.upstream })
    }

    func testNoExtraOrProbeOnlyCFilesAreVendored() throws {
        let manifest = try loadManifest()
        let cRoot = packageRoot.appendingPathComponent("Sources/CWebRTCVAD")
        let actual = try recursiveFiles(withExtension: "c", under: cRoot)
        let expected = Set(
            (manifest.sourceFiles + manifest.projectFiles)
                .map(\.path)
                .filter { $0.hasSuffix(".c") }
        )

        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.contains { $0.hasSuffix("/min_max_operations.c") })
        XCTAssertFalse(actual.contains { $0.hasSuffix("/resample_by_2.c") })
        XCTAssertFalse(actual.contains { $0.hasSuffix("/spl_init.c") })
    }

    func testLicenseAndSPLProvenanceInventoryIsComplete() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(
            Set(manifest.legalFiles.map(\.path)),
            [
                "ThirdParty/WebRTC/LICENSE",
                "ThirdParty/WebRTC/PATENTS",
                "ThirdParty/WebRTC/AUTHORS",
                "ThirdParty/WebRTC/spl_sqrt_floor/LICENSE",
                "ThirdParty/WebRTC/spl_sqrt_floor/README.chromium"
            ]
        )
        for legalFile in manifest.legalFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: packageRoot.appendingPathComponent(legalFile.path).path
                )
            )
        }
    }

    func testFatalCompatibilityTerminatesWithoutDynamicLogging() throws {
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/CWebRTCVAD/rtc_fatal_message.c"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("abort();"))
        XCTAssertTrue(source.contains("(void)file;"))
        XCTAssertTrue(source.contains("(void)line;"))
        XCTAssertTrue(source.contains("(void)msg;"))
        XCTAssertFalse(source.contains("printf"))
        XCTAssertFalse(source.contains("fprintf"))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadManifest() throws -> VendorManifest {
        let data = try Data(
            contentsOf: packageRoot.appendingPathComponent("ThirdParty/WebRTC/provenance.json")
        )
        return try JSONDecoder().decode(VendorManifest.self, from: data)
    }

    private func recursiveFiles(withExtension extensionName: String, under root: URL) throws -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }

        var paths: Set<String> = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == extensionName {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                paths.insert(fileURL.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
            }
        }
        return paths
    }
}

private struct VendorManifest: Decodable {
    let dependency: String
    let remote: String
    let commit: String
    let tree: String
    let sourceFiles: [VendorEntry]
    let headerFiles: [VendorEntry]
    let projectFiles: [VendorEntry]
    let legalFiles: [LegalEntry]
}

private struct VendorEntry: Decodable {
    let path: String
    let sha256: String
    let upstream: Bool
}

private struct LegalEntry: Decodable {
    let path: String
    let sha256: String
}
