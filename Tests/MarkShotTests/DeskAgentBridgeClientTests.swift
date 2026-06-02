import XCTest
@testable import MarkShot

final class DeskAgentBridgeClientTests: XCTestCase {
    func testProofTurnsAreFilteredByConversationID() {
        XCTAssertTrue(turn(conversationId: "iphone-live-proof-123").isProofTurn)
        XCTAssertTrue(turn(conversationId: "iphone-live-socket-proof-123").isProofTurn)
        XCTAssertTrue(turn(conversationId: "iphone-live-tool-proof-123").isProofTurn)
        XCTAssertTrue(turn(conversationId: "iphone-any-proof-value").isProofTurn)
    }

    func testRealIPhoneTurnsAreNotProofTurns() {
        XCTAssertFalse(turn(conversationId: "iphone-6c6d5ee4-5156-4677-bd61-8f8db62bc132").isProofTurn)
        XCTAssertFalse(turn(conversationId: "notch-123").isProofTurn)
        XCTAssertFalse(turn(conversationId: nil).isProofTurn)
    }

    private func turn(conversationId: String?) -> DeskAgentConversationTurn {
        DeskAgentConversationTurn(
            id: UUID().uuidString,
            source: "iphone",
            conversationId: conversationId,
            text: "hello",
            response: "hi",
            backend: "gemini-live",
            actionKind: "live-voice",
            at: "2026-05-31T00:00:00.000Z"
        )
    }
}
