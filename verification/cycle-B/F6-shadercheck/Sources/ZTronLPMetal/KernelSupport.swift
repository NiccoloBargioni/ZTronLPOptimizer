// Shared plumbing of the two kernels (specification §6.4): shared-memory buffers, the fp32
// conversions, the suspension on command-buffer completion and the CPU-side candidate
// selection.

import Metal

enum KernelSupport {
    /// What an infinite bound is sent to the GPU as. Finite, so that no shader comparison
    /// involves an infinity, and far enough below the largest float that adding a tolerance
    /// to it cannot overflow.
    static let infinityStandIn: Float = 3.0e38

    /// A buffer in unified memory (`storageModeShared`), at least one word long.
    static func makeBuffer(_ device: any MTLDevice, bytes: Int) -> (any MTLBuffer)? {
        device.makeBuffer(length: Swift.max(bytes, 4), options: .storageModeShared)
    }

    /// A buffer holding `source` in single precision. With `clampInfinities`, values beyond
    /// the stand-in (infinite bounds) are replaced by it.
    static func floatBuffer(
        _ device: any MTLDevice, _ source: [Double], clampInfinities: Bool = false
    ) -> (any MTLBuffer)? {
        guard let buffer = makeBuffer(device, bytes: source.count * MemoryLayout<Float>.stride) else { return nil }
        source.withUnsafeBufferPointer { write($0, to: buffer, clampInfinities: clampInfinities) }
        return buffer
    }

    /// A buffer holding 32-bit indices. A nonnegative `Int32` has the bit pattern of the same
    /// `UInt32`, so the array is copied as it is.
    static func indexBuffer(_ device: any MTLDevice, _ source: [Int32]) -> (any MTLBuffer)? {
        guard let buffer = makeBuffer(device, bytes: source.count * MemoryLayout<Int32>.stride) else { return nil }
        source.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, bytes.count > 0 {
                buffer.contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
        return buffer
    }

    /// A buffer holding storage offsets as `UInt32`; `nil` when an offset does not fit.
    static func offsetBuffer(_ device: any MTLDevice, _ source: [Int]) -> (any MTLBuffer)? {
        guard let last = source.last, last <= Int(UInt32.max),
              let buffer = makeBuffer(device, bytes: source.count * MemoryLayout<UInt32>.stride)
        else { return nil }
        let destination = buffer.contents().bindMemory(to: UInt32.self, capacity: source.count)
        for (k, offset) in source.enumerated() { destination[k] = UInt32(truncatingIfNeeded: offset) }
        return buffer
    }

    /// Converts `source` to single precision into the start of `buffer`.
    static func write(
        _ source: UnsafeBufferPointer<Double>, to buffer: any MTLBuffer, clampInfinities: Bool = false
    ) {
        let destination = buffer.contents().bindMemory(to: Float.self, capacity: source.count)
        if clampInfinities {
            let limit = Double(infinityStandIn)
            for k in 0..<source.count {
                destination[k] = Float(Swift.min(Swift.max(source[k], -limit), limit))
            }
        } else {
            for k in 0..<source.count { destination[k] = Float(source[k]) }
        }
    }

    /// Commits a command buffer and suspends until the GPU has finished it.
    ///
    /// Completion is awaited through a continuation resumed from the buffer's completion
    /// handler, so no thread of the cooperative pool is ever parked on the GPU (§6.4, rules C6
    /// and L8). The function runs in the caller's isolation, so the command buffer never
    /// leaves the kernel actor that created it. Returns whether the buffer completed.
    static func commit(
        _ commandBuffer: any MTLCommandBuffer, isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Metal calls the handler on a thread of its own: it must not inherit the
            // kernel actor's isolation, hence the explicit @Sendable.
            let resume: @Sendable (any MTLCommandBuffer) -> Void = { _ in continuation.resume() }
            commandBuffer.addCompletedHandler(resume)
            commandBuffer.commit()
        }
        return commandBuffer.status == .completed
    }

    /// The `limit` best positive scores, best first; ties go to the lower index, so the result
    /// does not depend on anything but the scores. NaN scores are never selected.
    static func topCandidates(_ scores: UnsafeBufferPointer<Float>, limit: Int) -> [Int32] {
        guard limit > 0 else { return [] }
        // A min-heap of the best candidates seen so far: the root is the worst of them.
        var heapScore: [Float] = []
        var heapIndex: [Int32] = []
        heapScore.reserveCapacity(limit)
        heapIndex.reserveCapacity(limit)

        /// True when (a, i) ranks below (b, j).
        func worse(_ a: Float, _ i: Int32, _ b: Float, _ j: Int32) -> Bool {
            a < b || (a == b && i > j)
        }
        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard worse(heapScore[child], heapIndex[child], heapScore[parent], heapIndex[parent]) else { break }
                heapScore.swapAt(child, parent)
                heapIndex.swapAt(child, parent)
                child = parent
            }
        }
        func siftDown() {
            var parent = 0
            let count = heapScore.count
            while true {
                var smallest = parent
                let left = 2 * parent + 1
                let right = left + 1
                if left < count, worse(heapScore[left], heapIndex[left], heapScore[smallest], heapIndex[smallest]) {
                    smallest = left
                }
                if right < count, worse(heapScore[right], heapIndex[right], heapScore[smallest], heapIndex[smallest]) {
                    smallest = right
                }
                if smallest == parent { break }
                heapScore.swapAt(parent, smallest)
                heapIndex.swapAt(parent, smallest)
                parent = smallest
            }
        }

        for j in 0..<scores.count {
            let score = scores[j]
            guard score > 0 else { continue }
            let index = Int32(truncatingIfNeeded: j)
            if heapScore.count < limit {
                heapScore.append(score)
                heapIndex.append(index)
                siftUp(heapScore.count - 1)
            } else if worse(heapScore[0], heapIndex[0], score, index) {
                heapScore[0] = score
                heapIndex[0] = index
                siftDown()
            }
        }
        let order = heapScore.indices.sorted { worse(heapScore[$1], heapIndex[$1], heapScore[$0], heapIndex[$0]) }
        return order.map { heapIndex[$0] }
    }
}
