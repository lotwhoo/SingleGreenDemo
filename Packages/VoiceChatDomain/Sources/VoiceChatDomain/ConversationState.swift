import Foundation

public enum MessageStatus: Sendable, Equatable {
    case pending
    case completed
    case failed
    case cancelled
}

public enum InputState: Sendable, Equatable {
    case idle
    case preparing
    case recording
    case finalizing
    case failed(String)
}

public enum ReplyState: Sendable, Equatable {
    case idle
    case requesting(UUID)
    case searching(UUID)
    case completed(UUID)
    case failed(UUID, String)
    case cancelled(UUID)
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public let isUser: Bool
    public let timestamp: Date
    public var status: MessageStatus

    public init(
        text: String,
        isUser: Bool,
        timestamp: Date = .now,
        id: UUID = UUID(),
        status: MessageStatus = .completed
    ) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        self.status = status
    }
}

/// 与 UI 和网络实现无关的对话领域状态。
/// 所有 reply 操作都校验 replyID，旧任务不能覆盖或删除新任务的气泡。
public struct ConversationState: Sendable, Equatable {
    public var messages: [ChatMessage]
    public var inputState: InputState
    public private(set) var replyState: ReplyState
    public private(set) var activeReplyID: UUID?

    public init(
        messages: [ChatMessage] = [],
        inputState: InputState = .idle,
        replyState: ReplyState = .idle
    ) {
        self.messages = messages
        self.inputState = inputState
        self.replyState = replyState
        switch replyState {
        case .requesting(let id), .searching(let id):
            self.activeReplyID = id
        case .idle, .completed, .failed, .cancelled:
            self.activeReplyID = nil
        }
    }

    public mutating func appendUser(_ text: String) {
        messages.append(ChatMessage(text: text, isUser: true))
    }

    @discardableResult
    public mutating func beginReply(id: UUID = UUID()) -> UUID {
        if activeReplyID != nil {
            _ = cancelActiveReply()
        }
        messages.append(ChatMessage(text: "", isUser: false, id: id, status: .pending))
        activeReplyID = id
        replyState = .requesting(id)
        return id
    }

    public mutating func markSearching(id: UUID) {
        guard activeReplyID == id else { return }
        replyState = .searching(id)
    }

    @discardableResult
    public mutating func completeReply(id: UUID, text: String) -> Bool {
        guard activeReplyID == id,
              let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages[index].text = text
        messages[index].status = .completed
        activeReplyID = nil
        replyState = .completed(id)
        return true
    }

    @discardableResult
    public mutating func failReply(id: UUID, message: String) -> Bool {
        guard activeReplyID == id else { return false }
        messages.removeAll { $0.id == id }
        activeReplyID = nil
        replyState = .failed(id, message)
        return true
    }

    @discardableResult
    public mutating func cancelActiveReply() -> UUID? {
        guard let id = activeReplyID else { return nil }
        messages.removeAll { $0.id == id && $0.status == .pending }
        activeReplyID = nil
        replyState = .cancelled(id)
        return id
    }
}
