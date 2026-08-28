import Foundation
import XCTest

final class ProviderNeutralSourceBoundaryTests: XCTestCase {
    func testProductionSourcesContainNoProviderConfigurationOrRawToolNames() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )
        let forbidden = [
            "apiKey", "APIKey", "resourceID", "ConversationCredential",
            "DeepSeek", "Bocha", "Doubao", "豆包", "web_search", "llmModel"
        ]
        var violations: [String] = []

        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden where contents.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "SingleGreenGlassesKit production sources crossed the provider-neutral boundary: \(violations)"
        )
    }
}
