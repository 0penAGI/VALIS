import SwiftUI
import CoreMotion
import UIKit

// MARK: - Copy

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
            case 0: return "Доброй ночи\n"
            case 1: return "Доброе утро\nКакие планы?"
            case 2: return "Добрый день\n"
            default: return "Добрый вечер\n"
            }
        }

        switch band {
        case 0: return "Good night\n"
        case 1: return "Good morning\nWhat's the plan?"
        case 2: return "Good afternoon\nWhat matters today?"
        default: return "Good evening\n"
        }
    }
}

// MARK: - Helpers

private func introHash(_ n: Double) -> Double {
    let s = sin(n * 12.9898) * 43758.5453
    return s - floor(s)
}

// MARK: - Greeting view

struct IntroGreetingView: View {
    let text: String
    let isTyping: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion = IntroMotionController()
    @State private var taps: [TapWave] = []
    @State private var activeAttractorID: UUID?
    @State private var keyboardHeight: CGFloat = 0
    @State private var appeared = false
    @State private var crossfading = false

    private var isDayMode: Bool {
        colorScheme != .dark
    }

    struct TapWave {
        var id: UUID
        var point: CGPoint
        var start: TimeInterval
        var releasedAt: TimeInterval?

        func strength(at time: TimeInterval) -> Double {
            if let releasedAt {
                return max(0, 1 - (time - releasedAt) / 0.55)
            }
            return min(1, max(0, (time - start) / 0.24))
        }
    }

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: false)) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let k: CGFloat = reduceMotion ? 0 : 1

                ZStack {
                    // Night always sits underneath; day fades in/out above it.
                    // No view swap, so there is no hard cut or broken frame at the seam.
                    if !isDayMode || crossfading {
                        IntroStarField(
                            size: geo.size,
                            time: now,
                            motionOffset: CGSize(width: motion.roll * 38 * k, height: motion.pitch * 32 * k),
                            taps: taps
                        )
                    }

                    if isDayMode || crossfading {
                        IntroDaylightField(
                            size: geo.size,
                            time: now,
                            motionOffset: CGSize(width: motion.roll * 34 * k, height: motion.pitch * 24 * k)
                        )
                        .opacity(isDayMode ? 1 : 0)
                        .animation(.easeInOut(duration: 1.4), value: isDayMode)
                    }

                    VStack {
                        Spacer(minLength: max(120, geo.safeAreaInsets.top + 120) + (keyboardHeight > 0 ? 20 : 0))
                        greeting(now: now)
                        Spacer()
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let now = Date().timeIntervalSinceReferenceDate
                            if let activeAttractorID,
                               let index = taps.firstIndex(where: { $0.id == activeAttractorID }) {
                                taps[index].point = value.location
                            } else {
                                taps.removeAll { tap in
                                    guard let releasedAt = tap.releasedAt else { return false }
                                    return now - releasedAt > 0.55
                                }
                                let id = UUID()
                                taps.append(TapWave(id: id, point: value.location, start: now, releasedAt: nil))
                                activeAttractorID = id
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.45)
                            }
                        }
                        .onEnded { value in
                            let now = Date().timeIntervalSinceReferenceDate
                            if let activeAttractorID,
                               let index = taps.firstIndex(where: { $0.id == activeAttractorID }) {
                                taps[index].point = value.location
                                taps[index].releasedAt = now
                            }
                            activeAttractorID = nil
                        }
                )
                .opacity(isTyping ? (isDayMode ? 0.88 : 0.78) : 1.0)
                .animation(.easeOut(duration: 0.22), value: isTyping)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height + 120)
            .offset(y: -40)
        }
        .onAppear {
            withAnimation { appeared = true }
        }
        .onChange(of: colorScheme) { _, _ in
            crossfading = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                crossfading = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
            if let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    @ViewBuilder
    private func greeting(now: TimeInterval) -> some View {
        let baseOpacity = isDayMode ? 0.76 : 0.72

        // Appear = plain opacity fade. No blur on the way in: blurring thin text over pure black bands into steps.
        let label = Text(text)
            .font(.system(size: 34, weight: .ultraLight, design: .rounded))
            .foregroundStyle(Color.primary.opacity(baseOpacity))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 30)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 1.1).delay(0.15), value: appeared)

        Group {
            if isDayMode {
                label.shadow(color: Color.white.opacity(0.9), radius: 22)
            } else {
                label
            }
        }
        .blur(radius: isTyping ? 12 : 0)
        .scaleEffect((isTyping ? 0.97 : 1.0) * (keyboardHeight > 0 ? 0.92 : 1.0))
        .offset(y: keyboardHeight > 0 ? -keyboardHeight * 0.25 : 0)
        .opacity(isTyping ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: isTyping)
        .animation(.easeOut(duration: 0.3), value: keyboardHeight)
    }
}

