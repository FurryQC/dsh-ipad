import SwiftUI
import Foundation

// MARK: - 块级模型

/// 块级元素：解析和渲染之间的中转结构，块类型确定后不再改动。
fileprivate enum MDBlock {
    case paragraph(String)
    case code(String, String)
    case math(String)
    case heading(Int, String)
    case list([MDListItem])
    case quote(String)
    case table([[String]], Bool)
    case rule
}

/// 列表中的一行：项目符号或序号已经算好，渲染层只负责排版。
fileprivate struct MDListItem {
    let ordered: Bool
    let marker: String
    let content: String
    let indent: Int
}

/// 行内排版的最小单元：普通文字、强调、行内代码、链接文字、公式。
fileprivate enum MDFlowItem {
    case text(String)
    case bold(String)
    case italic(String)
    case code(String)
    case link(String)
    case math(String)
}

/// 统一的字号刻度：正文 15（和聊天气泡一致），列表与引用小一档，代码和表格再小一档。
fileprivate enum MDStyle {
    static let bodySize: CGFloat = 15
    static let smallSize: CGFloat = 14
    static let codeSize: CGFloat = 12.5
    static let tableSize: CGFloat = 13
}

/// 标题相对正文的放大倍数，按 # 的个数取。
fileprivate func mdHeadingScale(_ level: Int) -> CGFloat {
    switch level {
    case 1:
        return 1.35
    case 2:
        return 1.2
    default:
        return 1.08
    }
}

// MARK: - 块级解析

