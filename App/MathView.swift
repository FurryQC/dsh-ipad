import SwiftUI
import Foundation

/// 公式语法树：TeX 子集解析后只会落成这几种节点，渲染层按类型分派。
enum MathNode {
    /// 正体文本：数字、运算符、text 命令的内容，以及未知命令的兜底。
    case text(String)

    /// 斜体符号：一组拉丁字母或小写希腊字母，数学变量按惯例用斜体。
    case symbol(String)

    /// 显式空白：细空格、分号空格、quad 空格和普通空格，宽度以字号为单位。
    case space(CGFloat)

    /// 行：一段从左到右排列的内容，所有结构最后都靠它拼起来。
    case row([MathNode])

    /// 分式：分子在上、分母在下，中间一条横线。
    case frac(MathNode, MathNode)

    /// 根式：可选根指数加根号内的内容。
    case sqrt(index: MathNode?, radicand: MathNode)

    /// 上下标：底数加可选的上标与下标，两者可以并存。
    case script(base: MathNode, sup: MathNode?, sub: MathNode?)

    /// 定界符：左右括号夹内容，tall 表示内容够高、括号要放大。
    case delimited(open: String, close: String, inner: MathNode, tall: Bool)
}

/// 递归下降解析器：把 TeX 子集切成 MathNode，残缺输入一律降级成普通文本。
struct MathParser {
    /// 反斜杠：TeX 命令的起始字符，集中一处省掉满屏转义。
    private static let backslash: Character = "\\"

    /// 待解析的字符序列。
    private let chars: [Character]

    /// 当前读到的下标位置。
    private var pos: Int = 0

    /// 保存字符序列，位置从头开始。
    private init(_ text: String) {
        self.chars = Array(text)
    }

    /// 外部入口：解析整段字符串并返回节点数组。
    static func parse(_ text: String) -> [MathNode] {
        var parser = MathParser(text)
        return parser.parseRow(stopAtBrace: false, inDelimiter: false)
    }

    /// 解析一行内容；遇到不配对的右括号或右定界符就停下，交给上层收尾。
    private mutating func parseRow(stopAtBrace: Bool, inDelimiter: Bool) -> [MathNode] {
        var nodes: [MathNode] = []
        while pos < chars.count {
            let c = chars[pos]
            if c == "}" {
                if stopAtBrace { break }
                pos += 1
                nodes.append(.text("}"))
                continue
            }
            if c == MathParser.backslash {
                if inDelimiter && peekIsRightCommand() { break }
                if let node = parseCommand() {
                    nodes.append(node)
                }
                continue
            }
            if c == "^" || c == "_" {
                pos += 1
                let argument = parseArgument()
                let base = nodes.popLast() ?? .row([])
                nodes.append(makeScript(base: base, isSuperscript: c == "^", argument: argument))
                continue
            }
            if c == "{" {
                pos += 1
                let inner = parseRow(stopAtBrace: true, inDelimiter: false)
                if pos < chars.count && chars[pos] == "}" { pos += 1 }
                nodes.append(.row(inner))
                continue
            }
            if c == " " {
                pos += 1
                nodes.append(.space(0.25))
                continue
            }
            pos += 1
            if c.isNumber || c == "." {
                var digits = String(c)
                while pos < chars.count && (chars[pos].isNumber || chars[pos] == ".") {
                    digits.append(chars[pos])
                    pos += 1
                }
                nodes.append(.text(digits))
            } else if c.isASCII && c.isLetter {
                var letters = String(c)
                while pos < chars.count && chars[pos].isASCII && chars[pos].isLetter {
                    letters.append(chars[pos])
                    pos += 1
                }
                nodes.append(.symbol(letters))
            } else {
                nodes.append(.text(String(c)))
            }
        }
        return nodes
    }

