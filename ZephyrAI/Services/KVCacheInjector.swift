import Foundation
import Darwin

struct KVInjection {
    let fieldVector: [Double]
    let beta: Float
}

enum KVCacheInjector {
    private typealias LlamaKVInjectVFn = @convention(c) (
        OpaquePointer,
        UnsafePointer<Float>,
        Int32,
        Float
    ) -> Int32

    static func applyV(ctx: OpaquePointer, vector: [Float], beta: Float) -> Bool {
        guard !vector.isEmpty, beta != 0 else { return false }
        guard let fn = resolveInjectV() else { return false }

        return vector.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            let result = fn(ctx, base, Int32(buffer.count), beta)
            return result == 0
        }
    }

    private static func resolveInjectV() -> LlamaKVInjectVFn? {
        let handle = dlopen(nil, RTLD_NOW)
        defer {
            if let handle { dlclose(handle) }
        }
        guard let symbol = dlsym(handle, "llama_kv_inject_v") else {
            return nil
        }
        return unsafeBitCast(symbol, to: LlamaKVInjectVFn.self)
    }
}

enum TurboQuantCodec {
    private struct PolarBin {
        let radiusBin: Int
        let angleBin: Int

        var signature: String {
            "r\(radiusBin):a\(angleBin)"
        }

        var quantizedRadius: Double {
            Double(radiusBin) / 7.0
        }

        var quantizedAngle: Double {
            (-Double.pi) + (Double(angleBin) / 15.0) * (2.0 * Double.pi)
        }

        var quantizedPair: (x: Float, y: Float) {
            let radius = quantizedRadius
            return (
                Float(radius * cos(quantizedAngle)),
                Float(radius * sin(quantizedAngle))
            )
        }
    }

    private struct RNG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        QuantumFeatures.isTurboQuantEnabled(defaults: defaults)
    }

    static func compactSignature(for field: [Double], targetCount: Int = 8) -> String {
        guard !field.isEmpty else { return "" }
        let prepared = preconditionedProjection(for: field, targetCount: targetCount)
        let bins = polarBins(for: prepared)
        let payload = bins.map(\.signature).joined(separator: ",")
        return """
        [TurboQuant]
        mode: polar-turbo
        shape: \(bins.count)
        code: \(payload)
        """
    }

    static func compressedVector(for field: [Double], targetCount: Int) -> [Float] {
        guard !field.isEmpty else { return [] }
        let prepared = preconditionedProjection(for: field, targetCount: targetCount)
        var vector = polarQuantize(prepared)
        let norm = sqrt(vector.reduce(0) { $0 + ($1 * $1) })
        if norm > 0 {
            vector = vector.map { $0 / norm }
        }
        return vector
    }

    private static func preconditionedProjection(for field: [Double], targetCount: Int) -> [Double] {
        let target = max(1, min(targetCount, field.count))
        let projected = resample(field, targetCount: target)
        guard !projected.isEmpty else { return [] }

        var out = projected
        var rng = RNG(seed: deterministicSeed(for: field, targetCount: target))

        for index in out.indices {
            if rng.next() & 1 == 0 {
                out[index].negate()
            }
        }

        if out.count > 1 {
            for index in stride(from: 0, to: out.count - 1, by: 2) {
                let a = out[index]
                let b = out[index + 1]
                let mix = 1.0 / sqrt(2.0)
                out[index] = (a + b) * mix
                out[index + 1] = (a - b) * mix
            }
        }

        return out
    }

    private static func resample(_ field: [Double], targetCount: Int) -> [Double] {
        let target = max(1, min(targetCount, field.count))
        if field.count <= target {
            return field.map { max(-1.0, min(1.0, $0)) }
        }

        let chunkSize = Double(field.count) / Double(target)
        var samples: [Double] = []
        samples.reserveCapacity(target)

        for i in 0..<target {
            let start = Int(Double(i) * chunkSize)
            let end = max(start + 1, min(field.count, Int(Double(i + 1) * chunkSize)))
            let slice = field[start..<end]
            let mean = slice.reduce(0.0, +) / Double(slice.count)
            samples.append(max(-1.0, min(1.0, mean)))
        }

        return samples
    }

    private static func polarBins(for values: [Double]) -> [PolarBin] {
        guard !values.isEmpty else { return [] }
        var padded = values
        if padded.count % 2 != 0 {
            padded.append(0)
        }

        var bins: [PolarBin] = []
        bins.reserveCapacity(padded.count / 2)

        for index in stride(from: 0, to: padded.count, by: 2) {
            let x = padded[index]
            let y = padded[index + 1]
            let radius = min(1.0, hypot(x, y))
            let angle = atan2(y, x)
            let radiusBin = max(0, min(7, Int((radius * 7.0).rounded())))
            let anglePhase = (angle + Double.pi) / (2.0 * Double.pi)
            let angleBin = max(0, min(15, Int((anglePhase * 15.0).rounded())))
            bins.append(PolarBin(radiusBin: radiusBin, angleBin: angleBin))
        }

        return bins
    }

    private static func polarQuantize(_ values: [Double]) -> [Float] {
        guard !values.isEmpty else { return [] }
        var padded = values
        if padded.count % 2 != 0 {
            padded.append(0)
        }

        var vector: [Float] = []
        vector.reserveCapacity(padded.count)

        for index in stride(from: 0, to: padded.count, by: 2) {
            let x = padded[index]
            let y = padded[index + 1]
            let radius = min(1.0, hypot(x, y))
            let angle = atan2(y, x)
            let radiusBin = max(0, min(7, Int((radius * 7.0).rounded())))
            let anglePhase = (angle + Double.pi) / (2.0 * Double.pi)
            let angleBin = max(0, min(15, Int((anglePhase * 15.0).rounded())))
            let bin = PolarBin(radiusBin: radiusBin, angleBin: angleBin)
            let pair = bin.quantizedPair
            vector.append(pair.x)
            vector.append(pair.y)
        }

        return vector
    }

    private static func deterministicSeed(for field: [Double], targetCount: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325

        @inline(__always)
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x100000001b3
        }

        mix(UInt64(field.count))
        mix(UInt64(targetCount))
        mix(UInt64(min(field.count, 16)))
        for value in field.prefix(16) {
            mix(value.bitPattern)
        }

        return hash == 0 ? 1 : hash
    }
}