/// 把 Markdown 切成块级元素；只做这一层，行内样式交给 MDInlineParser。
fileprivate enum MDParser {

    /// 解析入口：先统一换行符，再逐行识别块；未知行一律落进段落。
    static func parse(_ text: String) -> [MDBlock] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                let result = parseCodeFence(lines: lines, start: index, header: trimmed)
                blocks.append(result.block)
                index = result.next
                continue
            }
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let result = parseMathBlock(lines: lines, start: index, trimmed: trimmed)
                blocks.append(result.block)
                index = result.next
                continue
            }
            if let info = headingInfo(trimmed) {
                blocks.append(.heading(info.level, info.text))
                index += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
                index += 1
                continue
            }
            if bulletText(trimmed) != nil || orderedInfo(trimmed) != nil {
                var items: [MDListItem] = []
                while index < lines.count {
                    let line = lines[index]
                    let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
                    let indent = min(leadingSpaces(line) / 2, 3)
                    if let content = bulletText(lineTrimmed) {
                        items.append(MDListItem(ordered: false, marker: "•", content: content, indent: indent))
                        index += 1
                    } else if let info = orderedInfo(lineTrimmed) {
                        items.append(MDListItem(ordered: true, marker: info.number + ".", content: info.text, indent: indent))
                        index += 1
                    } else {
                        break
                    }
                }
                if items.isEmpty {
                    blocks.append(.paragraph(trimmed))
                    index += 1
                } else {
                    blocks.append(.list(items))
                }
                continue
            }
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let lineTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if lineTrimmed.hasPrefix(">") {
                        var content = String(lineTrimmed.dropFirst())
                        if content.hasPrefix(" ") {
                            content = String(content.dropFirst())
                        }
                        quoted.append(content)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|") {
                let result = parseTable(lines: lines, start: index)
                if let tableBlock = result.block {
                    blocks.append(tableBlock)
                }
                index = result.next
                continue
            }
            var paragraphLines: [String] = []
            while index < lines.count {
                let lineTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if lineTrimmed.isEmpty {
                    break
                }
                if !paragraphLines.isEmpty && startsBlock(lineTrimmed) {
                    break
                }
                paragraphLines.append(lineTrimmed)
                index += 1
            }
            if paragraphLines.isEmpty {
                index += 1
            } else {
                blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            }
        }
        return blocks
    }

    /// 解析围栏代码块：未闭合时把剩余内容都当代码，流式输出里不丢字。
    static func parseCodeFence(lines: [String], start: Int, header: String) -> (block: MDBlock, next: Int) {
        let language = String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var codeLines: [String] = []
        var index = start + 1
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }
        return (.code(language, codeLines.joined(separator: "\n")), index)
    }

    /// 解析 $$...$$ 或 \[...\] 独立公式：可跨行，未闭合时一直吃到结尾。
    static func parseMathBlock(lines: [String], start: Int, trimmed: String) -> (block: MDBlock, next: Int) {
        let opening: String
        let closing: String
        if trimmed.hasPrefix("$$") {
            opening = "$$"
            closing = "$$"
        } else {
            opening = "\\["
            closing = "\\]"
        }
        let firstLine = String(trimmed.dropFirst(opening.count))
        if let closeRange = firstLine.range(of: closing) {
            let tex = String(firstLine[firstLine.startIndex..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (.math(tex), start + 1)
        }
        var parts: [String] = [firstLine]
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if let closeRange = line.range(of: closing) {
                parts.append(String(line[line.startIndex..<closeRange.lowerBound]))
                index += 1
                let tex = parts.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (.math(tex), index)
            }
            parts.append(line)
            index += 1
        }
        let tex = parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.math(tex), index)
    }

    /// 解析表格：按竖线切单元格，分隔行（|---|）只用来标记表头。
    static func parseTable(lines: [String], start: Int) -> (block: MDBlock?, next: Int) {
        var rows: [[String]] = []
        var rawLines: [String] = []
        var hasHeader = false
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("|") || !trimmed.dropFirst().contains("|") {
                break
            }
            var cells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            if let first = cells.first, first.isEmpty {
                cells.removeFirst()
            }
            if let last = cells.last, last.isEmpty {
                cells.removeLast()
            }
            if isSeparatorRow(cells) {
                if !rows.isEmpty {
                    hasHeader = true
                }
                index += 1
                continue
            }
            rawLines.append(trimmed)
            rows.append(cells)
            index += 1
        }
        if rows.isEmpty {
            if rawLines.isEmpty {
                return (nil, index)
            }
            return (.paragraph(rawLines.joined(separator: "\n")), index)
        }
        return (.table(rows, hasHeader), index)
    }

    /// 标题识别：1 到 6 个 # 后跟空格（或直接结束），最多按三级字号渲染。
    static func headingInfo(_ trimmed: String) -> (level: Int, text: String)? {
        var hashes = 0
        for character in trimmed {
            if character == "#" {
                hashes += 1
            } else {
                break
            }
        }
        if hashes == 0 || hashes > 6 {
            return nil
        }
        let rest = trimmed.dropFirst(hashes)
        if !rest.isEmpty && !rest.hasPrefix(" ") {
            return nil
        }
        let text = String(rest).trimmingCharacters(in: .whitespaces)
        return (min(hashes, 3), text)
    }

    /// 无序列表行：-、*、+ 后面必须跟一个空格。
    static func bulletText(_ trimmed: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// 有序列表行：数字序号加 "." 或 ")" 再接空格。
    static func orderedInfo(_ trimmed: String) -> (number: String, text: String)? {
        var digits = ""
        for character in trimmed {
            if character.isNumber {
                digits.append(character)
            } else {
                break
            }
        }
        if digits.isEmpty {
            return nil
        }
        let rest = String(trimmed.dropFirst(digits.count))
        if rest.hasPrefix(". ") {
            return (digits, String(rest.dropFirst(2)))
        }
        if rest.hasPrefix(") ") {
            return (digits, String(rest.dropFirst(2)))
        }
        return nil
    }

    /// 统计行首空格数，用来推断列表缩进层级。
    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    /// 判断一行是否开启新的块级元素，段落遇到它就收尾。
    static func startsBlock(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("```") {
            return true
        }
        if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
            return true
        }
        if headingInfo(trimmed) != nil {
            return true
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return true
        }
        if bulletText(trimmed) != nil || orderedInfo(trimmed) != nil {
            return true
        }
        if trimmed.hasPrefix(">") {
            return true
        }
        if trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|") {
            return true
        }
        return false
    }

    /// 判断分隔行：每个单元格都是可选的冒号加若干短横线。
    static func isSeparatorRow(_ cells: [String]) -> Bool {
        if cells.isEmpty {
            return false
        }
        for cell in cells {
            if !isSeparatorCell(cell) {
                return false
            }
        }
        return true
    }

    /// 单个分隔单元格，例如 ---、:--、--:、:-:。
    static func isSeparatorCell(_ cell: String) -> Bool {
        var text = cell
        if text.hasPrefix(":") {
            text.removeFirst()
        }
        if text.hasSuffix(":") {
            text.removeLast()
        }
        if text.isEmpty {
            return false
        }
        for character in text {
            if character != "-" {
                return false
            }
        }
        return true
    }

    /// 按换行切行，段内换行和引用多行都靠它还原。
    static func splitLines(_ text: String) -> [String] {
        return text.components(separatedBy: "\n")
    }
}

