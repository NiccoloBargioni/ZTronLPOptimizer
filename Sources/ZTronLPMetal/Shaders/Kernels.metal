// ZTronLPMetal — compute kernels of the optional GPU tier (specification §6.4).
//
// Metal Shading Language has no double: everything here is float32, and nothing here decides
// anything. Both kernels only produce candidates, which the CPU re-verifies in Double.
//
// Xcode compiles this file into default.metallib. A command-line build copies it verbatim and
// MetalContext compiles it with makeLibrary(source:) at first use.
//
// Both kernels are dispatched with uniform thread groups rounded up to the grid, so every
// kernel starts with a bounds check. That works on every GPU family of the iOS 15 floor.

#include <metal_stdlib>

using namespace metal;

// One unit in the last place of a float around 1. Rounding-error bounds below use it as a
// (deliberately generous) stand-in for the unit roundoff 2^-24.
constant float kEpsilon = 1.1920929e-7f;

// MARK: - reducedCostScan

struct ScanParameters {
    uint columns;
};

// Pricing scan. For every structural column j, computes the reduced cost
//     d_j = c_j − a_jᵀ y
// from the static fp32 CSC copy of A, and writes the pricing score |d_j| / √w_j when the
// column is eligible and its reduced cost has the attractive sign; 0 otherwise.
//
// Eligibility codes (ZTronLPNumerics.PricingEligibility): 0 = never, 1 = at lower bound
// (attractive when d < 0), 2 = at upper bound (attractive when d > 0), 3 = free (attractive
// whenever d ≠ 0).
//
// The CPU selects the best candidates from `scores` and recomputes each one's reduced cost in
// Double before using it.
kernel void reducedCostScan(const device uint *columnStart [[buffer(0)]],
                            const device uint *rowIndex [[buffer(1)]],
                            const device float *values [[buffer(2)]],
                            const device float *duals [[buffer(3)]],
                            const device float *costs [[buffer(4)]],
                            const device float *weights [[buffer(5)]],
                            const device uchar *eligibility [[buffer(6)]],
                            device float *scores [[buffer(7)]],
                            constant ScanParameters &parameters [[buffer(8)]],
                            uint j [[thread_position_in_grid]])
{
    if (j >= parameters.columns) {
        return;
    }
    const uchar code = eligibility[j];
    float score = 0.0f;
    if (code != 0) {
        float d = costs[j];
        const uint end = columnStart[j + 1];
        for (uint p = columnStart[j]; p < end; ++p) {
            d -= values[p] * duals[rowIndex[p]];
        }
        const bool attractive = (code == 1 && d < 0.0f) || (code == 2 && d > 0.0f) || (code == 3 && d != 0.0f);
        if (attractive) {
            // Devex weights are at least 1 in exact arithmetic; the floor only guards the division.
            const float w = max(weights[j], 1.0e-30f);
            score = fabs(d) / sqrt(w);
        }
    }
    scores[j] = score;
}

// MARK: - batchedActivity

struct ActivityParameters {
    uint rows;
    uint columns;
    uint points;
    uint storeActivities;
    float tolerance;
};

// Row activities of a batch of candidate points. Thread (i, k) computes the activity of row i
// at point k from the static fp32 CSR copy of A,
//     s = Σ_j a_ij · x_kj,
// optionally stores it, and raises the point's flag when the activity violates the row's
// bounds.
//
// The comparison is widened by a bound on the rounding error of the fp32 dot product, so a
// point that is feasible in exact arithmetic is never rejected here because of single
// precision. The price is false positives near a bound, which is the right way round: the CPU
// re-evaluates every point this kernel lets through in Double before it becomes an incumbent.
//
// Infinite row bounds arrive as ±3e38, so no comparison involves an infinity.
kernel void batchedActivity(const device uint *rowStart [[buffer(0)]],
                            const device uint *columnIndex [[buffer(1)]],
                            const device float *values [[buffer(2)]],
                            const device float *points [[buffer(3)]],
                            const device float *rowLower [[buffer(4)]],
                            const device float *rowUpper [[buffer(5)]],
                            device atomic_uint *violated [[buffer(6)]],
                            device float *activities [[buffer(7)]],
                            constant ActivityParameters &parameters [[buffer(8)]],
                            uint2 position [[thread_position_in_grid]])
{
    const uint i = position.x;
    const uint k = position.y;
    if (i >= parameters.rows || k >= parameters.points) {
        return;
    }
    const uint base = k * parameters.columns;
    const uint begin = rowStart[i];
    const uint end = rowStart[i + 1];
    float activity = 0.0f;
    float magnitude = 0.0f;
    for (uint p = begin; p < end; ++p) {
        const float term = values[p] * points[base + columnIndex[p]];
        activity += term;
        magnitude += fabs(term);
    }
    if (parameters.storeActivities != 0) {
        activities[k * parameters.rows + i] = activity;
    }
    // (length + 4)·ε·Σ|a·x| bounds the error of the rounded inputs and of the summation.
    const float noise = (float(end - begin) + 4.0f) * kEpsilon * magnitude;
    const float lower = rowLower[i];
    const float upper = rowUpper[i];
    const float slackLower = parameters.tolerance + noise + kEpsilon * fabs(lower);
    const float slackUpper = parameters.tolerance + noise + kEpsilon * fabs(upper);
    if (activity < lower - slackLower || activity > upper + slackUpper) {
        atomic_fetch_or_explicit(&violated[k], 1u, memory_order_relaxed);
    }
}
