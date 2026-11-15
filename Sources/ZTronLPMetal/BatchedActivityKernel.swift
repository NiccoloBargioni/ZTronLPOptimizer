// The batchedActivity kernel (specification §6.4, §9.5).
//
//   Input     fp32 CSR copy of A, batch of up to 1,024 candidate points x (rounding/diving
//             heuristics)
//   Output    fp32 row activities Ax and a feasibility flag per point
//   Verified  the CPU re-evaluates every point flagged feasible in Double before it becomes
//             an incumbent
//   Threshold batch ≥ 64 points and nnz ≥ 100,000 under MetalPolicy.automatic

import Metal
import ZTronLPCore
import ZTronLPNumerics

/// Layout of the shader's `ActivityParameters`.
private struct ActivityParameters {
    var rows: UInt32
    var columns: UInt32
    var points: UInt32
    var storeActivities: UInt32
    var tolerance: Float
}

/// The fp32 feasibility screen on the GPU.
///
/// For a batch of points the GPU computes every row activity and flags the points that leave
/// a row's bounds. The comparison is widened by a bound on the single-precision rounding
/// error, so the screen never rejects a point that is feasible in exact arithmetic; it can
/// let through a point that is not, and the caller's Double re-evaluation removes those.
/// Column bounds are checked on the CPU, exactly, while the batch is packed.
///
/// Like the scan kernel this is an actor: the static copy of A is written once in `init`, and
/// the per-call buffers belong to one call at a time.
public actor MetalBatchedActivity: BatchedActivityEvaluating {
    /// The CSR view of A (`CompiledLP.aT`) the fp32 copy was built from, and the bounds the
    /// screen tests against. The provider's cache compares them to decide whether a request
    /// can reuse this kernel.
    public nonisolated let matrix: SparseCSC
    public nonisolated let rowLower: [Double]
    public nonisolated let rowUpper: [Double]
    public nonisolated let columnLower: [Double]
    public nonisolated let columnUpper: [Double]
    public nonisolated let rows: Int
    public nonisolated let columns: Int

    private let context: MetalContext
    private let rowStart: any MTLBuffer
    private let columnIndex: any MTLBuffer
    private let values: any MTLBuffer
    private let lowerBuffer: any MTLBuffer
    private let upperBuffer: any MTLBuffer
    /// Bound in place of the activities buffer when a call does not store them.
    private let placeholder: any MTLBuffer
    /// The most scratch memory one GPU dispatch may use; larger batches are split.
    private let scratchByteLimit: Int

    /// The buffers of one dispatch, sized for `capacity` points.
    private struct Scratch {
        let capacity: Int
        let storesActivities: Bool
        let points: any MTLBuffer
        let violated: any MTLBuffer
        let activities: (any MTLBuffer)?
    }
    private var pool: [Scratch] = []
    private static let poolLimit = 2

    /// GPU dispatches completed so far.
    public private(set) var dispatches = 0

    /// Builds the fp32 CSR copy of `lp`'s matrix and bounds. Fails when the problem is empty or
    /// a buffer cannot be allocated on the device.
    init?(context: MetalContext, lp: CompiledLP, scratchByteLimit: Int = 64 << 20) {
        let aT = lp.aT
        guard lp.m > 0, lp.n > 0, aT.nnz > 0 else { return nil }
        let device = context.device
        guard aT.nnz * MemoryLayout<Float>.stride <= device.maxBufferLength,
              let rowStart = KernelSupport.offsetBuffer(device, aT.colStart),
              let columnIndex = KernelSupport.indexBuffer(device, aT.rowIndex),
              let values = KernelSupport.floatBuffer(device, aT.values),
              let lowerBuffer = KernelSupport.floatBuffer(device, lp.rl, clampInfinities: true),
              let upperBuffer = KernelSupport.floatBuffer(device, lp.ru, clampInfinities: true),
              let placeholder = KernelSupport.makeBuffer(device, bytes: MemoryLayout<Float>.stride)
        else { return nil }
        self.context = context
        matrix = aT
        rowLower = lp.rl
        rowUpper = lp.ru
        columnLower = lp.xl
        columnUpper = lp.xu
        rows = lp.m
        columns = lp.n
        self.rowStart = rowStart
        self.columnIndex = columnIndex
        self.values = values
        self.lowerBuffer = lowerBuffer
        self.upperBuffer = upperBuffer
        self.placeholder = placeholder
        self.scratchByteLimit = Swift.max(scratchByteLimit, 1)
    }

    /// Bytes of device memory the static copy of a problem needs.
    static func staticBytes(for lp: CompiledLP) -> Int {
        lp.nnz * (MemoryLayout<Float>.stride + MemoryLayout<UInt32>.stride)
            + (lp.m + 1) * MemoryLayout<UInt32>.stride + 2 * lp.m * MemoryLayout<Float>.stride
    }

    /// True when `lp` has the matrix and bounds this kernel was built for.
    nonisolated func serves(_ lp: CompiledLP) -> Bool {
        rows == lp.m && columns == lp.n && matrix == lp.aT && rowLower == lp.rl && rowUpper == lp.ru
            && columnLower == lp.xl && columnUpper == lp.xu
    }

    public func evaluate(points: [Double], count: Int, tolerance: Double) async -> [Bool]? {
        guard count >= 0, points.count == count * columns else { return nil }
        if count == 0 { return [] }
        // Column bounds, exactly, on the CPU.
        var feasible = [Bool](repeating: true, count: count)
        let n = columns
        points.withUnsafeBufferPointer { x in
            for k in 0..<count {
                let base = k * n
                for j in 0..<n {
                    let value = x[base + j]
                    // The negated form also rejects NaN.
                    if !(value >= columnLower[j] - tolerance && value <= columnUpper[j] + tolerance) {
                        feasible[k] = false
                        break
                    }
                }
            }
        }
        guard let screened = await run(points: points, count: count, tolerance: tolerance, storeActivities: false) else {
            return nil
        }
        for k in 0..<count where screened.violated[k] { feasible[k] = false }
        return feasible
    }

    /// The fp32 row activities A·x of `count` points: `count × rows` values, one point after
    /// another. `evaluate` only reports the flags; this is the kernel's other output, for
    /// diagnostics and for the tests that compare the kernel with a Double reference.
    public func activities(points: [Double], count: Int) async -> [Float]? {
        guard count >= 0, points.count == count * columns else { return nil }
        if count == 0 { return [] }
        return await run(points: points, count: count, tolerance: 0, storeActivities: true)?.activities
    }

    /// The row-bound flags of `count` points exactly as the GPU raised them, before the
    /// column-bound check: true where a row activity left its (widened) bounds.
    func rowViolations(points: [Double], count: Int, tolerance: Double) async -> [Bool]? {
        guard count > 0, points.count == count * columns else { return nil }
        return await run(points: points, count: count, tolerance: tolerance, storeActivities: false)?.violated
    }

    /// Runs the kernel over the batch, one dispatch per chunk that fits the scratch limit.
    private func run(
        points: [Double], count: Int, tolerance: Double, storeActivities: Bool
    ) async -> (violated: [Bool], activities: [Float])? {
        let n = columns
        let m = rows
        let bytesPerPoint = MemoryLayout<Float>.stride * (n + (storeActivities ? m : 0))
        let chunk = Swift.max(
            1, Swift.min(count, KernelThresholds.batchedActivityMaxBatch, scratchByteLimit / Swift.max(1, bytesPerPoint)))
        guard chunk * n <= Int(UInt32.max), chunk * m <= Int(UInt32.max) else { return nil }

        var violated = [Bool](repeating: false, count: count)
        var activities = [Float](repeating: 0, count: storeActivities ? count * m : 0)
        let pipeline = context.activityPipeline
        let width = Swift.max(1, pipeline.threadExecutionWidth)
        let height = Swift.max(1, pipeline.maxTotalThreadsPerThreadgroup / width)

        var first = 0
        while first < count {
            let size = Swift.min(chunk, count - first)
            guard let scratch = takeScratch(capacity: chunk, storeActivities: storeActivities) else { return nil }
            points.withUnsafeBufferPointer { x in
                let slice = UnsafeBufferPointer(rebasing: x[(first * n)..<((first + size) * n)])
                KernelSupport.write(slice, to: scratch.points)
            }
            scratch.violated.contents().initializeMemory(as: UInt32.self, repeating: 0, count: size)

            guard let commandBuffer = context.queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else {
                recycle(scratch)
                return nil
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(rowStart, offset: 0, index: 0)
            encoder.setBuffer(columnIndex, offset: 0, index: 1)
            encoder.setBuffer(values, offset: 0, index: 2)
            encoder.setBuffer(scratch.points, offset: 0, index: 3)
            encoder.setBuffer(lowerBuffer, offset: 0, index: 4)
            encoder.setBuffer(upperBuffer, offset: 0, index: 5)
            encoder.setBuffer(scratch.violated, offset: 0, index: 6)
            encoder.setBuffer(scratch.activities ?? placeholder, offset: 0, index: 7)
            var parameters = ActivityParameters(
                rows: UInt32(m), columns: UInt32(n), points: UInt32(size),
                storeActivities: storeActivities ? 1 : 0, tolerance: Float(tolerance))
            encoder.setBytes(&parameters, length: MemoryLayout<ActivityParameters>.stride, index: 8)
            // Grid: rows across, points down. Uniform thread groups rounded up to the grid;
            // the shader ignores the overhang.
            encoder.dispatchThreadgroups(
                MTLSize(width: (m + width - 1) / width, height: (size + height - 1) / height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
            encoder.endEncoding()

            let completed = await KernelSupport.commit(commandBuffer)
            dispatches += 1
            guard completed else {
                recycle(scratch)
                return nil
            }
            let flags = scratch.violated.contents().bindMemory(to: UInt32.self, capacity: size)
            for k in 0..<size where flags[k] != 0 { violated[first + k] = true }
            if storeActivities, let buffer = scratch.activities {
                let source = buffer.contents().bindMemory(to: Float.self, capacity: size * m)
                activities.withUnsafeMutableBufferPointer { destination in
                    for k in 0..<(size * m) { destination[first * m + k] = source[k] }
                }
            }
            recycle(scratch)
            first += size
        }
        return (violated, activities)
    }

    private func takeScratch(capacity: Int, storeActivities: Bool) -> Scratch? {
        if let index = pool.firstIndex(where: { $0.capacity >= capacity && $0.storesActivities == storeActivities }) {
            return pool.remove(at: index)
        }
        let device = context.device
        let stride = MemoryLayout<Float>.stride
        guard capacity * columns * stride <= device.maxBufferLength,
              let points = KernelSupport.makeBuffer(device, bytes: capacity * columns * stride),
              let violated = KernelSupport.makeBuffer(device, bytes: capacity * MemoryLayout<UInt32>.stride)
        else { return nil }
        var activities: (any MTLBuffer)? = nil
        if storeActivities {
            guard capacity * rows * stride <= device.maxBufferLength,
                  let buffer = KernelSupport.makeBuffer(device, bytes: capacity * rows * stride)
            else { return nil }
            activities = buffer
        }
        return Scratch(
            capacity: capacity, storesActivities: storeActivities, points: points, violated: violated,
            activities: activities)
    }

    private func recycle(_ scratch: Scratch) {
        if pool.count >= Self.poolLimit { pool.removeFirst() }
        pool.append(scratch)
    }
}

/// An activity kernel together with the policy of the request that obtained it.
///
/// The provider can tell from the problem alone whether the matrix is large enough for the
/// tier; whether a batch is large enough is only known per call. Under
/// `MetalPolicy.automatic` a batch below 64 points is declined here (`nil`), and the caller
/// evaluates it on the CPU.
public struct PolicyBoundActivityEvaluator: BatchedActivityEvaluating {
    public let kernel: MetalBatchedActivity
    public let policy: MetalPolicy
    public let nonzeros: Int

    public func evaluate(points: [Double], count: Int, tolerance: Double) async -> [Bool]? {
        guard KernelThresholds.allowsBatchedActivity(points: count, nonzeros: nonzeros, policy: policy) else {
            return nil
        }
        return await kernel.evaluate(points: points, count: count, tolerance: tolerance)
    }
}