// MARK: - 行内解析

/// 把一行文字拆成行内片段，并顺手把文字拆成可换行的小块。
fileprivate enum MDInlineParser {

    /// 解析入口：一次扫描产出排版单元；认不出的标记原样留在文字里。
    static func flowItems(_ input: String) -> [MDFlowItem] {
        var items: [MDFlowItem] = []
        var buffer = ""
        func flushText() {
            if buffer.isEmpty {
                return
            }
            for piece in splitWords(buffer) {
                items.append(.text(piece))
            }
            buffer = ""
        }
        let escapable: Set<Character> = ["\\", "*", "_", "$", "`"]
        var index = input.startIndex
        let end = input.endIndex
        while index < end {
            let character = input[index]
            if character == "\\" {
                let next = input.index(after: index)
                if next < end && input[next] == "(" {
                    let contentStart = input.index(after: next)
                    if let closeRange = input.range(of: "\\)", range: contentStart..<end) {
                        let tex = String(input[contentStart..<closeRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                        if !tex.isEmpty {
                            flushText()
                            items.append(.math(tex))
                            index = closeRange.upperBound
                            continue
                        }
                    }
                }
                if next < end && escapable.contains(input[next]) {
                    buffer.append(input[next])
                    index = input.index(after: next)
                    continue
                }
                buffer.append(character)
                index = next
                continue
            }
            if character == "`" {
                let contentStart = input.index(after: index)
                if contentStart < end, let closeRange = input.range(of: "`", range: contentStart..<end) {
                    flushText()
                    items.append(.code(String(input[contentStart..<closeRange.lowerBound])))
                    index = closeRange.upperBound
                    continue
                }
                buffer.append(character)
                index = contentStart
                continue
            }
            if character == "*" {
                let second = input.index(after: index)
                if second < end && input[second] == "*" {
                    let contentStart = input.index(after: second)
                    if let closeRange = input.range(of: "**", range: contentStart..<end) {
                        flushText()
                        for piece in splitWords(String(input[contentStart..<closeRange.lowerBound])) {
                            items.append(.bold(piece))
                        }
                        index = closeRange.upperBound
                        continue
                    }
                }
                if let closeRange = input.range(of: "*", range: second..<end), closeRange.lowerBound > second {
                    flushText()
                    for piece in splitWords(String(input[second..<closeRange.lowerBound])) {
                        items.append(.italic(piece))
                    }
                    index = closeRange.upperBound
                    continue
                }
                buffer.append(character)
                index = second
                continue
            }
            if character == "_" {
                var previousIsWord = false
                if index > input.startIndex {
                    let previous = input[input.index(before: index)]
                    previousIsWord = previous.isLetter || previous.isNumber
                }
                if !previousIsWord {
                    let contentStart = input.index(after: index)
                    if let closeRange = input.range(of: "_", range: contentStart..<end), closeRange.lowerBound > contentStart {
                        flushText()
                        for piece in splitWords(String(input[contentStart..<closeRange.lowerBound])) {
                            items.append(.italic(piece))
                        }
                        index = closeRange.upperBound
                        continue
                    }
                }
                buffer.append(character)
                index = input.index(after: index)
                continue
            }
            if character == "$" {
                let contentStart = input.index(after: index)
                if contentStart < end && !input[contentStart].isWhitespace,
                   let closeRange = input.range(of: "$", range: contentStart..<end),
                   !input[input.index(before: closeRange.lowerBound)].isWhitespace {
                    let tex = String(input[contentStart..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if !tex.isEmpty {
                        flushText()
                        items.append(.math(tex))
                        index = closeRange.upperBound
                        continue
                    }
                }
                buffer.append(character)
                index = contentStart
                continue
            }
            if character == "[" {
                let textStart = input.index(after: index)
                if let bracketRange = input.range(of: "]", range: textStart..<end) {
                    let afterBracket = bracketRange.upperBound
                    if afterBracket < end && input[afterBracket] == "(" {
                        let urlStart = input.index(after: afterBracket)
                        if let parenRange = input.range(of: ")", range: urlStart..<end) {
                            let label = String(input[textStart..<bracketRange.lowerBound])
                            if !label.isEmpty {
                                flushText()
                                for piece in splitWords(label) {
                                    items.append(.link(piece))
                                }
                                index = parenRange.upperBound
                                continue
                            }
                        }
                    }
                }
                buffer.append(character)
                index = textStart
                continue
            }
            buffer.append(character)
            index = input.index(after: index)
        }
        flushText()
        return items
    }

    /// 把一行拆成可换行的小块：中文逐字拆，英文按词拆，空白跟着前一个词走。
    static func splitWords(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if isCJK(character) {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(String(character))
            } else if character == " " || character == "\t" {
                current.append(character)
                pieces.append(current)
                current = ""
            } else if isCJKPunctuation(character) {
                if !current.isEmpty {
                    current.append(character)
                } else if !pieces.isEmpty {
                    pieces[pieces.count - 1].append(character)
                } else {
                    pieces.append(String(character))
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    /// 判断字符是否属于可以逐字换行的中日韩文字。
    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        let value = Int(scalar.value)
        if value >= 0x4E00 && value <= 0x9FFF {
            return true
        }
        if value >= 0x3400 && value <= 0x4DBF {
            return true
        }
        if value >= 0xF900 && value <= 0xFAFF {
            return true
        }
        if value >= 0x3040 && value <= 0x30FF {
            return true
        }
        if value >= 0xAC00 && value <= 0xD7AF {
            return true
        }
        return false
    }

    /// 判断中日韩标点：标点粘在前一个片段上，免得跑到行首。
    static func isCJKPunctuation(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        let value = Int(scalar.value)
        if value >= 0x3000 && value <= 0x303F {
            return true
        }
        if value >= 0xFF01 && value <= 0xFF60 {
            return true
        }
        return false
    }
}

// MARK: - 行内排版

/// 自定义流式布局：把小块从左到右排进多行，超宽时整块换行；同排垂直居中。
fileprivate struct MDFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var lineSpacing: CGFloat = 2

    /// 布局没有需要跨次保存的中间状态，缓存类型显式声明为空。
    typealias Cache = Void

    /// 先按理想尺寸算行，再累加宽度与行高，返回整体尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = measuredSizes(maxWidth: maxWidth, subviews: subviews)
        let rows = makeRows(maxWidth: maxWidth, sizes: sizes)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for rowIndex in rows.indices {
            if rowIndex > 0 {
                height += lineSpacing
            }
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for item in rows[rowIndex] {
                rowWidth += sizes[item].width
                rowHeight = max(rowHeight, sizes[item].height)
            }
            rowWidth += horizontalSpacing * CGFloat(max(0, rows[rowIndex].count - 1))
            height += rowHeight
            width = max(width, rowWidth)
        }
        return CGSize(width: width, height: height)
    }

    /// 按同样的行划分把每个小块摆到位置上，同排以垂直中心对齐。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let sizes = measuredSizes(maxWidth: maxWidth, subviews: subviews)
        let rows = makeRows(maxWidth: maxWidth, sizes: sizes)
        var y = bounds.minY
        for rowIndex in rows.indices {
            if rowIndex > 0 {
                y += lineSpacing
            }
            var rowHeight: CGFloat = 0
            for item in rows[rowIndex] {
                rowHeight = max(rowHeight, sizes[item].height)
            }
            var x = bounds.minX
            for item in rows[rowIndex] {
                let size = sizes[item]
                let point = CGPoint(x: x, y: y + rowHeight / 2)
                subviews[item].place(at: point, anchor: .leading, proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + horizontalSpacing
            }
            y += rowHeight
        }
    }

    /// 测量每个小块：理想宽度超过容器时按容器宽重新测，让它自己换行。
    private func measuredSizes(maxWidth: CGFloat, subviews: Subviews) -> [CGSize] {
        var result: [CGSize] = []
        for index in 0..<subviews.count {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            if maxWidth.isFinite && ideal.width > maxWidth {
                result.append(subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil)))
            } else {
                result.append(ideal)
            }
        }
        return result
    }

    /// 贪心分行：放不下就开新行。
    private func makeRows(maxWidth: CGFloat, sizes: [CGSize]) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for index in sizes.indices {
            let itemWidth = sizes[index].width
            if current.isEmpty {
                current = [index]
                currentWidth = itemWidth
            } else if currentWidth + horizontalSpacing + itemWidth <= maxWidth {
                current.append(index)
                currentWidth += horizontalSpacing + itemWidth
            } else {
                rows.append(current)
                current = [index]
                currentWidth = itemWidth
            }
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

/// 行内单个小块：文字、粗体、斜体、代码、链接、公式各自一套外观。
fileprivate struct MDFlowChild: View {
    let item: MDFlowItem
    let size: CGFloat
    let color: Color
    let boldAll: Bool

    /// 按片段类型套对应外观，公式直接转交给 MathView。
    var body: some View {
        switch item {
        case .text(let value):
            Text(value)
                .font(.system(size: size, weight: boldAll ? .bold : .regular))
                .foregroundColor(color)
        case .bold(let value):
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
        case .italic(let value):
            Text(value)
                .font(.system(size: size, weight: boldAll ? .semibold : .regular))
                .italic()
                .foregroundColor(color)
        case .code(let value):
            Text(value)
                .font(.system(size: max(11, size - 1), design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surfaceStrong)
                )
        case .link(let value):
            Text(value)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(Theme.accent)
                .underline()
        case .math(let tex):
            MathView(tex: tex, fontSize: size, color: color)
        }
    }
}

/// 一行行内内容：解析后交给流式布局逐块摆放，自动换行。
fileprivate struct MDRichLine: View {
    let items: [MDFlowItem]
    let size: CGFloat
    let color: Color
    let boldAll: Bool

    /// 行内解析放在初始化里，一行只扫一遍，刷新时不再重复解析。
    init(text: String, size: CGFloat, color: Color, boldAll: Bool = false) {
        self.items = MDInlineParser.flowItems(text)
        self.size = size
        self.color = color
        self.boldAll = boldAll
    }

    /// 把解析出来的小块交给流式布局，超宽时自动换行。
    var body: some View {
        MDFlowLayout(horizontalSpacing: 0, lineSpacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                MDFlowChild(item: items[index], size: size, color: color, boldAll: boldAll)
            }
        }
    }
}

// MARK: - 块级视图

/// 段落：同一段内的换行保留，行间 2pt；段与段之间由外层 VStack 给 10pt。
fileprivate struct MDParagraphView: View {
    let text: String

    /// 段落内的换行要保留：切成若干行，逐行排版。
    private var lines: [String] {
        MDParser.splitLines(text)
    }

    /// 每行一个流式排版单元，行距 2pt。
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                MDRichLine(text: lines[index], size: MDStyle.bodySize, color: Theme.textPrimary)
            }
        }
    }
}

