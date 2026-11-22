import SwiftUI

/// 启动动画的画面本体：糊掉的壁纸打底，光晕亮起，光带扫过，最后 DSH 字标压上来。
/// 入场节奏全部在这里（约 1.3 秒走完）；淡出和收尾交给 LaunchSplashOverlay。
/// 挂法：直接把它塞进任意全屏容器就能看效果，不依赖外部素材。
struct LaunchSplashView: View {
    @ObservedObject private var wallpaper = WallpaperStore.shared

    @State private var haloIn: Double = 0
    @State private var emblemIn: Double = 0
    @State private var spin: Double = 0
    @State private var sweepIn: Double = 0
    @State private var wordmarkIn: Double = 0
    @State private var subtitleIn: Double = 0
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg

                wallpaperBase

                Color.black.opacity(0.34)

                halo

                centerpiece

                sweep(geo: geo)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .background(Theme.bg.ignoresSafeArea())
        .onAppear(perform: startAnimations)
    }

    // MARK: - 图层

    /// 垫底的壁纸：有图就用图糊掉，没图退回主题渐变，两种都不空。
    @ViewBuilder
    private var wallpaperBase: some View {
        if let image = wallpaper.image {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(1.08)
                    .blur(radius: 30)
                    .clipped()
            }
            .opacity(0.9)
        } else {
            LinearGradient(
                colors: [
                    Color(red: 15 / 255, green: 17 / 255, blue: 25 / 255),
                    Color(red: 8 / 255, green: 9 / 255, blue: 13 / 255)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// 光晕：中心一团辉光 + 一圈细边 + 一段转着的弧。
    private var halo: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.42), Theme.accent.opacity(0)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 190
                    )
                )
                .frame(width: 380, height: 380)
                .scaleEffect(0.82 + haloIn * 0.28)
                .opacity(haloIn)

            Circle()
                .strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1)
                .frame(width: 134, height: 134)
                .scaleEffect(0.92 + haloIn * 0.08)
                .opacity(haloIn)

            Circle()
                .trim(from: 0.05, to: 0.33)
                .stroke(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0), Theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .frame(width: 154, height: 154)
                .rotationEffect(.degrees(spin))
                .opacity(haloIn * 0.9)
        }
    }

    /// 中心徽标 + 字标。三段错开淡入，压着光晕的中心走。
    private var centerpiece: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Theme.surfaceStrong.opacity(0.92))
                Circle()
                    .strokeBorder(Theme.stroke, lineWidth: 1)
                VStack(spacing: 7) {
                    SplashWave()
                        .stroke(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.95), Color.white.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                        )
                        .frame(width: 46, height: 14)
                    SplashWave()
                        .stroke(
                            Theme.accent.opacity(0.42),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .frame(width: 32, height: 12)
                }
            }
            .frame(width: 112, height: 112)
            .scaleEffect(0.86 + emblemIn * 0.14)
            .opacity(emblemIn)

            Text("DSH")
                .font(Theme.title(38))
                .tracking(7)
                .foregroundColor(Theme.textPrimary)
                .padding(.top, 22)
                .opacity(wordmarkIn)
                .offset(y: (1 - wordmarkIn) * 10)

            Text("DeepSeek Harness")
                .font(Theme.monoSmall)
                .tracking(2.4)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 8)
                .opacity(subtitleIn)
                .offset(y: (1 - subtitleIn) * 8)
        }
    }

    /// 斜着扫过全屏的光带。用 plusLighter 混，扫过的地方像被提亮而不是盖了一层白。
    private func sweep(geo: GeometryProxy) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.14),
                        Theme.accent.opacity(0.30),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 170, height: geo.size.height * 1.8)
            .rotationEffect(.degrees(20))
            .offset(x: -geo.size.width * 0.85 + sweepIn * geo.size.width * 1.9)
            .blendMode(.plusLighter)
            .opacity(sweepIn > 0 ? 1 : 0)
    }

    // MARK: - 节奏

    private func startAnimations() {
        guard !started else { return }
        started = true

        withAnimation(.easeOut(duration: 0.5)) {
            haloIn = 1
            emblemIn = 1
        }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            spin = 360
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            withAnimation(.easeInOut(duration: 0.52)) {
                sweepIn = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            withAnimation(.easeOut(duration: 0.38)) {
                wordmarkIn = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.92) {
            withAnimation(.easeOut(duration: 0.32)) {
                subtitleIn = 1
            }
        }
    }
}

/// 启动页的全屏容器：盖上动画、按时间淡出、然后回调放人进来。
/// 用法：`LaunchSplashOverlay { showSplash = false }`，挂在最外层 ZStack 最后一位即可。
struct LaunchSplashOverlay: View {
    let onFinish: () -> Void
    var duration: Double = 1.66
    var fadeOut: Double = 0.34

    @State private var opacity: Double = 1
    @State private var scheduled = false

    var body: some View {
        LaunchSplashView()
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear(perform: scheduleFinish)
    }

    private func scheduleFinish() {
        guard !scheduled else { return }
        scheduled = true

        let fadeStart = max(0.3, duration - fadeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart) {
            withAnimation(.easeIn(duration: fadeOut)) {
                opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            onFinish()
        }
    }
}

/// 徽标里那道波浪：两段对称的三次贝塞尔，像水波也像鲸尾划过。
private struct SplashWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let amp = rect.height * 0.30
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.18, y: midY - amp),
            control2: CGPoint(x: rect.minX + rect.width * 0.32, y: midY + amp)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: midY),
            control1: CGPoint(x: rect.midX + rect.width * 0.18, y: midY - amp),
            control2: CGPoint(x: rect.midX + rect.width * 0.32, y: midY + amp)
        )
        return path
    }
}
