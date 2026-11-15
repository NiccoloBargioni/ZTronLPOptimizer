// One tab per solving strategy: what it is, which examples it shows, and how it is configured.

import ZTronLPOptimizer

/// A configuration choice offered on a tab (the simplex method, the node engine, …).
struct Variant: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

enum StrategyKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case simplex, interiorPoint, branchAndBound, cpsat, automatic, portfolio, conditioned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplex: return "Simplex"
        case .interiorPoint: return "Interior Point"
        case .branchAndBound: return "Branch & Bound"
        case .cpsat: return "CP-SAT"
        case .automatic: return "Automatic"
        case .portfolio: return "Portfolio"
        case .conditioned: return "Conditioned"
        }
    }

    var systemImage: String {
        switch self {
        case .simplex: return "hexagon"
        case .interiorPoint: return "scope"
        case .branchAndBound: return "arrow.triangle.branch"
        case .cpsat: return "puzzlepiece"
        case .automatic: return "wand.and.stars"
        case .portfolio: return "flag.checkered"
        case .conditioned: return "stethoscope"
        }
    }

    var summary: String {
        switch self {
        case .simplex:
            return """
                Bounded-variable revised simplex: walks from vertex to vertex of the feasible \
                region. Returns a basis and shadow prices, and a ray when the problem is \
                unbounded or infeasible.
                """
        case .interiorPoint:
            return """
                Mehrotra predictor–corrector through the interior of the feasible region, then \
                crossover-lite to a vertex. Cannot always tell infeasible from unbounded.
                """
        case .branchAndBound:
            return """
                Parallel tree search for models with integer variables. Every node solves an \
                LP relaxation; the best open node is a proven bound on the optimum.
                """
        case .cpsat:
            return """
                Clause learning with linear propagation, in exact integer arithmetic, for \
                models whose variables are all integer with finite bounds.
                """
        case .automatic:
            return """
                Chooses from the shape of the problem: dual simplex for LPs up to 4,000 rows, \
                interior point above, branch and bound when there are integer variables.
                """
        case .portfolio:
            return """
                Races several strategies and keeps the first conclusive answer, cancelling the \
                rest. LPs race both simplex methods and the interior point; integer models race \
                branch and bound and CP-SAT.
                """
        case .conditioned:
            return """
                Runs Automatic, then attaches a conditioning report: coefficient ranges, the \
                condition number of the final basis, and findings such as big-M rows.
                """
        }
    }

    /// The label of the variant picker; empty when there is a single configuration.
    var variantTitle: String {
        switch self {
        case .simplex: return "Method"
        case .interiorPoint: return "Crossover"
        case .branchAndBound: return "Node LPs"
        case .cpsat: return "Propagation"
        case .automatic, .portfolio, .conditioned: return ""
        }
    }

    var variants: [Variant] {
        switch self {
        case .simplex:
            return [Variant(id: "dual", label: "Dual"), Variant(id: "primal", label: "Primal")]
        case .interiorPoint:
            return [Variant(id: "lite", label: "Lite"), Variant(id: "none", label: "None")]
        case .branchAndBound:
            return [
                Variant(id: "primal", label: "Primal simplex"), Variant(id: "dual", label: "Dual simplex"),
                Variant(id: "ipm", label: "Interior point"),
            ]
        case .cpsat:
            return [Variant(id: "lp", label: "With LP relaxation"), Variant(id: "cdcl", label: "CDCL only")]
        case .automatic, .portfolio, .conditioned:
            return [Variant(id: "default", label: "Default")]
        }
    }

    var defaultVariant: Variant.ID { variants[0].id }

    /// Whether this tab passes an example's node limit to branch and bound.
    var honorsNodeLimit: Bool { self == .branchAndBound || self == .portfolio }

    /// The examples of this tab, grouped.
    var groups: [ExampleGroup] {
        switch self {
        case .simplex:
            return [
                ExampleGroup("Well conditioned", [Catalog.furniture, Catalog.transport]),
                ExampleGroup("Badly conditioned", [Catalog.hilbert, Catalog.mixedUnits]),
                ExampleGroup("No optimum", [Catalog.unbounded, Catalog.overbooked]),
            ]
        case .interiorPoint:
            return [
                ExampleGroup("Well conditioned", [Catalog.furniture, Catalog.transport]),
                ExampleGroup("Badly conditioned", [Catalog.hilbertSmall, Catalog.mixedUnits]),
                ExampleGroup("No optimum", [Catalog.unbounded, Catalog.overbooked]),
            ]
        case .branchAndBound:
            return [
                ExampleGroup("Well conditioned", [Catalog.knapsack, Catalog.facility]),
                ExampleGroup("Badly conditioned", [Catalog.bigMFacility]),
                ExampleGroup("No optimum", [Catalog.crates, Catalog.tokens]),
                ExampleGroup("Stopped early", [Catalog.projects]),
            ]
        case .cpsat:
            return [
                ExampleGroup("Well conditioned", [Catalog.knapsack]),
                ExampleGroup("Badly conditioned", [Catalog.jobs]),
                ExampleGroup("No optimum", [Catalog.pigeonhole]),
                ExampleGroup("Stopped early", [Catalog.projects]),
                ExampleGroup("Outside CP-SAT's scope", [Catalog.facility]),
            ]
        case .automatic:
            return [
                ExampleGroup("Well conditioned", [Catalog.furniture, Catalog.overtime]),
                ExampleGroup("Badly conditioned", [Catalog.hilbert]),
                ExampleGroup("No optimum", [Catalog.unbounded]),
            ]
        case .portfolio:
            return [
                ExampleGroup("Well conditioned", [Catalog.transport, Catalog.knapsack]),
                ExampleGroup("Badly conditioned", [Catalog.mixedUnits, Catalog.bigMFacility]),
                ExampleGroup("No optimum", [Catalog.overbooked]),
            ]
        case .conditioned:
            return [
                ExampleGroup("Well conditioned", [Catalog.furniture]),
                ExampleGroup(
                    "Badly conditioned",
                    [Catalog.mixedUnits, Catalog.hilbert, Catalog.nearParallel, Catalog.bigMFacility]),
            ]
        }
    }

    func example(id: Example.ID?) -> Example? {
        guard let id else { return nil }
        for group in groups {
            if let example = group.examples.first(where: { $0.id == id }) { return example }
        }
        return nil
    }

    /// The strategy this tab runs on `example`, in the chosen configuration.
    func strategy(_ variant: Variant.ID, for example: Example) -> any SolverStrategy {
        let nodeLimit = example.limits.nodes
        switch self {
        case .simplex:
            return Simplex(variant == "primal" ? .primal : .dual)
        case .interiorPoint:
            return InteriorPoint(crossover: variant == "none" ? .none : .lite)
        case .branchAndBound:
            switch variant {
            case "dual": return BranchAndBound(engine: Simplex(.dual), nodeLimit: nodeLimit)
            case "ipm": return BranchAndBound(engine: InteriorPoint(), nodeLimit: nodeLimit)
            default: return BranchAndBound(engine: Simplex(.primal), nodeLimit: nodeLimit)
            }
        case .cpsat:
            return CPSAT(lpPropagator: variant != "cdcl")
        case .automatic:
            return Automatic()
        case .portfolio:
            // Each race holds only strategies that answer the problem as stated: an LP engine
            // would relax an integer model and "win" with the relaxation's optimum.
            if example.problemClass == .lp {
                return Portfolio([Simplex(.primal), Simplex(.dual), InteriorPoint()])
            }
            return Portfolio([
                BranchAndBound(engine: Simplex(.primal), nodeLimit: nodeLimit),
                BranchAndBound(engine: Simplex(.dual), nodeLimit: nodeLimit),
                CPSAT(),
            ])
        case .conditioned:
            return Conditioned(Automatic())
        }
    }
}
