import SwiftUI

/// App 的视觉底层：近黑底、比底色亮一档的面、1px 低对比描边、一个低饱和蓝紫强调色。
/// 全用手写色值不用系统语义色：深色下要压住系统蓝的饱和度，也让壁纸和内容共用同一套层次。
enum Theme {

    // MARK: - 颜色

    /// 页面底。不用纯黑：纯黑在 OLED 上边缘发飘，和卡片之间也拉不出第一层。
    static let bg = Color(red: 11.0 / 255.0, green: 12.0 / 255.0, blue: 16.0 / 255.0)

    /// 卡片面。比底色亮一档，刚好浮起来，又没到"另一个颜色"的程度。
    static let surface = Color(red: 20.0 / 255.0, green: 22.0 / 255.0, blue: 28.0 / 255.0)

    /// 更高的面：输入框、悬浮层、选中行。第二档亮，和 surface 拉开但别跳。
    static let surfaceStrong = Color(red: 27.0 / 255.0, green: 30.0 / 255.0, blue: 38.0 / 255.0)

    /// 描边。白 8% 只勾轮廓，不能抢内容；深色界面的边界靠它，不靠阴影。
    static let stroke = Color.white.opacity(0.08)

    /// 正文色。纯白在深底上发刺，压到 #F2F3F5，长时间读眼睛更省力。
    static let textPrimary = Color(red: 242.0 / 255.0, green: 243.0 / 255.0, blue: 245.0 / 255.0)

    /// 次要文字：时间戳、说明、状态。靠透明度降级，不换色相，免得整屏色彩失衡。
    static let textSecondary = Color.white.opacity(0.55)

    /// 三级文字：占位符、禁用态、辅助说明。
    static let textTertiary = Color.white.opacity(0.35)

    /// 唯一的强调色，低饱和蓝紫。全 App 只有它和三个语义色允许带彩度。
    static let accent = Color(red: 108.0 / 255.0, green: 140.0 / 255.0, blue: 255.0 / 255.0)

    /// 强调色的淡底：选中行、标签、轻提示。铺面不压字，所以透明度一定要低。
    static let accentSoft = accent.opacity(0.18)

    /// 错误。深底上要够亮才读得出是"坏了"，但又不能亮成霓虹。
    static let danger = Color(red: 1.0, green: 107.0 / 255.0, blue: 107.0 / 255.0)

    /// 警告：运行中提示、可恢复的失败。
    static let warning = Color(red: 1.0, green: 180.0 / 255.0, blue: 84.0 / 255.0)

    /// 成功：工具跑完、写入完成这类短状态。
    static let success = Color(red: 74.0 / 255.0, green: 222.0 / 255.0, blue: 128.0 / 255.0)

    // MARK: - 字体

    /// 等宽小字：路径、代码、工具输出。机器文本用等宽才对得齐。
    static let monoSmall = Font.system(size: 12, design: .monospaced)

    /// 标题：圆体比默认字体暖一点，和硬朗的深色底形成对比。
    static func title(_ size: CGFloat) -> Font {
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    /// 正文。字号交给调用点，这里只锁字重和字形。
    static func body(_ size: CGFloat) -> Font {
        return .system(size: size, weight: .regular)
    }

    // MARK: - 圆角与间距

    /// 卡片圆角。14 在 iPad 上既不显得软，也不至于读成方块。
    static let radius: CGFloat = 14

    /// 小的面：输入框、标签、按钮。
    static let radiusSmall: CGFloat = 10

    /// 页面统一边距。宁可少一个能调的参数，也别让每页各缩各的。
    static let pad: CGFloat = 16

    // MARK: - 底色渐变

    /// 没有壁纸时的底色：两个相邻色相从偏蓝黑过渡到更深的黑，只在近黑里动，不会显脏。
    static let bgGradient = LinearGradient(
        colors: [
            Color(red: 15.0 / 255.0, green: 17.0 / 255.0, blue: 25.0 / 255.0),
            Color(red: 8.0 / 255.0, green: 9.0 / 255.0, blue: 13.0 / 255.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension View {

    /// 卡片：surface 底 + 1px 描边 + 统一圆角。全 App 只保留这一种"卡片"。
    func dshCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }

    /// 输入类控件的面：比卡片更凹一档，免得输入框被读成一块普通卡片。
    func dshFieldChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