/// 围栏代码块：等宽、原始换行、横向滚动，不折行。
fileprivate struct MDCodeBlockView: View {
    let language: String
    let code: String

    /// 代码原样输出，横向滚动，不折行。
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code.isEmpty ? " " : code)
                .font(.system(size: MDStyle.codeSize, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(12)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

/// 列表项：符号或序号在左、内容在右，长内容自动换行并与文字左缘对齐。
fileprivate struct MDListRowView: View {
    let item: MDListItem

    /// 符号列定宽右对齐，内容列占满剩余宽度。
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(item.marker)
                .font(.system(size: MDStyle.smallSize, weight: item.ordered ? .regular : .bold))
                .foregroundColor(Theme.textSecondary)
                .frame(minWidth: item.ordered ? 20 : 10, alignment: .trailing)
            MDRichLine(text: item.content, size: MDStyle.smallSize, color: Theme.textPrimary)
        }
        .padding(.leading, CGFloat(item.indent) * 14)
    }
}

/// 列表：连续的行合成一个块，行距收紧，避免每行都被当成独立段落。
fileprivate struct MDListView: View {
    let items: [MDListItem]

    /// 列表项纵向排列，行距比段落更紧。
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                MDListRowView(item: items[index])
            }
        }
    }
}

/// 引用块：左侧一条强调色竖线，文字降为次要色、字号略小。
fileprivate struct MDQuoteView: View {
    let text: String

    /// 引用里的换行同样保留，逐行渲染。
    private var lines: [String] {
        MDParser.splitLines(text)
    }

    /// 左侧强调色竖线用 overlay 画，文字降为次要色。
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                MDRichLine(text: lines[index], size: MDStyle.smallSize, color: Theme.textSecondary)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.accent.opacity(0.5))
                .frame(width: 3)
        }
    }
}

