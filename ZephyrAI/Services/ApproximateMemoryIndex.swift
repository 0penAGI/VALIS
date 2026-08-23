import Foundation

struct ApproximateMemoryIndex {
    private struct Signature: Hashable {
        let bands: [Int]
    }

    private let projectionCount: Int
    private let bandSize: Int
    private let projections: [[Double]]
    private var buckets: [Int: [UUID]] = [:]
    private var signatures: [UUID: Signature] = [:]

    init(projectionCount: Int = 16, bandSize: Int = 4) {
        self.projectionCount = max(4, projectionCount)
        self.bandSize = max(2, bandSize)
        self.projections = Self.makeProjections(projectionCount: self.projectionCount, seed: 0xA11CE5ED)
    }

    mutating func rebuild(from memories: [Memory]) {
        buckets.removeAll(keepingCapacity: true)
        signatures.removeAll(keepingCapacity: true)

        for memory in memories {
            insert(memoryId: memory.id, embedding: memory.embedding)
        }
    }

    mutating func insert(memoryId: UUID, embedding: [Double]) {
        guard !embedding.isEmpty else { return }
        let signature = makeSignature(for: embedding)
        signatures[memoryId] = signature
        for bucket in signature.bands {
            buckets[bucket, default: []].append(memoryId)
        }
    }

    mutating func remove(memoryId: UUID) {
        guard let signature = signatures.removeValue(forKey: memoryId) else { return }
        for bucket in signature.bands {
            buckets[bucket]?.removeAll { $0 == memoryId }
            if buckets[bucket]?.isEmpty == true {
                buckets.removeValue(forKey: bucket)
            }
        }
    }

    func candidates(for embedding: [Double], limit: Int, excluding excluded: Set<UUID> = []) -> [UUID] {
        guard !embedding.isEmpty, limit > 0 else { return [] }
        let signature = makeSignature(for: embedding)
        var seen = Set<UUID>()
        var result: [UUID] = []
        result.reserveCapacity(limit)

        let neighborBands = neighborhood(for: signature)
        for bucket in neighborBands {
            guard let ids = buckets[bucket] else { continue }
            for id in ids where !excluded.contains(id) && seen.insert(id).inserted {
                result.append(id)
                if result.count >= limit {
                    return result
                }
            }
        }

        return result
    }

    private func neighborhood(for signature: Signature) -> [Int] {
        let bands = signature.bands
        if bands.isEmpty { return [] }

        var out: [Int] = []
        out.reserveCapacity(bands.count * 2 + 1)

        for band in bands {
            out.append(band)
        }
        if bands.count > 1 {
            for index in 0..<bands.count {
                out.append(bands[index] ^ 0x5f3759df)
                out.append(bands[index] ^ 0x1f123bb5)
            }
        }
        return Array(Set(out))
    }

    private func makeSignature(for embedding: [Double]) -> Signature {
        let vector = Self.normalized(embedding)
        guard !vector.isEmpty else { return Signature(bands: []) }

        var bands: [Int] = []
        bands.reserveCapacity(max(1, projectionCount / bandSize))

        for start in stride(from: 0, to: projections.count, by: bandSize) {
            let end = min(projections.count, start + bandSize)
            var bandValue: Int = 0
            for i in start..<end {
                let dot = dot(vector, projections[i])
                bandValue = (bandValue &* 16777619) ^ (dot >= 0 ? 1 : 0)
                bandValue = (bandValue &* 16777619) ^ Int((abs(dot) * 127.0).rounded())
            }
            bands.append(bandValue)
        }

        return Signature(bands: bands)
    }

    private static func makeProjections(projectionCount: Int, seed: UInt64) -> [[Double]] {
        var rng = SplitMix64(seed: seed)
        var projections: [[Double]] = []
        projections.reserveCapacity(projectionCount)

        for _ in 0..<projectionCount {
            var projection: [Double] = []
            projection.reserveCapacity(32)
            for _ in 0..<32 {
                let value = rng.nextGaussian()
                projection.append(value)
            }
            projections.append(Self.normalized(projection))
        }

        return projections
    }

    private static func normalized(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var sum = 0.0
        for i in 0..<a.count {
            sum += a[i] * b[i]
        }
        return sum
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let raw = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * raw
    }

    mutating func nextGaussian() -> Double {
        let u1 = max(1e-12, nextDouble(in: 0.0...1.0))
        let u2 = nextDouble(in: 0.0...1.0)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
    }
}
