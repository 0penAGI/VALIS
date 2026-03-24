import SwiftUI
import CoreMotion

enum IntroGreetingCopy {
    static func current() -> String {
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.component(.hour, from: Date())
        let lang = (UserDefaults.standard.string(forKey: "lang.lastDetected") ?? Locale.preferredLanguages.first ?? "en")
            .lowercased()
        let isRU = lang.hasPrefix("ru")

        let band: Int = {
            if hour >= 22 || hour < 5 { return 0 }
            if hour < 12 { return 1 }
            if hour < 18 { return 2 }
            return 3
        }()

        if isRU {
            switch band {
            case 0: return "Доброй ночи.\n"
            case 1: return "Доброе утро.\nКакие планы?"
            case 2: return "Добрый день.\n"
            default: return "Добрый вечер.\n"
            }
        }

        switch band {
        case 0: return "Good night.\n"
        case 1: return "Good morning.\nWhat's the plan?"
        case 2: return "Good afternoon.\nWhat matters today?"
        default: return "Good evening.\n"
        }
    }
}

struct IntroGreetingView: View {
    let text: String
    let isTyping: Bool

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var motion = IntroMotionController()

    private var isDayMode: Bool {
        colorScheme != .dark
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                ZStack {
                    if isDayMode {
                        IntroDaylightField(
                            size: geo.size,
                            time: timeline.date.timeIntervalSinceReferenceDate,
                            motionOffset: CGSize(
                                width: motion.roll * 34,
                                height: motion.pitch * 24
                            )
                        )
                    } else {
                        IntroStarField(
                            size: geo.size,
                            time: timeline.date.timeIntervalSinceReferenceDate,
                            motionOffset: CGSize(
                                width: motion.roll * 38,
                                height: motion.pitch * 32
                            )
                        )
                    }

                    VStack {
                        Spacer(minLength: max(120, geo.safeAreaInsets.top + 120))

                        Text(text)
                            .font(.system(size: 34, weight: .ultraLight, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(isDayMode ? 0.76 : 0.72))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.horizontal, 30)
                            .blur(radius: isTyping ? 12 : 0)
                            .scaleEffect(isTyping ? 0.97 : 1.0)
                            .opacity(isTyping ? 0 : 1)
                            .animation(.easeOut(duration: 0.22), value: isTyping)

                        Spacer()
                    }
                }
                .opacity(isTyping ? 0.35 : 1.0)
                .animation(.easeOut(duration: 0.22), value: isTyping)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height + 120)
            .offset(y: -40)
        }
    }
}

private struct IntroStarField: View {
    let size: CGSize
    let time: TimeInterval
    let motionOffset: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            for star in IntroStarSeed.samples {
                let driftX = CGFloat(sin(time * star.speed + star.driftPhaseX)) * (8 + star.depth * 10)
                let driftY = CGFloat(cos(time * (star.speed * 0.82) + star.driftPhaseY)) * (6 + star.depth * 8)

                let x = star.x * canvasSize.width + motionOffset.width * star.depth + driftX
                let adjustedY = star.y * canvasSize.height + motionOffset.height * star.depth + driftY
                let twinkle = 0.72 + 0.28 * sin(time * star.twinkleSpeed + star.twinklePhase)
                let radius = star.radius * (star.depth > 0.7 ? 1.18 : 1.0) * CGFloat(0.96 + twinkle * 0.14)
                let haloRadius = radius * (star.depth > 0.72 ? 7.4 : 5.4)
                let flareLength = radius * (star.depth > 0.75 ? 18 : 11)
                let coreOpacity = min(1.0, star.opacity * (0.82 + twinkle * 0.42))
                let haloOpacity = star.opacity * (star.depth > 0.72 ? 0.22 : 0.14) * twinkle
                let flareOpacity = star.opacity * (star.depth > 0.7 ? 0.26 : 0.12) * twinkle

                let haloRect = CGRect(x: x - haloRadius, y: adjustedY - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
                let rect = CGRect(x: x - radius, y: adjustedY - radius, width: radius * 2, height: radius * 2)

                context.fill(
                    Path(ellipseIn: haloRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color.white.opacity(haloOpacity),
                            Color.white.opacity(haloOpacity * 0.45),
                            Color.clear
                        ]),
                        center: CGPoint(x: haloRect.midX, y: haloRect.midY),
                        startRadius: 0,
                        endRadius: haloRadius
                    )
                )

                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color.white.opacity(coreOpacity))
                )

                if star.depth > 0.58 {
                    let verticalRect = CGRect(x: x - 0.65, y: adjustedY - flareLength, width: 1.3, height: flareLength * 2)
                    let horizontalRect = CGRect(x: x - flareLength, y: adjustedY - 0.65, width: flareLength * 2, height: 1.3)

                    context.fill(
                        Path(roundedRect: verticalRect, cornerRadius: 1),
                        with: .linearGradient(
                            Gradient(colors: [Color.clear, Color.white.opacity(flareOpacity), Color.clear]),
                            startPoint: CGPoint(x: verticalRect.midX, y: verticalRect.minY),
                            endPoint: CGPoint(x: verticalRect.midX, y: verticalRect.maxY)
                        )
                    )
                    context.fill(
                        Path(roundedRect: horizontalRect, cornerRadius: 1),
                        with: .linearGradient(
                            Gradient(colors: [Color.clear, Color.white.opacity(flareOpacity * 0.92), Color.clear]),
                            startPoint: CGPoint(x: horizontalRect.minX, y: horizontalRect.midY),
                            endPoint: CGPoint(x: horizontalRect.maxX, y: horizontalRect.midY)
                        )
                    )
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
    }
}

