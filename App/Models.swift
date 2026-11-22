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
}

struct ChatSession: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String = "新会话"
    var items: [ChatItem] = []
    var updatedAt: Date = Date()
}

// MARK: - API 传输结构

struct WireFunction: Codable {
    var name: String
    var arguments: String
}

struct WireToolCall: Codable {
    var id: String
    var type: String = "function"
    var function: WireFunction
}

struct WireMessage: Codable {
    var role: String
    var content: String?
    var tool_calls: [WireToolCall]?
    var tool_call_id: String?

    init(role: String, content: String? = nil, tool_calls: [WireToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }
}

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

struct ChatRequest: Encodable {
    var model: String
    var messages: [WireMessage]
    var tools: [ToolSpec]
    var tool_choice: String
    var stream: Bool
}

struct StreamFunctionDelta: Decodable {
    var name: String?
    var arguments: String?
}

struct StreamToolCallDelta: Decodable {
    var index: Int?
    var id: String?
    var function: StreamFunctionDelta?
}

struct StreamDelta: Decodable {
    var content: String?
    var tool_calls: [StreamToolCallDelta]?
}

struct StreamChoice: Decodable {
    var delta: StreamDelta?
    var finish_reason: String?
}

struct StreamChunk: Decodable {
    var choices: [StreamChoice]?
}

/// 一次模型回复：文本 + 要执行的工具调用。
struct AssistantTurn {
    var text: String
    var toolCalls: [ToolCall]
}