    /// 窥探当前位置是不是右定界命令，用来在左定界之后截断内容。
    private func peekIsRightCommand() -> Bool {
        guard pos < chars.count && chars[pos] == MathParser.backslash else { return false }
        var cursor = pos + 1
        var name = ""
        while cursor < chars.count && chars[cursor].isLetter {
            name.append(chars[cursor])
            cursor += 1
        }
        return name == "right"
    }

    /// 读一个反斜杠命令，返回对应节点；不认识的命令去掉反斜杠按文本渲染。
    private mutating func parseCommand() -> MathNode? {
        guard pos < chars.count && chars[pos] == MathParser.backslash else { return nil }
        pos += 1
        guard pos < chars.count else { return .text(String(MathParser.backslash)) }
        var name = ""
        if chars[pos].isLetter {
            while pos < chars.count && chars[pos].isLetter {
                name.append(chars[pos])
                pos += 1
            }
        } else {
            name = String(chars[pos])
            pos += 1
        }
        if name == "frac" || name == "dfrac" {
            let numerator = parseArgument() ?? .row([])
            let denominator = parseArgument() ?? .row([])
            return .frac(numerator, denominator)
        }
        if name == "sqrt" {
            let rootIndex = parseBracketArgument()
            let body = parseArgument() ?? .row([])
            return .sqrt(index: rootIndex, radicand: body)
        }
        if name == "left" {
            return parseDelimited()
        }
        if name == "text" {
            return .text(parseRawText())
        }
        if let mapped = mappedNode(name: name) {
            return mapped
        }
        return .text(name)
    }

    /// 收一个左定界组合：读左括号、内容、右括号，括号大小按内容高度估算。
    private mutating func parseDelimited() -> MathNode {
        let open = parseDelimiter()
        let nodes = parseRow(stopAtBrace: false, inDelimiter: true)
        var close = ""
        if peekIsRightCommand() {
            pos += 1
            while pos < chars.count && chars[pos].isLetter { pos += 1 }
            close = parseDelimiter()
        }
        return .delimited(open: open, close: close, inner: .row(nodes), tall: containsTall(nodes))
    }

