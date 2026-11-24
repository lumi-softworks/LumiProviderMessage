import Foundation
import Testing
@testable import ProviderMessage

@Suite("消息截断")
@MainActor
struct MessageTruncationTests {
    private func makeConversation() -> (conversationID: UUID, messages: [Message]) {
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let roles: [MessageRole] = [.user, .assistant, .tool, .user, .assistant, .system]
        let messages = roles.enumerated().map { offset, role in
            Message(
                conversationID: conversationID,
                role: role,
                content: "message \(offset)",
                createdAt: base.addingTimeInterval(TimeInterval(offset))
            )
        }
        return (conversationID, messages)
    }

    @Test("保留前缀，删除目标及其后的全部消息")
    func removesTargetAndSuffix() {
        let manager = DefaultMessageManager()
        let (conversationID, messages) = makeConversation()
        messages.forEach { manager.insertMessage($0, to: conversationID) }

        manager.deleteMessages(from: messages[3].id, in: conversationID)

        #expect(manager.messages(for: conversationID).map(\.id) == [messages[0].id, messages[1].id, messages[2].id])
        #expect(manager.message(id: messages[3].id, in: conversationID) == nil)
        #expect(manager.message(id: messages[5].id, in: conversationID) == nil)
        #expect(manager.messageCount(for: conversationID) == 3)
    }

    @Test("截断最后一条消息只删除它自己")
    func removesOnlyLastMessage() {
        let manager = DefaultMessageManager()
        let (conversationID, messages) = makeConversation()
        messages.forEach { manager.insertMessage($0, to: conversationID) }

        manager.deleteMessages(from: messages[5].id, in: conversationID)

        #expect(manager.messages(for: conversationID).map(\.id) == messages.dropLast().map(\.id))
    }

    @Test("只发出一个 truncated 事件")
    func emitsSingleTruncatedEvent() {
        let manager = DefaultMessageManager()
        let (conversationID, messages) = makeConversation()
        messages.forEach { manager.insertMessage($0, to: conversationID) }
        var changes: [MessageChange] = []
        manager.addMessageChangeObserver { changes.append($0) }

        manager.deleteMessages(from: messages[1].id, in: conversationID)

        #expect(changes.count == 1)
        guard case let .truncated(fromID, changedConversationID) = changes.first else {
            Issue.record("expected a single .truncated change, got \(changes)")
            return
        }
        #expect(fromID == messages[1].id)
        #expect(changedConversationID == conversationID)
    }

    @Test("目标不存在时什么都不做")
    func unknownTargetIsNoOp() {
        let manager = DefaultMessageManager()
        let (conversationID, messages) = makeConversation()
        messages.forEach { manager.insertMessage($0, to: conversationID) }
        var changes: [MessageChange] = []
        manager.addMessageChangeObserver { changes.append($0) }

        manager.deleteMessages(from: UUID(), in: conversationID)
        manager.deleteMessages(from: messages[0].id, in: UUID())

        #expect(manager.messages(for: conversationID).map(\.id) == messages.map(\.id))
        #expect(changes.isEmpty)
    }

    @Test("同一时间的消息按 id 顺序决定谁在目标之后")
    func sameTimestampOrderingIsPreserved() {
        let manager = DefaultMessageManager()
        let conversationID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (0..<6).map { index in
            Message(conversationID: conversationID, role: .user, content: "\(index)", createdAt: createdAt)
        }
        // 乱序插入，确认截断不依赖插入顺序。
        for message in messages.reversed() { manager.insertMessage(message, to: conversationID) }
        let expectedOrder = DefaultMessageManager.timelineOrder(messages).map(\.id)
        let target = expectedOrder[2]

        manager.deleteMessages(from: target, in: conversationID)

        #expect(manager.messages(for: conversationID).map(\.id) == Array(expectedOrder.prefix(2)))
    }

    @Test("默认实现逐条删除并沿用 deleteMessage 的事件")
    func defaultImplementationUsesDeleteMessage() {
        let manager = RecordingMessageManager()
        let conversationID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (0..<4).map { offset in
            Message(conversationID: conversationID, role: .user, content: "\(offset)", createdAt: base.addingTimeInterval(Double(offset)))
        }
        messages.forEach { manager.insertMessage($0, to: conversationID) }

        manager.deleteMessages(from: messages[2].id, in: conversationID)

        #expect(manager.deletedIDs == [messages[2].id, messages[3].id])
        #expect(manager.messages(for: conversationID).map(\.id) == [messages[0].id, messages[1].id])
        manager.deleteMessages(from: UUID(), in: conversationID)
        #expect(manager.deletedIDs == [messages[2].id, messages[3].id])
    }
}

@MainActor
private final class RecordingMessageManager: MessageManaging {
    private var storage: [UUID: [Message]] = [:]
    private(set) var deletedIDs: [UUID] = []

    func messages(for conversationID: UUID) -> [Message] {
        storage[conversationID] ?? []
    }

    func message(id: UUID, in conversationID: UUID) -> Message? {
        storage[conversationID]?.first { $0.id == id }
    }

    func lastMessage(in conversationID: UUID) -> Message? {
        storage[conversationID]?.last
    }

    func messageCount(for conversationID: UUID) -> Int {
        storage[conversationID]?.count ?? 0
    }

    func insertMessage(_ message: Message, to conversationID: UUID) {
        storage[conversationID, default: []].append(message)
    }

    func updateMessage(id: UUID, in conversationID: UUID, content: String) {}

    func deleteMessage(id: UUID, in conversationID: UUID) {
        storage[conversationID]?.removeAll { $0.id == id }
        deletedIDs.append(id)
    }

    func clearMessages(in conversationID: UUID) {
        storage[conversationID] = []
    }

    func updateToolCallResult(
        _: MessageToolResult,
        toolCallID: String,
        assistantMessageID: UUID,
        in conversationID: UUID,
        authorizationState: String?
    ) {}
}