private struct IntroDaylightSeed {
    struct Orb {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let speed: Double
        let phaseX: Double
        let phaseY: Double
        let travel: CGFloat
        let depth: CGFloat
        let color: Color
    }

    struct Ribbon {
        let y: CGFloat
        let height: CGFloat
        let speed: Double
        let phase: Double
        let depth: CGFloat
        let color: Color
    }

    struct Dust {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let speed: Double
        let phase: Double
        let depth: CGFloat
        let opacity: Double
    }

    static let orbs: [Orb] = [
        Orb(x: 0.18, y: 0.22, radius: 0.24, speed: 0.16, phaseX: 0.3, phaseY: 1.4, travel: 28, depth: 0.8, color: Color(red: 0.55, green: 0.76, blue: 1.0)),
        Orb(x: 0.76, y: 0.18, radius: 0.22, speed: 0.11, phaseX: 1.2, phaseY: 2.0, travel: 22, depth: 0.6, color: Color(red: 1.0, green: 0.82, blue: 0.58)),
        Orb(x: 0.68, y: 0.58, radius: 0.27, speed: 0.09, phaseX: 2.8, phaseY: 0.7, travel: 18, depth: 0.45, color: Color(red: 0.66, green: 0.9, blue: 0.86)),
        Orb(x: 0.28, y: 0.72, radius: 0.21, speed: 0.12, phaseX: 0.9, phaseY: 2.7, travel: 20, depth: 0.55, color: Color(red: 1.0, green: 0.73, blue: 0.78))
    ]

    static let ribbons: [Ribbon] = [
        Ribbon(y: 0.28, height: 46, speed: 0.18, phase: 0.4, depth: 0.5, color: Color.white),
        Ribbon(y: 0.64, height: 54, speed: 0.13, phase: 1.7, depth: 0.35, color: Color(red: 1.0, green: 0.96, blue: 0.92))
    ]

    static let dust: [Dust] = {
        var state: UInt64 = 0xA11CE123
        func next() -> Double {
            state = state &* 1103515245 &+ 12345
            return Double(state % 10_000) / 10_000.0
        }

        return (0..<52).map { _ in
            Dust(
                x: next(),
                y: next(),
                radius: 0.8 + next() * 2.4,
                speed: 0.1 + next() * 0.35,
                phase: next() * .pi * 2,
                depth: 0.2 + next() * 0.8,
                opacity: 0.08 + next() * 0.12
            )
        }
    }()
}