    /// 取 text 命令花括号里的原始内容，里面的字符不再当 TeX 解析。
    private mutating func parseRawText() -> String {
        while pos < chars.count && chars[pos] == " " { pos += 1 }
        guard pos < chars.count && chars[pos] == "{" else { return "" }
        pos += 1
        var depth = 1
        var out = ""
        while pos < chars.count {
            let c = chars[pos]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    pos += 1
                    break
                }
            }
            out.append(c)
            pos += 1
        }
        return out
    }

    /// 把命令名映射成节点：希腊字母、运算符、函数、空白；未知返回 nil 走文本兜底。
    private func mappedNode(name: String) -> MathNode? {
        switch name {
        case "alpha": return .symbol("α")
        case "beta": return .symbol("β")
        case "gamma": return .symbol("γ")
        case "delta": return .symbol("δ")
        case "epsilon": return .symbol("ε")
        case "theta": return .symbol("θ")
        case "lambda": return .symbol("λ")
        case "mu": return .symbol("μ")
        case "pi": return .symbol("π")
        case "sigma": return .symbol("σ")
        case "phi": return .symbol("φ")
        case "omega": return .symbol("ω")
        case "Delta": return .text("Δ")
        case "Omega": return .text("Ω")
        case "Sigma": return .text("Σ")
        case "pm": return .text("±")
        case "mp": return .text("∓")
        case "times": return .text("×")
        case "cdot": return .text("⋅")
        case "div": return .text("÷")
        case "approx": return .text("≈")
        case "neq", "ne": return .text("≠")
        case "le", "leq": return .text("≤")
        case "ge", "geq": return .text("≥")
        case "ll": return .text("≪")
        case "gg": return .text("≫")
        case "to": return .text("→")
        case "Rightarrow": return .text("⇒")
        case "infty": return .text("∞")
        case "deg": return .text("°")
        case "sin", "cos", "tan", "log", "ln", "exp", "max", "min", "lim":
            return .row([.text(name), .space(0.16)])
        case ",": return .space(0.166)
        case ";": return .space(0.277)
        case " ": return .space(0.25)
        case "quad": return .space(1.0)
        case "qquad": return .space(2.0)
        case "{": return .text("{")
        case "}": return .text("}")
        default: return nil
        }
    }

    /// 读一个参数：花括号分组、一个命令或单个字符；读不到返回 nil。
    private mutating func parseArgument() -> MathNode? {
        guard pos < chars.count else { return nil }
        let c = chars[pos]
        if c == "{" {
            pos += 1
            let inner = parseRow(stopAtBrace: true, inDelimiter: false)
            if pos < chars.count && chars[pos] == "}" { pos += 1 }
            return .row(inner)
        }
        if c == MathParser.backslash {
            return parseCommand()
        }
        pos += 1
        if c.isNumber || c == "." {
            var digits = String(c)
            while pos < chars.count && (chars[pos].isNumber || chars[pos] == ".") {
                digits.append(chars[pos])
                pos += 1
            }
            return .text(digits)
        }
        if c.isASCII && c.isLetter {
            return .symbol(String(c))
        }
        return .text(String(c))
    }

    /// 生成上下标节点；底数本身是上下标时合并，处理连续叠加的情况。
    private func makeScript(base: MathNode, isSuperscript: Bool, argument: MathNode?) -> MathNode {
        if case .script(let oldBase, let oldSup, let oldSub) = base {
            if isSuperscript {
                return .script(base: oldBase, sup: argument ?? oldSup, sub: oldSub)
            }
            return .script(base: oldBase, sup: oldSup, sub: argument ?? oldSub)
        }
        if isSuperscript {
            return .script(base: base, sup: argument, sub: nil)
        }
        return .script(base: base, sup: nil, sub: argument)
    }

    /// 读一个定界符：普通括号、竖线、转义花括号，或者不可见点。
    private mutating func parseDelimiter() -> String {
        guard pos < chars.count else { return "" }
        let c = chars[pos]
        pos += 1
        if c == MathParser.backslash {
            guard pos < chars.count else { return "" }
            let next = chars[pos]
            pos += 1
            return delimiterText(next)
        }
        return delimiterText(c)
    }

    /// 把单个字符归一化成实际显示的括号字形，点号表示不显示。
    private func delimiterText(_ c: Character) -> String {
        if c == "." { return "" }
        return String(c)
    }

    /// 读根指数用的方括号参数，取出原始子串再当独立公式解析一遍。
    private mutating func parseBracketArgument() -> MathNode? {
        guard pos < chars.count && chars[pos] == "[" else { return nil }
        pos += 1
        var raw = ""
        var depth = 0
        while pos < chars.count {
            let c = chars[pos]
            if c == "{" { depth += 1 }
            if c == "}" && depth > 0 { depth -= 1 }
            if c == "]" && depth == 0 {
                pos += 1
                break
            }
            raw.append(c)
            pos += 1
        }
        return .row(MathParser.parse(raw))
    }

    /// 判断一组节点里有没有分式或根号，决定括号要不要放大。
    private func containsTall(_ nodes: [MathNode]) -> Bool {
        for node in nodes {
            if nodeIsTall(node) { return true }
        }
        return false
    }

    /// 单个节点是否包含高结构，递归到嵌套的子节点。
    private func nodeIsTall(_ node: MathNode) -> Bool {
        switch node {
        case .frac:
            return true
        case .sqrt:
            return true
        case .row(let inner):
            return containsTall(inner)
        case .delimited(_, _, let inner, let tall):
            return tall || nodeIsTall(inner)
        case .script(let base, let sup, let sub):
            if nodeIsTall(base) { return true }
            if let supNode = sup, nodeIsTall(supNode) { return true }
            if let subNode = sub, nodeIsTall(subNode) { return true }
            return false
        case .text, .symbol, .space:
            return false
        }
    }
}

