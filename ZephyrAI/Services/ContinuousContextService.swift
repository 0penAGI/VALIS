import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

@MainActor
final class ContinuousContextService {
    static let shared = ContinuousContextService()

    private var cachedBlock: String?
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 30

    private init() {}

    func contextBlock() -> String {
        if let cached = cachedBlock, let t = cacheTime,
           Date().timeIntervalSince(t) < cacheTTL {
            return cached
        }
        let block = buildBlock()
        cachedBlock = block
        cacheTime = Date()
        return block
    }

    private func buildBlock() -> String {
        var parts: [String] = []

        parts.append("Current Time: \(formatTime())")
        parts.append("Date: \(formatDate())")

        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        if level >= 0 {
            parts.append("Battery: \(Int(level * 100))%")
        }
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        parts.append("Power: \(batteryState)")
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            parts.append("Low Power Mode: on")
        }

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: break
        case .fair: parts.append("Thermal: fair")
        case .serious: parts.append("Thermal: serious — performance reduced")
        case .critical: parts.append("Thermal: critical")
        @unknown default: break
        }
        #endif

        let net = NWPathMonitor().currentPath
        if net.usesInterfaceType(.wifi) {
            parts.append("Network: Wi-Fi")
        } else if net.usesInterfaceType(.cellular) {
            parts.append("Network: Cellular")
        } else if !net.status.statusString.isEmpty {
            parts.append("Network: \(net.status.statusString)")
        }

        let locale = Locale.current
        if let lang = locale.language.languageCode?.identifier {
            parts.append("Locale: \(lang)")
        }

        return "Device state:\n" + parts.joined(separator: "\n")
    }

    private func formatTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = .current
        return f.string(from: Date())
    }

    private func formatDate() -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.locale = .current
        return f.string(from: Date())
    }
}

#if canImport(Network)
private extension NWPath.Status {
    var statusString: String {
        switch self {
        case .satisfied: return "connected"
        case .unsatisfied: return "offline"
        case .requiresConnection: return "connecting"
        @unknown default: return "unknown"
        }
    }
}
#endif
