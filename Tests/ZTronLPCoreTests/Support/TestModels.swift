// Variable families and small helpers shared by the ZTronLPCore suites.

import Foundation
import Testing
import ZTronLPCore

/// Two scalar variables and one indexed family; every variable is continuous, x ≥ 0.
enum XY: LPVariable {
    case x, y
    case z(Int)
}

/// Families with one, two and three indices.
enum Grid: LPVariable {
    case line(Int)
    case cell(Int, Int)
    case cube(Int, Int, Int)
}

struct Plant: Hashable, Sendable { let id: Int }
struct Market: Hashable, Sendable { let id: Int }

/// The variables of the specification's worked example (§4.6).
enum FacilityVars: LPVariable {
    case ship(Plant, Market)
    case open(Plant)

    var domain: VariableDomain {
        switch self {
        case .ship: return .continuous
        case .open: return .binary
        }
    }
}

/// One case per kind of domain.
enum Mixed: LPVariable {
    case free(Int)
    case count(Int)
    case flag(Int)
    case boxed(Int)

    var domain: VariableDomain {
        switch self {
        case .free: return .free
        case .count: return .integer
        case .flag: return .binary
        case .boxed: return .continuous(.range(-2...5))
        }
    }
}

/// The fixed facility-location model the golden files were produced from.
enum FacilityExample {
    static let plants = (0..<3).map(Plant.init)
    static let markets = (0..<4).map(Market.init)

    static func fixedCost(_ p: Plant) -> Double { 100 + 25 * Double(p.id) }
    static func supply(_ p: Plant) -> Double { 60 - 5 * Double(p.id) }
    static func demand(_ m: Market) -> Double { 15 + 2.5 * Double(m.id) }
    static func cost(_ p: Plant, _ m: Market) -> Double { 1.5 + Double(p.id) + 0.25 * Double(m.id * (p.id + 1)) }

    static func model() -> LPModel<FacilityVars> {
        LPModel<FacilityVars>()
            .minimizing(
                sum(over: plants) { p in
                    fixedCost(p) * FacilityVars.open(p)
                        + sum(over: markets) { m in cost(p, m) * FacilityVars.ship(p, m) }
                }
            )
            .subjectTo {
                for p in plants {
                    (sum(over: markets) { m in FacilityVars.ship(p, m) } <= supply(p) * FacilityVars.open(p))
                        .named("supply[\(p.id)]")
                }
                for m in markets {
                    (sum(over: plants) { p in FacilityVars.ship(p, m) } >= demand(m))
                        .named("demand[\(m.id)]")
                }
            }
    }
}

/// Runs `body`, which must throw `SolverError.invalidModel`, and returns the diagnostic.
func invalidModelDiagnostic<T>(
    _ body: () throws -> T, sourceLocation: SourceLocation = #_sourceLocation
) -> ModelDiagnostic? {
    do {
        _ = try body()
        Issue.record("expected SolverError.invalidModel, but nothing was thrown", sourceLocation: sourceLocation)
        return nil
    } catch let error as SolverError {
        if case .invalidModel(let diagnostic) = error { return diagnostic }
        Issue.record("expected SolverError.invalidModel, got \(error)", sourceLocation: sourceLocation)
        return nil
    } catch {
        Issue.record("expected SolverError.invalidModel, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Runs `body`, which must throw `SolverError.unsupported`, and returns the message.
func unsupportedMessage<T>(
    _ body: () throws -> T, sourceLocation: SourceLocation = #_sourceLocation
) -> String? {
    do {
        _ = try body()
        Issue.record("expected SolverError.unsupported, but nothing was thrown", sourceLocation: sourceLocation)
        return nil
    } catch let error as SolverError {
        if case .unsupported(let message) = error { return message }
        Issue.record("expected SolverError.unsupported, got \(error)", sourceLocation: sourceLocation)
        return nil
    } catch {
        Issue.record("expected SolverError.unsupported, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// A small problem built from dense rows, for the hand-solved presolve and scaling cases.
/// `rows[i]` lists the coefficients of row i over all columns (zeros are not stored).
func denseLP(
    rows: [[Double]], rl: [Double], ru: [Double], c: [Double], xl: [Double], xu: [Double],
    c0: Double = 0, sense: ObjectiveSense = .minimize, integer: [Int32] = [],
    names: LPNames? = nil
) -> CompiledLP {
    let n = c.count
    var entries: [(row: Int, col: Int, value: Double)] = []
    for (i, row) in rows.enumerated() {
        precondition(row.count == n, "row \(i) has the wrong length")
        for (j, value) in row.enumerated() where value != 0 { entries.append((i, j, value)) }
    }
    return CompiledLP(
        a: SparseCSC.fromTriplets(rows: rows.count, cols: n, entries), c: c, c0: c0, sense: sense,
        xl: xl, xu: xu, rl: rl, ru: ru, integerColumns: integer, names: names)
}

/// Compile-time check that a type is `Sendable`.
func requireSendable<T: Sendable>(_: T.Type) {}

let inf = Double.infinity

/// How far a primal-dual pair is from optimal for the minimization form of `lp`: the largest
/// of the primal bound and row violations and of the complementary-slackness violations
/// (a positive reduced cost or dual needs its column or row on the lower bound, a negative one
/// on the upper bound). Zero, up to rounding, exactly when `(x, y)` is optimal.
func optimalityViolation(_ lp: CompiledLP, x: [Double], y: [Double], tolerance: Double = 1e-9) -> Double {
    let d = lp.reducedCosts(forDuals: y)
    let activity = lp.rowActivity(x)
    let feasibility = lp.maxViolation(at: x)
    var worst = Swift.max(feasibility.bounds, feasibility.rows)
    for j in 0..<lp.n {
        if d[j] > tolerance { worst = Swift.max(worst, Swift.min(Swift.abs(x[j] - lp.xl[j]), Swift.abs(d[j]))) }
        if d[j] < -tolerance { worst = Swift.max(worst, Swift.min(Swift.abs(lp.xu[j] - x[j]), Swift.abs(d[j]))) }
    }
    for i in 0..<lp.m {
        if y[i] > tolerance { worst = Swift.max(worst, Swift.min(Swift.abs(activity[i] - lp.rl[i]), Swift.abs(y[i]))) }
        if y[i] < -tolerance { worst = Swift.max(worst, Swift.min(Swift.abs(lp.ru[i] - activity[i]), Swift.abs(y[i]))) }
    }
    return worst
}
