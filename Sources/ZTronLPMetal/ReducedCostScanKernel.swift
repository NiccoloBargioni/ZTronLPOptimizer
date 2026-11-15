// The reducedCostScan kernel (specification §6.4, §7.5).
//
//   Input     static fp32 CSC copy of A, fp32 y, fp32 c, nonbasic mask, Devex weights
//   Output    top-64 candidate columns by |d_j| / √w_j
//   Verified  the CPU recomputes d_j in Double for the candidates and picks the entering
//             variable from those
//   Threshold `KernelThresholds.reducedCostScanColumns` and `…Nonzeros` under
//             MetalPolicy.automatic (the specification's 50,000 / 500,000, raised by measurement)

import Metal
import ZTronLPCore
import ZTronLPNumerics

/// Layout of the shader's `ScanParameters`.
private struct ScanParameters {
    var columns: UInt32
}

/// The fp32 pricing scan on the GPU.
///
/// The GPU computes one score per column; the best `limit` are then selected on the CPU
/// straight from the shared output buffer. The result is a list of candidates and nothing
/// more: single precision can rank two columns the wrong way round or call a column
/// attractive whose reduced cost is zero in Double, which is why the caller verifies.
///
/// The kernel is an actor, so its Metal buffers never leave its isolation and need no
/// `Sendable` escape hatch. The static copy of A is written once in `init` and only read
/// afterwards. The per-call buffers are taken from a small pool for the duration of one call:
/// calls made while another one is suspended on the GPU each get their own set, so several
/// workers can share one kernel.
public actor MetalReducedCostScan: ReducedCostScanning {
    /// The matrix the fp32 copy was built from. The provider's cache compares it to decide
    /// whether a request can reuse this kernel.
    public nonisolated let matrix: SparseCSC
    public nonisolated let rows: Int
    public nonisolated let columns: Int

    private let context: MetalContext
    private let columnStart: any MTLBuffer
    private let rowIndex: any MTLBuffer
    private let values: any MTLBuffer

    /// The buffers one call writes its inputs to and reads its scores from.
    private struct Scratch {
        let duals: any MTLBuffer
        let costs: any MTLBuffer
        let weights: any MTLBuffer
        let eligibility: any MTLBuffer
        let scores: any MTLBuffer
    }
    private var pool: [Scratch] = []
    /// Idle scratch sets kept for reuse.
    private static let poolLimit = 4

    /// GPU dispatches completed so far.
    public private(set) var dispatches = 0

    /// Builds the fp32 CSC copy of `matrix`. Fails when the matrix is empty or a buffer cannot
    /// be allocated on the device.
    init?(context: MetalContext, matrix: SparseCSC) {
        let n = Int(matrix.cols)
        let m = Int(matrix.rows)
        guard n > 0, m > 0, matrix.nnz > 0 else { return nil }
        let device = context.device
        guard matrix.nnz * MemoryLayout<Float>.stride <= device.maxBufferLength,
              let columnStart = KernelSupport.offsetBuffer(device, matrix.colStart),
              let rowIndex = KernelSupport.indexBuffer(device, matrix.rowIndex),
              let values = KernelSupport.floatBuffer(device, matrix.values)
        else { return nil }
        self.context = context
        self.matrix = matrix
        rows = m
        columns = n
        self.columnStart = columnStart
        self.rowIndex = rowIndex
        self.values = values
    }

    /// Bytes of device memory the static copy of a matrix needs.
    static func staticBytes(for matrix: SparseCSC) -> Int {
        matrix.nnz * (MemoryLayout<Float>.stride + MemoryLayout<UInt32>.stride)
            + (Int(matrix.cols) + 1) * MemoryLayout<UInt32>.stride
    }

    public func scan(
        costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8], limit: Int
    ) async -> [Int32]? {
        guard limit > 0 else { return [] }
        guard let scratch = await run(costs: costs, duals: duals, weights: weights, eligibility: eligibility) else {
            return nil
        }
        let scores = UnsafeBufferPointer(
            start: scratch.scores.contents().bindMemory(to: Float.self, capacity: columns), count: columns)
        let candidates = KernelSupport.topCandidates(scores, limit: limit)
        recycle(scratch)
        return candidates
    }

    /// Every column's fp32 pricing score: |d_j| / √w_j for an eligible column whose reduced
    /// cost has the attractive sign, 0 otherwise. `scan` returns the positions of the largest
    /// ones; this is the raw output, for diagnostics and for the tests that compare the
    /// kernel with a Double reference.
    public func scores(
        costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8]
    ) async -> [Float]? {
        guard let scratch = await run(costs: costs, duals: duals, weights: weights, eligibility: eligibility) else {
            return nil
        }
        let pointer = scratch.scores.contents().bindMemory(to: Float.self, capacity: columns)
        let result = Array(UnsafeBufferPointer(start: pointer, count: columns))
        recycle(scratch)
        return result
    }

    /// Runs the kernel once and returns the scratch set whose `scores` buffer holds the result.
    private func run(
        costs: [Double], duals: [Double], weights: [Double], eligibility: [UInt8]
    ) async -> Scratch? {
        let n = columns
        guard costs.count == n, weights.count == n, eligibility.count == n, duals.count == rows else {
            return nil
        }
        guard let scratch = pool.popLast() ?? makeScratch() else { return nil }
        duals.withUnsafeBufferPointer { KernelSupport.write($0, to: scratch.duals) }
        costs.withUnsafeBufferPointer { KernelSupport.write($0, to: scratch.costs) }
        weights.withUnsafeBufferPointer { KernelSupport.write($0, to: scratch.weights) }
        eligibility.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { scratch.eligibility.contents().copyMemory(from: base, byteCount: n) }
        }

        guard let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            recycle(scratch)
            return nil
        }
        let pipeline = context.scanPipeline
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(columnStart, offset: 0, index: 0)
        encoder.setBuffer(rowIndex, offset: 0, index: 1)
        encoder.setBuffer(values, offset: 0, index: 2)
        encoder.setBuffer(scratch.duals, offset: 0, index: 3)
        encoder.setBuffer(scratch.costs, offset: 0, index: 4)
        encoder.setBuffer(scratch.weights, offset: 0, index: 5)
        encoder.setBuffer(scratch.eligibility, offset: 0, index: 6)
        encoder.setBuffer(scratch.scores, offset: 0, index: 7)
        var parameters = ScanParameters(columns: UInt32(n))
        encoder.setBytes(&parameters, length: MemoryLayout<ScanParameters>.stride, index: 8)
        // Uniform thread groups rounded up to the grid; the shader ignores the overhang.
        let width = Swift.max(1, pipeline.threadExecutionWidth)
        encoder.dispatchThreadgroups(
            MTLSize(width: (n + width - 1) / width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()

        let completed = await KernelSupport.commit(commandBuffer)
        dispatches += 1
        guard completed else {
            recycle(scratch)
            return nil
        }
        return scratch
    }

    private func makeScratch() -> Scratch? {
        let device = context.device
        let floatBytes = columns * MemoryLayout<Float>.stride
        guard let duals = KernelSupport.makeBuffer(device, bytes: rows * MemoryLayout<Float>.stride),
              let costs = KernelSupport.makeBuffer(device, bytes: floatBytes),
              let weights = KernelSupport.makeBuffer(device, bytes: floatBytes),
              let eligibility = KernelSupport.makeBuffer(device, bytes: columns),
              let scores = KernelSupport.makeBuffer(device, bytes: floatBytes)
        else { return nil }
        return Scratch(duals: duals, costs: costs, weights: weights, eligibility: eligibility, scores: scores)
    }

    private func recycle(_ scratch: Scratch) {
        if pool.count < Self.poolLimit { pool.append(scratch) }
    }
}