// MARK: - Night

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
    let tint: Color

    static let samples: [IntroStarSeed] = {
        var state: UInt64 = 0x5EED1234
        func next() -> Double {
            state = state &* 2862933555777941757 &+ 3037000493
            return Double((state >> 33) % 10_000) / 10_000.0
        }

        let tints: [Color] = [Color.white]

        return (0..<64).map { _ in
            let depth = 0.25 + next() * 0.95
            let tint = tints[Int(next() * Double(tints.count)) % tints.count]
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
                driftPhaseY: next() * .pi * 2,
                tint: tint
            )
        }
    }()
}

private struct IntroStarField: View {
    let size: CGSize
    let time: TimeInterval
    let motionOffset: CGSize
    let taps: [IntroGreetingView.TapWave]

    private struct StarMotion {
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var velocityX: CGFloat = 0
        var velocityY: CGFloat = 0
    }

    @State private var starMotions = Array(
        repeating: StarMotion(),
        count: IntroStarSeed.samples.count
    )

    private func advanceGravity(from oldTime: TimeInterval, to newTime: TimeInterval) {
        let dt = CGFloat(min(max(newTime - oldTime, 0), 0.05))
        guard dt > 0 else { return }

        var nextMotions = starMotions
        for (index, star) in IntroStarSeed.samples.enumerated() {
            let driftX = CGFloat(sin(newTime * star.speed + star.driftPhaseX)) * 4
            let driftY = CGFloat(cos(newTime * (star.speed * 0.82) + star.driftPhaseY)) * 3
            let x = star.x * size.width + motionOffset.width * star.depth + driftX + nextMotions[index].offsetX
            let y = star.y * size.height + motionOffset.height * star.depth + driftY + nextMotions[index].offsetY

            var accelerationX: CGFloat = 0
            var accelerationY: CGFloat = 0
            var hasGravity = false
            for tap in taps {
                let strength = CGFloat(tap.strength(at: newTime))
                guard strength > 0.001 else { continue }
                hasGravity = true

                let dx = tap.point.x - x
                let dy = tap.point.y - y
                let distanceSquared = dx * dx + dy * dy
                let softenedDistance = distanceSquared + 34 * 34
                let gravity = min(900, 1_800_000 / softenedDistance) * strength
                let inverseDistance = 1 / max(1, sqrt(distanceSquared))
                accelerationX += dx * inverseDistance * gravity
                accelerationY += dy * inverseDistance * gravity
            }

            // Gravity accelerates stars while the touch is active. After release,
            // keep their momentum and let gentle drag slow them without snapping back.
            nextMotions[index].velocityX += accelerationX * dt
            nextMotions[index].velocityY += accelerationY * dt
            let drag = exp(-(hasGravity ? 0.18 : 0.32) * dt)
            nextMotions[index].velocityX *= drag
            nextMotions[index].velocityY *= drag

            nextMotions[index].offsetX += nextMotions[index].velocityX * dt
            nextMotions[index].offsetY += nextMotions[index].velocityY * dt
        }
        starMotions = nextMotions
    }

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let baseRect = CGRect(origin: .zero, size: canvasSize)

