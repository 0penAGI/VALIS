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