private struct IntroDaylightField: View {
    let size: CGSize
    let time: TimeInterval
    let motionOffset: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let baseRect = CGRect(origin: .zero, size: canvasSize)
            context.fill(
                Path(baseRect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.95, green: 0.97, blue: 1.0),
                        Color(red: 0.88, green: 0.93, blue: 1.0),
                        Color(red: 0.98, green: 0.92, blue: 0.84)
                    ]),
                    startPoint: CGPoint(x: baseRect.minX, y: baseRect.minY),
                    endPoint: CGPoint(x: baseRect.maxX, y: baseRect.maxY)
                )
            )

            for orb in IntroDaylightSeed.orbs {
                let driftX = CGFloat(sin(time * orb.speed + orb.phaseX)) * orb.travel + motionOffset.width * orb.depth
                let driftY = CGFloat(cos(time * (orb.speed * 0.8) + orb.phaseY)) * (orb.travel * 0.66) + motionOffset.height * orb.depth
                let center = CGPoint(
                    x: orb.x * canvasSize.width + driftX,
                    y: orb.y * canvasSize.height + driftY
                )
                let radius = orb.radius * min(canvasSize.width, canvasSize.height)

                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                context.addFilter(.blur(radius: 24 * orb.depth))
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            orb.color.opacity(0.34),
                            orb.color.opacity(0.16),
                            Color.clear
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }

            for ribbon in IntroDaylightSeed.ribbons {
                let wave = CGFloat(sin(time * ribbon.speed + ribbon.phase)) * 24
                let y = ribbon.y * canvasSize.height + wave + motionOffset.height * ribbon.depth
                let rect = CGRect(x: -40, y: y, width: canvasSize.width + 80, height: ribbon.height)
                context.addFilter(.blur(radius: 18))
                context.fill(
                    Path(roundedRect: rect, cornerRadius: ribbon.height * 0.5),
                    with: .linearGradient(
                        Gradient(colors: [
                            ribbon.color.opacity(0),
                            ribbon.color.opacity(0.22),
                            ribbon.color.opacity(0)
                        ]),
                        startPoint: CGPoint(x: rect.minX, y: rect.midY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                    )
                )
            }

            for dust in IntroDaylightSeed.dust {
                let x = dust.x * canvasSize.width + CGFloat(sin(time * dust.speed + dust.phase)) * 18 + motionOffset.width * dust.depth
                let y = dust.y * canvasSize.height + CGFloat(cos(time * (dust.speed * 0.75) + dust.phase)) * 10 + motionOffset.height * dust.depth
                let rect = CGRect(x: x, y: y, width: dust.radius, height: dust.radius)
                context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(dust.opacity)))
            }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
    }
}

private struct IntroStarSeed {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let opacity: Double
    let speed: Double
    let depth: CGFloat
    let twinklePhase: Double
    let twinkleSpeed: Double
    let driftPhaseX: Double
    let driftPhaseY: Double

    static let samples: [IntroStarSeed] = {
        var state: UInt64 = 0x5EED1234
        func next() -> Double {
            state = state &* 2862933555777941757 &+ 3037000493
            return Double(state % 10_000) / 10_000.0
        }

        return (0..<42).map { _ in
            let depth = 0.25 + next() * 0.95
            return IntroStarSeed(
                x: next(),
                y: next(),
                radius: 0.8 + next() * 1.9,
                opacity: 0.18 + next() * 0.62,
                speed: 0.012 + next() * 0.06,
                depth: depth,
                twinklePhase: next() * .pi * 2,
                twinkleSpeed: 0.6 + next() * 1.8,
                driftPhaseX: next() * .pi * 2,
                driftPhaseY: next() * .pi * 2
            )
        }
    }()
}

#Preview {
    IntroGreetingView(text: "Good morning.\nWhat's the plan?", isTyping: false)
}

@MainActor
private final class IntroMotionController: ObservableObject {
    @Published var pitch: CGFloat = 0
    @Published var roll: CGFloat = 0

    private let motionManager = CMMotionManager()

    init() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.pitch = max(-1, min(1, CGFloat(motion.attitude.pitch)))
            self.roll = max(-1, min(1, CGFloat(motion.attitude.roll)))
        }
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}