            // Pure black, nothing else
            context.fill(Path(baseRect), with: .color(Color.black))

            // Stars
            for (index, star) in IntroStarSeed.samples.enumerated() {
                let driftX = CGFloat(sin(time * star.speed + star.driftPhaseX)) * 4
                let driftY = CGFloat(cos(time * (star.speed * 0.82) + star.driftPhaseY)) * 3

                let x = star.x * w + motionOffset.width * star.depth + driftX + starMotions[index].offsetX
                let y = star.y * h + motionOffset.height * star.depth + driftY + starMotions[index].offsetY
                let twinkle = 0.72 + 0.28 * sin(time * star.twinkleSpeed + star.twinklePhase)

                // A restrained local glimmer reveals the gravitational field without drawing a ripple.
                var boost: Double = 0
                for tap in taps {
                    let strength = tap.strength(at: time)
                    guard strength > 0.001 else { continue }
                    let distance = hypot(x - tap.point.x, y - tap.point.y)
                    boost += strength * exp(-Double(distance / 150)) * 0.55
                }
                boost = min(boost, 1.4)

                let radius = star.radius * 0.75 * (1 + CGFloat(boost) * 0.9)
                let haloRadius = radius * 4.5
                let flareLength = radius * 10
                let coreOpacity = min(1.0, star.opacity * (0.6 + twinkle * 0.28) + boost * 0.6)
                let haloOpacity = star.opacity * 0.07 + boost * 0.14
                let flareOpacity = star.opacity * 0.08 + boost * 0.12

                let haloRect = CGRect(x: x - haloRadius, y: y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
                let coreRect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)

                context.fill(
                    Path(ellipseIn: haloRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            star.tint.opacity(haloOpacity),
                            star.tint.opacity(haloOpacity * 0.45),
                            Color.clear
                        ]),
                        center: CGPoint(x: haloRect.midX, y: haloRect.midY),
                        startRadius: 0,
                        endRadius: haloRadius
                    )
                )

                context.fill(Path(ellipseIn: coreRect), with: .color(star.tint.opacity(coreOpacity)))

                if star.depth > 0.85 || boost > 0.5 {
                    let vRect = CGRect(x: x - 0.65, y: y - flareLength, width: 1.3, height: flareLength * 2)
                    let hRect = CGRect(x: x - flareLength, y: y - 0.65, width: flareLength * 2, height: 1.3)

                    context.fill(
                        Path(roundedRect: vRect, cornerRadius: 1),
                        with: .linearGradient(
                            Gradient(colors: [Color.clear, star.tint.opacity(flareOpacity), Color.clear]),
                            startPoint: CGPoint(x: vRect.midX, y: vRect.minY),
                            endPoint: CGPoint(x: vRect.midX, y: vRect.maxY)
                        )
                    )
                    context.fill(
                        Path(roundedRect: hRect, cornerRadius: 1),
                        with: .linearGradient(
                            Gradient(colors: [Color.clear, star.tint.opacity(flareOpacity * 0.92), Color.clear]),
                            startPoint: CGPoint(x: hRect.minX, y: hRect.midY),
                            endPoint: CGPoint(x: hRect.maxX, y: hRect.midY)
                        )
                    )
                }
            }

            // A rare shooting star. Time isn't linear: some cycles stay silent.
            let period = 9.0
            let cycle = floor(time / period)
            let local = time - cycle * period
            let life = 1.0
            if local < life && introHash(cycle) > 0.4 {
                let p = local / life
                let fade = sin(p * .pi)
                let startX = CGFloat(0.15 + introHash(cycle + 1) * 0.7) * w
                let startY = CGFloat(0.05 + introHash(cycle + 2) * 0.30) * h
                let dir: CGFloat = introHash(cycle + 3) > 0.5 ? 1 : -1
                let angle = CGFloat(0.5 + introHash(cycle + 4) * 0.3)
                let dx = cos(angle) * dir
                let dy = sin(angle)
                let travel = w * 0.6 * CGFloat(p)
                let head = CGPoint(x: startX + dx * travel, y: startY + dy * travel)
                let tailLength = 150 * CGFloat(fade)
                let tail = CGPoint(x: head.x - dx * tailLength, y: head.y - dy * tailLength)

                var path = Path()
                path.move(to: tail)
                path.addLine(to: head)
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [Color.clear, Color.white.opacity(0.6 * fade)]),
                        startPoint: tail,
                        endPoint: head
                    ),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                )
                let headRect = CGRect(x: head.x - 1.4, y: head.y - 1.4, width: 2.8, height: 2.8)
                context.fill(Path(ellipseIn: headRect), with: .color(Color.white.opacity(0.9 * fade)))
            }

        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
        .onChange(of: time) { oldTime, newTime in
            advanceGravity(from: oldTime, to: newTime)
        }
    }
}