/// 公式根的渲染视图：解析一次后交给行视图排版，对外只暴露 tex、字号、颜色。
struct MathView: View {
    /// 原始 TeX 字符串，流式输入时可能不完整。
    private let tex: String

    /// 正文字号，分式与上下标在这个基础上按比例缩小。
    private let fontSize: CGFloat

    /// 整体文字颜色，默认与正文一致。
    private let color: Color

    /// 只要求 tex 必填，字号和颜色留给调用点覆盖。
    init(tex: String, fontSize: CGFloat = 17, color: Color = Theme.textPrimary) {
        self.tex = tex
        self.fontSize = fontSize
        self.color = color
    }

    /// 每次刷新重新解析：公式规模很小，省掉缓存和失效逻辑。
    var body: some View {
        MathNodeRow(nodes: MathParser.parse(tex), size: self.fontSize, color: self.color)
            .fixedSize()
    }
}

/// 一行节点的水平排版：零间距排开，公式里的空隙全部由 space 节点自己撑。
struct MathNodeRow: View {
    /// 这一行要排的节点。
    let nodes: [MathNode]

    /// 当前层级的字号。
    let size: CGFloat

    /// 当前层级的颜色。
    let color: Color

    /// 顺序排开每个节点，节点自己负责自己的版式。
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<nodes.count, id: \.self) { index in
                MathNodeView(node: self.nodes[index], size: self.size, color: self.color)
            }
        }
    }
}

/// 单个节点的渲染：分式、根式、上下标、定界符各走一条分支。
struct MathNodeView: View {
    /// 要画的节点。
    let node: MathNode

    /// 当前字号。
    let size: CGFloat

    /// 当前颜色。
    let color: Color

    /// 按节点类型选版式，每个分支只产出一个视图。
    var body: some View {
        switch node {
        case .text(let value):
            self.textBody(value)
        case .symbol(let value):
            self.symbolBody(value)
        case .space(let width):
            Color.clear.frame(width: self.size * width, height: 1)
        case .row(let children):
            MathNodeRow(nodes: children, size: self.size, color: self.color)
        case .frac(let numerator, let denominator):
            self.fracBody(numerator, denominator)
        case .sqrt(let rootIndex, let radicand):
            self.sqrtBody(rootIndex, radicand)
        case .script(let base, let sup, let sub):
            self.scriptBody(base, sup, sub)
        case .delimited(let open, let close, let inner, let tall):
            self.delimitedBody(open, close, inner, tall)
        }
    }

    /// 正体文本：数字和运算符用衬线正体，运算符两侧按字号让出一点空隙。
    private func textBody(_ value: String) -> some View {
        Text(value)
            .font(Font.system(size: self.size, design: .serif))
            .foregroundColor(self.color)
            .padding(.horizontal, self.isSpacedOperator(value) ? self.size * 0.08 : 0)
    }

    /// 判断是不是关系或二元运算符，这类符号两侧需要留白。
    private func isSpacedOperator(_ value: String) -> Bool {
        let operators: Set<String> = ["=", "+", "-", "±", "∓", "×", "⋅", "÷", "≈", "≠", "≤", "≥", "≪", "≫", "→", "⇒", "<", ">"]
        return operators.contains(value)
    }

    /// 斜体符号：变量和希腊字母用衬线斜体，和正体数字区分开。
    private func symbolBody(_ value: String) -> some View {
        Text(value)
            .font(Font.system(size: self.size, design: .serif).italic())
            .foregroundColor(self.color)
    }