/// 表格的一行：单元格等宽分栏，表头用强调淡底和主色文字。
fileprivate struct MDTableRowView: View {
    let cells: [String]
    let isHeader: Bool
    let showsDivider: Bool

    /// 一行单元格等宽分栏，表头加淡底，行底画发丝线。
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(cells.indices, id: \.self) { index in
                Text(cells[index])
                    .font(.system(size: MDStyle.tableSize, weight: isHeader ? .semibold : .regular))
                    .foregroundColor(isHeader ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHeader ? Theme.accentSoft : Color.clear)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(height: 1)
            }
        }
    }
}

/// 表格：整块放在一个圆角卡片里，行间用发丝线分隔。
fileprivate struct MDTableView: View {
    let rows: [[String]]
    let hasHeader: Bool

    /// 行纵向排列，整块套一层圆角边框。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                MDTableRowView(
                    cells: rows[rowIndex],
                    isHeader: hasHeader && rowIndex == 0,
                    showsDivider: rowIndex < rows.count - 1
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.surfaceStrong)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

/// 单个块的渲染入口：块类型只在这里分派一次。
fileprivate struct MDBlockView: View {
    let block: MDBlock

    /// 按块类型分派到具体视图。
    var body: some View {
        switch block {
        case .paragraph(let text):
            MDParagraphView(text: text)
        case .code(let language, let code):
            MDCodeBlockView(language: language, code: code)
        case .math(let tex):
            MathView(tex: tex)
                .frame(maxWidth: .infinity, alignment: .center)
        case .heading(let level, let text):
            MDRichLine(
                text: text,
                size: MDStyle.bodySize * mdHeadingScale(level),
                color: Theme.textPrimary,
                boldAll: true
            )
        case .list(let items):
            MDListView(items: items)
        case .quote(let text):
            MDQuoteView(text: text)
        case .table(let rows, let hasHeader):
            MDTableView(rows: rows, hasHeader: hasHeader)
        case .rule:
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - 对外入口

/// 聊天气泡里的富文本：块级结构、行内样式和 LaTeX 公式都在这里渲染。
struct MarkdownView: View {
    private let blocks: [MDBlock]

    /// 初始化时一次解析完；流式不完整输入也照样切块，不会崩。
    init(_ text: String) {
        self.blocks = MDParser.parse(text)
    }

    /// 在气泡里按块纵向排列，整块文字可选中。
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                MDBlockView(block: blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