// MARK: - Day

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
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 10_000) / 10_000.0
        }

        return (0..<52).map { _ in
            Dust(
                x: next(),
                y: next(),
                radius: 0.8 + next() * 2.4,
                speed: 0.1 + next() * 0.35,
                phase: next() * .pi * 2,
                depth: 0.2 + next() * 0.8,
                opacity: 0.10 + next() * 0.16
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
            let w = canvasSize.width
            let h = canvasSize.height
            let baseRect = CGRect(origin: .zero, size: canvasSize)

            // Sky
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

            // Sun bloom in the upper corner, slowly breathing
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 50))
                let cx = w * 0.86 + CGFloat(sin(time * 0.13)) * 22 + motionOffset.width * 0.5
                let cy = h * 0.07 + CGFloat(cos(time * 0.17)) * 14 + motionOffset.height * 0.5
                let r = min(w, h) * (0.55 + 0.03 * CGFloat(sin(time * 0.4)))
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                layer.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 1.0, green: 0.94, blue: 0.78).opacity(0.80),
                            Color(red: 1.0, green: 0.88, blue: 0.70).opacity(0.26),
                            Color.clear
                        ]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0,
                        endRadius: r
                    )
                )
            }

            // Slow non-looping colour field
            context.drawLayer { layer in
                let t = time
                let flowX = sin(t * 0.23) * 40 + cos(t * 0.11) * 26
                let flowY = cos(t * 0.19) * 34 + sin(t * 0.07) * 18

                layer.translateBy(
                    x: CGFloat(flowX) + motionOffset.width * 0.4,
                    y: CGFloat(flowY) + motionOffset.height * 0.4
                )

                let gradient = Gradient(colors: [
                    Color(red: 0.6, green: 0.8, blue: 1.0).opacity(0.10),
                    Color(red: 1.0, green: 0.85, blue: 0.6).opacity(0.08),
                    Color(red: 0.7, green: 0.9, blue: 0.9).opacity(0.06),
                    Color.clear
                ])

                let rect = CGRect(x: -w * 0.3, y: -h * 0.3, width: w * 1.6, height: h * 1.6)

                layer.addFilter(.blur(radius: 60))
                layer.opacity = 0.6
                layer.fill(
                    Path(rect),
                    with: .radialGradient(
                        gradient,
                        center: CGPoint(
                            x: rect.midX + CGFloat(sin(t * 0.31)) * 120,
                            y: rect.midY + CGFloat(cos(t * 0.27)) * 90
                        ),
                        startRadius: 0,
                        endRadius: max(rect.width, rect.height)
                    )
                )
            }

            // Orbs. Each one gets its own layer so blur never leaks onto later draws.
            for orb in IntroDaylightSeed.orbs {
                let driftX = CGFloat(sin(time * orb.speed + orb.phaseX)) * orb.travel + motionOffset.width * orb.depth
                let driftY = CGFloat(cos(time * (orb.speed * 0.8) + orb.phaseY)) * (orb.travel * 0.66) + motionOffset.height * orb.depth
                let center = CGPoint(x: orb.x * w + driftX, y: orb.y * h + driftY)
                let pulse = 1 + 0.06 * CGFloat(sin(time * 0.35 + orb.phaseX))
                let radius = orb.radius * min(w, h) * pulse
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 24 * orb.depth))
                    layer.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [
                                orb.color.opacity(0.36),
                                orb.color.opacity(0.16),
                                Color.clear
                            ]),
                            center: center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }

                // soft echo
                let echoX = CGFloat(sin(time * 0.6 + orb.phaseX)) * 10 * orb.depth
                let echoY = CGFloat(cos(time * 0.5 + orb.phaseY)) * 10 * orb.depth
                let echoRect = rect.offsetBy(dx: echoX, dy: echoY)

                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 18 * orb.depth))
                    layer.fill(
                        Path(ellipseIn: echoRect),
                        with: .radialGradient(
                            Gradient(colors: [orb.color.opacity(0.08), Color.clear]),
                            center: CGPoint(x: echoRect.midX, y: echoRect.midY),
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
            }

            // Light ribbons
            for ribbon in IntroDaylightSeed.ribbons {
                let wave = CGFloat(sin(time * ribbon.speed + ribbon.phase)) * 24
                let y = ribbon.y * h + wave + motionOffset.height * ribbon.depth
                let rect = CGRect(x: -40, y: y, width: w + 80, height: ribbon.height)

                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 18))
                    layer.fill(
                        Path(roundedRect: rect, cornerRadius: ribbon.height * 0.5),
                        with: .linearGradient(
                            Gradient(colors: [
                                ribbon.color.opacity(0),
                                ribbon.color.opacity(0.24),
                                ribbon.color.opacity(0)
                            ]),
                            startPoint: CGPoint(x: rect.minX, y: rect.midY),
                            endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                        )
                    )
                }
            }

            // Floating light dust
            for dust in IntroDaylightSeed.dust {
                let x = dust.x * w + CGFloat(sin(time * dust.speed + dust.phase)) * 18 + motionOffset.width * dust.depth
                let y = dust.y * h + CGFloat(cos(time * (dust.speed * 0.75) + dust.phase)) * 10 + motionOffset.height * dust.depth
                let glimmer = 0.65 + 0.35 * sin(time * (dust.speed * 4) + dust.phase)
                let r = dust.radius
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(dust.opacity * glimmer)))
            }

        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
    }
}

