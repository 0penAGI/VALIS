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
    private var cachedDetailedBlock: String?
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 30

    #if canImport(Network)
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "ZephyrAI.NetworkPathMonitor")
    private var latestPath: NWPath?
    #endif

    private init() {
        #if canImport(Network)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.latestPath = path
            }
        }
        pathMonitor.start(queue: monitorQueue)
        #endif
    }

    func contextBlock(includeDeviceState: Bool) -> String {
        let now = Date()
        if includeDeviceState {
            if let cached = cachedDetailedBlock, let t = cacheTime,
               now.timeIntervalSince(t) < cacheTTL {
                return cached
            }
        } else {
            if let cached = cachedBlock, let t = cacheTime,
               now.timeIntervalSince(t) < cacheTTL {
                return cached
            }
        }
        let block = buildBlock(includeDeviceState: includeDeviceState)
        if includeDeviceState {
            cachedDetailedBlock = block
        } else {
            cachedBlock = block
        }
        cacheTime = now
        return block
    }

    func isDeviceStateRelevant(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
        let triggers = [
            "battery", "заряд", "батаре", "батарея", "заряж",
            "battery level", "%, battery", "energy saver",
            "low power", "энергосбереж", "экономии", "лимит заряда",
            "thermal", "overheat", "надоело греется", "нагрев", "нагрева", "перегрев", "горяч",
            "wifi", "wi-fi", "wi fi", "network", "cellular", "mobile data",
            "internet connection", "сеть", "соединение", "интернет", "офлайн", "offline", "сотовая",
            "storage", "хранилищ", "память телефона", "сколько памяти", "свободн", "место на",
            "device state", "состояние телефона", "состояние устройства", "про телефон", "про устройство",
            "статус телефона", "status of my phone", "device status", "system status", "статус системы"
        ]
        return triggers.contains { lower.contains($0) }
    }

    private func buildBlock(includeDeviceState: Bool) -> String {
        var parts: [String] = []

        parts.append("Current Time: \(formatTime())")
        parts.append("Date: \(formatDate())")

        let locale = Locale.current
        if let lang = locale.language.languageCode?.identifier {
            parts.append("Locale: \(lang)")
        }

        guard includeDeviceState else {
            return "Device state:\n" + parts.joined(separator: "\n")
        }

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

        #if canImport(Network)
        if let path = latestPath {
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) {
                    parts.append("Network: Wi-Fi")
                } else if path.usesInterfaceType(.cellular) {
                    parts.append("Network: Cellular")
                } else if path.usesInterfaceType(.wiredEthernet) {
                    parts.append("Network: Ethernet")
                } else {
                    parts.append("Network: connected")
                }
            case .requiresConnection:
                parts.append("Network: requires sign-in or confirmation")
            case .unsatisfied:
                parts.append("Network: offline")
            @unknown default:
                break
            }
        }
        #endif

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
