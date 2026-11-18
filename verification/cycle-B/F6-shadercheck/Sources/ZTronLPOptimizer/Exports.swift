// ZTronLPOptimizer — the facade most apps import (specification §3).
//
// One import brings every public type of the package: the modeling DSL and the compiled
// model (ZTronLPCore), the numerics layer, the four engines, the optional GPU tier and
// conditioning analyzer, and the three facade strategies defined in this target —
// `Automatic`, `Portfolio` and `Conditioned`.

@_exported import ZTronLPBranchAndBound
@_exported import ZTronLPCPSAT
@_exported import ZTronLPConditioning
@_exported import ZTronLPCore
@_exported import ZTronLPInteriorPoint
@_exported import ZTronLPMetal
@_exported import ZTronLPNumerics
@_exported import ZTronLPSimplex