// MARK: - Motion

@MainActor
private final class IntroMotionController: ObservableObject {
    @Published var pitch: CGFloat = 0
    @Published var roll: CGFloat = 0

    private let motionManager = CMMotionManager()
    private var hasBase = false
    private var basePitch: Double = 0
    private var baseRoll: Double = 0

    init() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let p = motion.attitude.pitch
            let r = motion.attitude.roll

            if !self.hasBase {
                self.basePitch = p
                self.baseRoll = r
                self.hasBase = true
            }

            // The "centre" slowly follows how you hold the phone,
            // so only real movement shifts the scene.
            self.basePitch += (p - self.basePitch) * 0.004
            self.baseRoll += (r - self.baseRoll) * 0.004

            let targetPitch = max(-1, min(1, CGFloat((p - self.basePitch) * 1.8)))
            let targetRoll = max(-1, min(1, CGFloat((r - self.baseRoll) * 1.8)))

            // Low-pass smoothing: no jitter, just drift.
            self.pitch += (targetPitch - self.pitch) * 0.14
            self.roll += (targetRoll - self.roll) * 0.14
        }
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - Preview

#Preview("Day") {
    IntroGreetingView(text: "Good morning\nWhat's the plan?", isTyping: false)
        .preferredColorScheme(.light)
}

#Preview("Night") {
    IntroGreetingView(text: "Good night\n", isTyping: false)
        .preferredColorScheme(.dark)
}
