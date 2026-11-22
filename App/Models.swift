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

/// 会话的两种用途。对话模式不加载任何工具，也不会弹「别切走」；
/// 工作模式才会读写文件、跑长任务，所以需要提醒用户留在本 App。
enum SessionMode: String, Codable {
    case chat
    case work

    var title: String {
        switch self {
        case .chat: return "对话"
        case .work: return "工作"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .work: return "hammer"
        }
    }

    var blurb: String {
        switch self {
        case .chat: return "只聊天，不带工具，不碰文件，也不会打断你切程序"
        case .work: return "可以读写工作目录里的文件、跑工具循环，跑起来要留在本 App"
        }
    }
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
    /// 用户消息里带的图片/文件。图片会以 base64 图片块发给模型，文件只作说明。
    var attachments: [AttachmentRef] = []
}

/// 手写解码放在扩展里：扩展不会顶掉结构体的逐成员初始化器，而合成的解码器一旦缺键
/// 就会让整份 sessions.json 解码失败 —— 表现就是升级后「对话记录丢了」。
extension ChatItem {
    private enum CodingKeys: String, CodingKey {
        case id, role, text, toolCalls, toolCallId, toolName
        case isError, isRunning, reasoning, reasoningSignature, attachments
    }

    /// 每个字段都允许缺失，缺了就用默认值。新增字段之后旧会话文件仍然算合法输入。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decodeIfPresent(ChatRole.self, forKey: .role) ?? .user
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningSignature = try container.decodeIfPresent(String.self, forKey: .reasoningSignature)
        attachments = try container.decodeIfPresent([AttachmentRef].self, forKey: .attachments) ?? []
    }
}

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var mode: SessionMode
    var items: [ChatItem]
    var updatedAt: Date
    /// 最近一次跑完工具的耗时。结果折叠行要显示「已完成，用时 X」，不落盘就只剩转圈。
    var lastRunSeconds: Double?

    init(id: UUID = UUID(),
         title: String = "新对话",
         mode: SessionMode = .chat,
         items: [ChatItem] = [],
         updatedAt: Date = Date(),
         lastRunSeconds: Double? = nil) {
        self.id = id
        self.title = title
        self.mode = mode
        self.items = items
        self.updatedAt = updatedAt
        self.lastRunSeconds = lastRunSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, mode, items, updatedAt, lastRunSeconds
    }

    /// 手写解码：旧版本会话文件里没有 mode 字段，缺了就按「工作」读回，
    /// 让已经在跑的老会话行为不变，而不是让整份历史解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        mode = try container.decodeIfPresent(SessionMode.self, forKey: .mode) ?? .work
        items = try container.decodeIfPresent([ChatItem].self, forKey: .items) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastRunSeconds = try container.decodeIfPresent(Double.self, forKey: .lastRunSeconds)
    }
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

/// 系统选择器请求。统一由 RootView 在最外层弹，避免 sheet 里再弹 sheet 被吞掉。
enum PickerRequest: String, Identifiable {
    case files
    case folders

    var id: String { rawValue }
}