    /// 分式：分子、横线、分母竖排，横线自然撑到较宽的一边。
    private func fracBody(_ numerator: MathNode, _ denominator: MathNode) -> some View {
        VStack(spacing: self.size * 0.10) {
            MathNodeView(node: numerator, size: self.size * 0.92, color: self.color)
            Rectangle()
                .fill(self.color.opacity(0.75))
                .frame(height: max(1, self.size * 0.06))
                .frame(maxWidth: .infinity)
            MathNodeView(node: denominator, size: self.size * 0.92, color: self.color)
        }
    }

    /// 根式：小号根指数抬到左上，内容用路径画出斜线和顶横线。
    private func sqrtBody(_ rootIndex: MathNode?, _ radicand: MathNode) -> some View {
        let hook = self.size * 0.62
        let topSpace = self.size * 0.16
        return HStack(alignment: .top, spacing: 0) {
            if let indexNode = rootIndex {
                MathNodeView(node: indexNode, size: self.size * 0.55, color: self.color)
                    .padding(.trailing, self.size * 0.05)
                    .offset(y: -self.size * 0.55)
            }
            MathNodeView(node: radicand, size: self.size, color: self.color)
                .padding(.leading, hook)
                .padding(.top, topSpace)
                .background(
                    MathRadicalShape(hook: hook, topSpace: topSpace)
                        .stroke(self.color, lineWidth: max(0.8, self.size * 0.06))
                )
        }
    }

    /// 上下标：底数后面接一排小字，单独上标时抬高一截。
    private func scriptBody(_ base: MathNode, _ sup: MathNode?, _ sub: MathNode?) -> some View {
        HStack(alignment: .center, spacing: 0) {
            MathNodeView(node: base, size: self.size, color: self.color)
            self.scriptStack(sup, sub)
        }
    }

    /// 上标下标的竖排：只有上标就上移，只有下标就下移，都有就上下各占一边。
    private func scriptStack(_ sup: MathNode?, _ sub: MathNode?) -> some View {
        let small = self.size * 0.7
        return VStack(alignment: .leading, spacing: 0) {
            if let supNode = sup {
                MathNodeView(node: supNode, size: small, color: self.color)
                    .offset(y: sub == nil ? -self.size * 0.30 : 0)
            }
            if let subNode = sub {
                MathNodeView(node: subNode, size: small, color: self.color)
                    .offset(y: sup == nil ? self.size * 0.30 : 0)
            }
        }
    }

    /// 定界符：内容够高时把括号字号放大一档，视觉上跟住分式与根号。
    private func delimitedBody(_ open: String, _ close: String, _ inner: MathNode, _ tall: Bool) -> some View {
        let bracketSize = tall ? self.size * 1.85 : self.size * 1.05
        return HStack(alignment: .center, spacing: 0) {
            if !open.isEmpty {
                Text(open)
                    .font(Font.system(size: bracketSize, weight: .light, design: .serif))
                    .foregroundColor(self.color)
            }
            MathNodeView(node: inner, size: self.size, color: self.color)
            if !close.isEmpty {
                Text(close)
                    .font(Font.system(size: bracketSize, weight: .light, design: .serif))
                    .foregroundColor(self.color)
            }
        }
    }
}

/// 根号的钩形轮廓：起笔、下探到底、斜上顶横线，全部画在内容矩形里。
struct MathRadicalShape: Shape {
    /// 左侧钩子占的宽度，必须和内容的左内边距一致才不歪。
    let hook: CGFloat

    /// 顶部为横线留出的空白，和内容的上内边距保持一致。
    let topSpace: CGFloat

    /// 在给定矩形里描出根号的折线。
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyTop = rect.minY + self.topSpace
        let bodyHeight = max(1, rect.maxY - bodyTop)
        path.move(to: CGPoint(x: rect.minX, y: bodyTop + bodyHeight * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + self.hook * 0.30, y: bodyTop + bodyHeight * 0.50))
        path.addLine(to: CGPoint(x: rect.minX + self.hook * 0.62, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + self.hook, y: bodyTop + 0.5))
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyTop + 0.5))
        return path
    }
}
