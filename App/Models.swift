import Foundation

/// 一次工具调用的完整内容（由流式响应拼装而成）。
struct ToolCall: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var arguments: String
}

enum ChatRole: String, Codable {
    case user
    case assistant
    case tool
}

/// 会话里的一条消息。user/assistant 是对话，tool 是工具结果回填。
struct ChatItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: ChatRole
    var text: String = ""
    var toolCalls: [ToolCall] = []
    var toolCallId: String?
    var toolName: String?
    var isError: Bool = false
    var isRunning: Bool = false
    /// 推理正文。开着推理等级时服务端会回传，展示在「思考」折叠区。
    var reasoning: String?
    /// 推理块的签名。回放历史时必须原样带回，否则服务端拒绝。
    var reasoningSignature: String?
}

struct ChatSession: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String = "新会话"
    var items: [ChatItem] = []
    var updatedAt: Date = Date()
}

// MARK: - API 传输结构

struct ToolProperty: Codable {
    var type: String
    var description: String
}

struct ToolParameters: Codable {
    var type: String = "object"
    var properties: [String: ToolProperty] = [:]
    var required: [String] = []
}

struct ToolSpecFunction: Codable {
    var name: String
    var description: String
    var parameters: ToolParameters
}

struct ToolSpec: Codable {
    var type: String = "function"
    var function: ToolSpecFunction
}
