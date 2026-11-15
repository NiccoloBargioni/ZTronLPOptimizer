// The demo problems, written with the ZTronLPOptimizer DSL.
//
// Each tab picks the examples that suit its strategy (see StrategyKind.groups). Every model is
// small enough to check by hand; the summaries say what the log should show.

import Foundation
import ZTronLPOptimizer

enum Catalog {}

// MARK: - Linear programs, well conditioned

extension Catalog {
    enum Furniture: LPVariable { case chairs, tables, desks }

    static let furniture = Example(
        id: "furniture",
        title: "Furniture workshop",
        subtitle: "3 products share 3 resources",
        summary: """
            Chairs, tables and desks compete for carpentry hours, wood and finishing hours. \
            Every coefficient is a small integer and the optimal basis is far from singular. \
            Known answer: 20 chairs, 5 tables and 10 desks for a profit of 2,000; the shadow \
            prices of the three resources are 1, 2 and 5.
            """,
        formulation: """
            maximize   35 chairs + 70 tables + 95 desks
            subject to  5 chairs + 20 tables + 15 desks ≤ 350  (carpentry)
                       10 chairs + 15 tables + 25 desks ≤ 525  (wood)
                        2 chairs +  4 tables +  6 desks ≤ 120  (finishing)
                       chairs, tables, desks ≥ 0
            """,
        problemClass: .lp,
        conditioning: .well
    ) {
        typealias V = Furniture
        let model = LPModel<V>()
            .maximizing(35 * V.chairs + 70 * V.tables + 95 * V.desks)
            .subjectTo {
                (5 * V.chairs + 20 * V.tables + 15 * V.desks <= 350).named("carpentry")
                (10 * V.chairs + 15 * V.tables + 25 * V.desks <= 525).named("wood")
                (2 * V.chairs + 4 * V.tables + 6 * V.desks <= 120).named("finishing")
            }
        return try BuiltExample(model.compile())
    }

    enum Plant: String, CaseIterable, Sendable { case lyon, milan, porto }
    enum Market: String, CaseIterable, Sendable { case berlin, paris, madrid, rome }
    enum Shipment: LPVariable { case ship(Plant, Market) }

    static let supply: [Plant: Double] = [.lyon: 40, .milan: 35, .porto: 45]
    static let demand: [Market: Double] = [.berlin: 25, .paris: 30, .madrid: 35, .rome: 30]
    static let freight: [Plant: [Market: Double]] = [
        .lyon: [.berlin: 6, .paris: 3, .madrid: 7, .rome: 5],
        .milan: [.berlin: 5, .paris: 6, .madrid: 8, .rome: 3],
        .porto: [.berlin: 9, .paris: 7, .madrid: 3, .rome: 9],
    ]

    static let transport = Example(
        id: "transport",
        title: "Transport plan",
        subtitle: "3 plants ship to 4 markets",
        summary: """
            Ship pallets from three plants to four markets at the lowest freight cost. Supply \
            and demand both total 120, so every row is tight at the optimum. The coefficients \
            are all 1, the classic well-behaved network matrix. The shadow prices of the \
            supply and demand rows are the marginal values of one more pallet at each place.
            """,
        formulation: """
            minimize   Σ freight[p,m] · ship[p,m]
            subject to Σ_m ship[p,m] ≤ supply[p]    p ∈ {lyon, milan, porto}
                       Σ_p ship[p,m] ≥ demand[m]    m ∈ {berlin, paris, madrid, rome}
                       ship ≥ 0
            supply  40, 35, 45     demand  25, 30, 35, 30
            freight lyon  6 3 7 5 · milan 5 6 8 3 · porto 9 7 3 9
            """,
        problemClass: .lp,
        conditioning: .well
    ) {
        typealias V = Shipment
        let model = LPModel<V>()
            .minimizing(
                sum(over: Plant.allCases) { p in
                    sum(over: Market.allCases) { m in freight[p]![m]! * V.ship(p, m) }
                }
            )
            .subjectTo(forEach: Plant.allCases, name: { "supply[\($0)]" }) { p in
                sum(over: Market.allCases) { m in V.ship(p, m) } <= supply[p]!
            }
            .subjectTo(forEach: Market.allCases, name: { "demand[\($0)]" }) { m in
                sum(over: Plant.allCases) { p in V.ship(p, m) } >= demand[m]!
            }
        return try BuiltExample(model.compile())
    }
}

// MARK: - Linear programs, badly conditioned

extension Catalog {
    enum HilbertVar: LPVariable {
        case x(Int)
        var domain: VariableDomain { .free }
    }

    /// The Hilbert system for the simplex-based tabs: the largest size the simplex method still
    /// solves. At 8 × 8 it declares the system unbounded.
    static let hilbert = hilbertSystem(size: 7)

    /// The Hilbert system for the interior-point tab: from 6 × 6 on, the interior point stops
    /// without a verdict, because its normal equations square the condition number.
    static let hilbertSmall = hilbertSystem(size: 5)

    /// Order of magnitude of the 2-norm condition number of the n × n Hilbert matrix.
    private static let hilbertKappaExponent = [3: 2, 4: 4, 5: 5, 6: 7, 7: 8, 8: 10, 9: 11, 10: 13, 11: 14, 12: 16]

    static func hilbertSystem(size n: Int) -> Example {
        let kappa = hilbertKappaExponent[n].map { "10" + Format.superscriptDigits($0) } ?? "huge"
        return Example(
            id: "hilbert-\(n)",
            title: "Hilbert system",
            subtitle: "\(n) × \(n), condition number ≈ \(kappa)",
            summary: """
                The rows are the \(n) × \(n) Hilbert matrix, with entries 1 / (i + j − 1), the \
                textbook ill-conditioned matrix, and the right-hand side makes the exact answer \
                x = (1, 1, …, 1). Rescaling cannot help: the rows are nearly linearly dependent. \
                Compare the two numbers in the check line: the rows hold almost to machine \
                precision, yet the answer has lost several digits. Each extra row multiplies the \
                condition number by about 30, and a few more rows defeat double precision.
                """,
            formulation: """
                minimize   x₁ + x₂ + … + x\(Format.subscriptDigits(n))
                subject to Σⱼ xⱼ / (i + j − 1) = Σⱼ 1 / (i + j − 1)    i = 1 … \(n)
                           x free
                exact solution: x = (1, 1, …, 1)
                """,
            problemClass: .lp,
            conditioning: .bad
        ) {
            typealias V = HilbertVar
            func h(_ i: Int, _ j: Int) -> Double { 1 / Double(i + j - 1) }
            let model = LPModel<V>()
                .minimizing(sum(over: 1...n) { j in V.x(j) })
                .subjectTo(forEach: 1...n, name: { "row\($0)" }) { i in
                    sum(over: 1...n) { j in h(i, j) * V.x(j) } == (1...n).reduce(0) { $0 + h(i, $1) }
                }
            return try BuiltExample(model.compile()) { compiled, x in
                let error = (1...n).map { abs(compiled.value(of: .x($0), in: x) - 1) }.max() ?? 0
                let residual = compiled.lp.maxViolation(at: x).rows
                return [
                    .info(
                        "Exact answer is x = (1, …, 1): largest error \(Format.sci(error)), "
                            + "although the rows hold to \(Format.sci(residual))")
                ]
            }
        }
    }

    enum Feed: LPVariable { case corn, soy, fishmeal }

    static let mixedUnits = Example(
        id: "mixed-units",
        title: "Feed blend in mixed units",
        subtitle: "coefficients span 12 orders of magnitude",
        summary: """
            One tonne of animal feed blended from corn, soy and fishmeal. Protein is written \
            in grams, selenium in tonnes, fiber in kilograms, so the matrix holds both 10⁻⁷ \
            and 6.5·10⁵. Unscaled, a feasibility tolerance of 10⁻⁷ would swallow the whole \
            selenium row. The engines rescale rows and columns by powers of two first, and \
            still find the blend that costs about 377 per tonne.
            """,
        formulation: """
            minimize   180 corn + 420 soy + 1300 fishmeal          ($ per tonne)
            subject to       corn +      soy +      fishmeal = 1        (tonnes)
                       90000 corn + 440000 soy + 650000 fishmeal ≥ 200000   (g protein)
                          25 corn +     60 soy +     10 fishmeal ≤ 40       (kg fiber)
                        1e-7 corn +   5e-7 soy +   3e-6 fishmeal ≥ 6e-7     (t selenium)
                       corn, soy, fishmeal ≥ 0
            """,
        problemClass: .lp,
        conditioning: .bad
    ) {
        typealias V = Feed
        let model = LPModel<V>()
            .minimizing(180 * V.corn + 420 * V.soy + 1300 * V.fishmeal)
            .subjectTo {
                (V.corn + V.soy + V.fishmeal == 1).named("mass_t")
                (90_000 * V.corn + 440_000 * V.soy + 650_000 * V.fishmeal >= 200_000).named("protein_g")
                (25 * V.corn + 60 * V.soy + 10 * V.fishmeal <= 40).named("fiber_kg")
                (1e-7 * V.corn + 5e-7 * V.soy + 3e-6 * V.fishmeal >= 6e-7).named("selenium_t")
            }
        return try BuiltExample(model.compile()) { compiled, x in
            let share = { (v: V) in Format.percent(compiled.value(of: v, in: x)) }
            return [.info("Blend: corn \(share(.corn)), soy \(share(.soy)), fishmeal \(share(.fishmeal))")]
        }
    }

    enum Pair: LPVariable { case x, y }

    static let nearParallel = Example(
        id: "near-parallel",
        title: "Two almost identical limits",
        subtitle: "rows agree to nine digits",
        summary: """
            Two capacity rows that differ only in the ninth significant digit cross at \
            (1, 1). The optimal value is well determined, the optimal point is not: moving \
            along either row changes the objective by less than the solver's tolerances. \
            The conditioning report flags the pair of near-parallel rows.
            """,
        formulation: """
            maximize   x + (1 + 5·10⁻¹⁰) y
            subject to x + y ≤ 2                      (limitA)
                       x + (1 + 10⁻⁹) y ≤ 2 + 10⁻⁹    (limitB)
                       x, y ≥ 0
            """,
        problemClass: .lp,
        conditioning: .bad
    ) {
        typealias V = Pair
        let eps = 1e-9
        let model = LPModel<V>()
            .maximizing(V.x + (1 + eps / 2) * V.y)
            .subjectTo {
                (V.x + V.y <= 2).named("limitA")
                (V.x + (1 + eps) * V.y <= 2 + eps).named("limitB")
            }
        return try BuiltExample(model.compile()) { compiled, point in
            let x = compiled.value(of: .x, in: point), y = compiled.value(of: .y, in: point)
            let distance = max(abs(x - 1), abs(y - 1))
            if distance < 1e-6 { return [.info("This is the exact optimum, (1, 1)")] }
            let shortfall = (2 + eps / 2) - (x + (1 + eps / 2) * y)
            return [
                .info(
                    "The exact optimum is (1, 1), \(Format.number(distance)) away, yet its objective "
                        + "is better by only \(Format.sci(shortfall))")
            ]
        }
    }
}

// MARK: - Linear programs without an optimum

extension Catalog {
    enum Mix: LPVariable { case basic, premium }

    static let unbounded = Example(
        id: "unbounded",
        title: "Forgotten capacity limit",
        subtitle: "profit grows without limit",
        summary: """
            A product mix whose capacity row was left out: the two remaining rows only bound \
            the ratio of the products, so making more of both raises the profit forever. The \
            simplex proves it and returns a ray, a direction that stays feasible and improves \
            the objective. The interior point may only say “infeasible or unbounded”.
            """,
        formulation: """
            maximize    basic + 2 premium
            subject to −basic +   premium ≤ 2   (blend)
                        basic − 2 premium ≤ 4   (balance)
                        basic, premium ≥ 0
            """,
        problemClass: .lp,
        conditioning: .well
    ) {
        typealias V = Mix
        let model = LPModel<V>()
            .maximizing(V.basic + 2 * V.premium)
            .subjectTo {
                (V.premium - V.basic <= 2).named("blend")
                (V.basic - 2 * V.premium <= 4).named("balance")
            }
        return try BuiltExample(model.compile())
    }

    enum Line: LPVariable { case line1, line2 }

    static let overbooked = Example(
        id: "overbooked",
        title: "Overbooked production line",
        subtitle: "two orders, one shift: infeasible",
        summary: """
            Two machines share one 10-hour shift, but the bolt and nut orders together need \
            at least 16⅔ hours: adding the two order rows gives 3·(line1 + line2) ≥ 50. The \
            simplex proves infeasibility and returns a Farkas certificate: row multipliers \
            whose combination reads 0 ≥ something positive. The interior point only finds \
            that there is no optimum, without telling infeasible from unbounded.
            """,
        formulation: """
            minimize   30 line1 + 40 line2        (hours on each machine)
            subject to   line1 +   line2 ≤ 10     (shift)
                         line1 + 2 line2 ≥ 25     (bolts)
                       2 line1 +   line2 ≥ 25     (nuts)
                       line1, line2 ≥ 0
            """,
        problemClass: .lp,
        conditioning: .well
    ) {
        typealias V = Line
        let model = LPModel<V>()
            .minimizing(30 * V.line1 + 40 * V.line2)
            .subjectTo {
                (V.line1 + V.line2 <= 10).named("shift")
                (V.line1 + 2 * V.line2 >= 25).named("bolts")
                (2 * V.line1 + V.line2 >= 25).named("nuts")
            }
        return try BuiltExample(model.compile())
    }
}

// MARK: - Integer and mixed-integer programs

extension Catalog {
    enum Gear: String, CaseIterable, Sendable {
        case tent, sleepingBag, stove, waterFilter, food, camera, book, chair, firstAid, lantern
    }

    enum Pack: LPVariable {
        case take(Gear)
        var domain: VariableDomain { .binary }
    }

    static let gear: [Gear: (weight: Double, value: Double)] = [
        .tent: (11, 70), .sleepingBag: (7, 50), .stove: (6, 35), .waterFilter: (3, 30),
        .food: (9, 60), .camera: (4, 20), .book: (2, 8), .chair: (8, 25), .firstAid: (2, 28),
        .lantern: (3, 15),
    ]

    static let knapsack = Example(
        id: "knapsack",
        title: "Backpack for a hike",
        subtitle: "10 items, 40 lb, yes or no",
        summary: """
            Pick gear worth the most without exceeding 40 lb. All data are small integers, \
            and the relaxation is tight: it allows half a camera and is worth 283, only two \
            more than the best packing. Known answer: 281 — everything but the camera, the \
            chair and the lantern.
            """,
        formulation: """
            maximize   Σ value[i] · take[i]
            subject to Σ weight[i] · take[i] ≤ 40     take[i] ∈ {0, 1}
            tent 11 lb/70 · sleeping bag 7/50 · stove 6/35 · water filter 3/30 · food 9/60
            camera 4/20 · book 2/8 · chair 8/25 · first aid 2/28 · lantern 3/15
            """,
        problemClass: .binary,
        conditioning: .well
    ) {
        typealias V = Pack
        let model = LPModel<V>()
            .maximizing(sum(over: Gear.allCases) { gear[$0]!.value * V.take($0) })
            .subjectTo {
                (sum(over: Gear.allCases) { gear[$0]!.weight * V.take($0) } <= 40).named("weight")
            }
        return try BuiltExample(model.compile()) { compiled, x in
            let packed = Gear.allCases.filter { compiled.value(of: .take($0), in: x) > 0.5 }
            let weight = packed.reduce(0) { $0 + gear[$1]!.weight }
            return [.info("Packed \(Format.number(weight)) of 40 lb: " + packed.map(\.rawValue).joined(separator: ", "))]
        }
    }

    enum Site: String, CaseIterable, Sendable { case north, south, east }
    enum City: String, CaseIterable, Sendable { case a, b, c, d }

    enum Facility: LPVariable {
        case ship(Site, City)
        case open(Site)
        var domain: VariableDomain {
            switch self {
            case .ship: return .continuous
            case .open: return .binary
            }
        }
    }

    static let fixedCost: [Site: Double] = [.north: 120, .south: 90, .east: 150]
    static let capacity: [Site: Double] = [.north: 60, .south: 45, .east: 80]
    static let cityDemand: [City: Double] = [.a: 20, .b: 25, .c: 15, .d: 30]
    static func unitCost(_ s: Site, _ c: City) -> Double {
        let si = Site.allCases.firstIndex(of: s)!, ci = City.allCases.firstIndex(of: c)!
        return Double(2 + (si * 3 + ci * 5) % 7)
    }

    static let facilityFormulation = """
        minimize   Σ fixed[s] · open[s] + Σ cost[s,c] · ship[s,c]
        subject to Σ_c ship[s,c] ≤ capacity[s] · open[s]      (supply[s])
                   Σ_s ship[s,c] ≥ demand[c]                  (demand[c])
                   ship ≥ 0, open[s] ∈ {0, 1}
        fixed 120, 90, 150 · capacity 60, 45, 80 · demand 20, 25, 15, 30
        """

    static let facility = Example(
        id: "facility",
        title: "Facility location",
        subtitle: "open 3 sites? ship to 4 cities",
        summary: """
            Decide which of three warehouses to open (a fixed cost each) and how to serve four \
            cities from the open ones. The shipments are continuous and the open decisions \
            binary; each site's capacity row switches it on and off, with the smallest \
            coefficient that works, its capacity. That keeps the relaxation strong: 409 \
            against an optimum of 505, where the big-M version manages only 235.
            """,
        formulation: facilityFormulation,
        problemClass: .mixedInteger,
        conditioning: .well
    ) {
        typealias V = Facility
        let model = LPModel<V>()
            .minimizing(
                sum(over: Site.allCases) { s in
                    fixedCost[s]! * V.open(s) + sum(over: City.allCases) { c in unitCost(s, c) * V.ship(s, c) }
                }
            )
            .subjectTo(forEach: Site.allCases, name: { "supply[\($0)]" }) { s in
                sum(over: City.allCases) { c in V.ship(s, c) } <= capacity[s]! * V.open(s)
            }
            .subjectTo(forEach: City.allCases, name: { "demand[\($0)]" }) { c in
                sum(over: Site.allCases) { s in V.ship(s, c) } >= cityDemand[c]!
            }
        return try BuiltExample(model.compile(), check: facilityCheck)
    }

    static let bigM = 1e8

    static let bigMFacility = Example(
        id: "big-m-facility",
        title: "Facility location with a big M",
        subtitle: "ship ≤ 10⁸ · open",
        summary: """
            The same warehouses, linked the careless way: every shipment gets ship ≤ M · open \
            with M = 10⁸ instead of the capacity. The relaxation becomes useless, and worse: \
            open = 3·10⁻⁷ already counts as 0 under the integrality tolerance of 10⁻⁶, yet \
            lets 30 units through. The solver reports 235 with every warehouse closed, while \
            the true optimum is 505. Read the check lines, and the Conditioned tab, which \
            flags the big-M rows.
            """,
        formulation: """
            minimize   Σ fixed[s] · open[s] + Σ cost[s,c] · ship[s,c]
            subject to Σ_c ship[s,c] ≤ capacity[s]               (capacity[s])
                       ship[s,c] ≤ 10⁸ · open[s]                  (link[s,c])
                       Σ_s ship[s,c] ≥ demand[c]                  (demand[c])
                       ship ≥ 0, open[s] ∈ {0, 1}
            """,
        problemClass: .mixedInteger,
        conditioning: .bad
    ) {
        typealias V = Facility
        let model = LPModel<V>()
            .minimizing(
                sum(over: Site.allCases) { s in
                    fixedCost[s]! * V.open(s) + sum(over: City.allCases) { c in unitCost(s, c) * V.ship(s, c) }
                }
            )
            .subjectTo(forEach: Site.allCases, name: { "capacity[\($0)]" }) { s in
                sum(over: City.allCases) { c in V.ship(s, c) } <= capacity[s]!
            }
            .subjectTo {
                for s in Site.allCases {
                    for c in City.allCases {
                        (V.ship(s, c) <= bigM * V.open(s)).named("link[\(s),\(c)]")
                    }
                }
            }
            .subjectTo(forEach: City.allCases, name: { "demand[\($0)]" }) { c in
                sum(over: Site.allCases) { s in V.ship(s, c) } >= cityDemand[c]!
            }
        return try BuiltExample(model.compile(), check: facilityCheck)
    }

    /// Which sites are open, and whether a closed site still ships.
    static func facilityCheck(_ compiled: CompiledModel<Facility>, _ x: [Double]) -> [CheckLine] {
        var open: [String] = []
        var leaks: [String] = []
        for s in Site.allCases {
            let flag = compiled.value(of: .open(s), in: x)
            let shipped = City.allCases.reduce(0) { $0 + compiled.value(of: .ship(s, $1), in: x) }
            if flag > 0.5 {
                open.append(s.rawValue)
            } else if shipped > 1e-6 {
                leaks.append("\(s.rawValue) counts as closed (open = \(Format.sci(flag))) yet ships \(Format.number(shipped))")
            }
        }
        var lines: [CheckLine] = [.info("Open sites: " + (open.isEmpty ? "none" : open.joined(separator: ", ")))]
        if leaks.isEmpty {
            lines.append(.info("Logic check: no closed site ships anything"))
        } else {
            lines.append(.problem("Logic check failed: " + leaks.joined(separator: "; ")))
            lines.append(.problem("Open × M within the integrality tolerance lets goods through closed sites; the true optimum costs more."))
        }
        return lines
    }

    enum Crate: LPVariable {
        case small, large
        var domain: VariableDomain { .integer(.range(0...10)) }
    }

    static let crates = Example(
        id: "crates",
        title: "Crates of 6 and 9",
        subtitle: "exactly 20 bottles: impossible",
        summary: """
            Fill an order of exactly 20 bottles with crates of 6 and of 9. Any combination \
            holds a multiple of 3, so there is no integer solution — yet the LP relaxation \
            is feasible (3⅓ small crates), so no certificate exists at the root. Branch and \
            bound has to close every branch to prove it.
            """,
        formulation: """
            minimize   small + large
            subject to 6 small + 9 large = 20
                       small, large ∈ {0, 1, …, 10}
            """,
        problemClass: .integer,
        conditioning: .well
    ) {
        typealias V = Crate
        let model = LPModel<V>()
            .minimizing(V.small + V.large)
            .subjectTo { (6 * V.small + 9 * V.large == 20).named("exactly20") }
        return try BuiltExample(model.compile())
    }

    enum Token: LPVariable {
        case red, blue
        var domain: VariableDomain { .integer }
    }

    static let tokens = Example(
        id: "tokens",
        title: "Unlimited tokens",
        subtitle: "integer program, unbounded",
        summary: """
            Collect red and blue tokens; the two counts may differ by at most one, and \
            nothing else limits them. The integer program is unbounded (take n of each), but \
            branch and bound only sees that the LP relaxation is unbounded, which leaves \
            “infeasible or unbounded” for the integer problem.
            """,
        formulation: """
            maximize   red + blue
            subject to red − blue ≤ 1
                       blue − red ≤ 1
                       red, blue ∈ {0, 1, 2, …}
            """,
        problemClass: .integer,
        conditioning: .well
    ) {
        typealias V = Token
        let model = LPModel<V>()
            .maximizing(V.red + V.blue)
            .subjectTo {
                (V.red - V.blue <= 1).named("redLead")
                (V.blue - V.red <= 1).named("blueLead")
            }
        return try BuiltExample(model.compile())
    }

    enum Funding: LPVariable {
        case fund(Int)
        var domain: VariableDomain { .binary }
    }

    static let projectCount = 40
    static let yearCount = 5

    /// Deterministic data: correlated costs and values make the instance hard to close.
    static let projectData: (cost: [[Double]], value: [Double], budget: [Double]) = {
        var state: UInt64 = 0x5EED_1234_ABCD
        func next(_ range: ClosedRange<Int>) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(range.lowerBound + Int((state >> 33) % UInt64(range.count)))
        }
        let cost = (0..<yearCount).map { _ in (0..<projectCount).map { _ in next(10...60) } }
        let value = (0..<projectCount).map { j in
            (0..<yearCount).reduce(0) { $0 + cost[$1][j] } / Double(yearCount) + next(0...8)
        }
        let budget = cost.map { ($0.reduce(0, +) / 2).rounded() }
        return (cost, value, budget)
    }()

    static let projects = Example(
        id: "projects",
        title: "Research portfolio",
        subtitle: "40 projects, 5 yearly budgets",
        summary: """
            Fund research projects within five yearly budgets. Values track costs closely, \
            which makes the bound hard to close: many selections are almost equally good. \
            This run is capped (300 nodes for branch and bound, 1 s overall), so expect a \
            good solution, a proven bound and the gap between them instead of a proof.
            """,
        formulation: """
            maximize   Σ value[j] · fund[j]                    j = 1 … 40
            subject to Σ cost[y,j] · fund[j] ≤ budget[y]       y = 1 … 5
                       fund[j] ∈ {0, 1}
            costs 10 … 60, values ≈ mean cost + 0 … 8, budgets = half the total cost
            """,
        problemClass: .binary,
        conditioning: .well,
        limits: .init(seconds: 1, nodes: 300)
    ) {
        typealias V = Funding
        let data = projectData
        let model = LPModel<V>()
            .maximizing(sum(over: 0..<projectCount) { data.value[$0] * V.fund($0 + 1) })
            .subjectTo(forEach: 0..<yearCount, name: { "budget[year\($0 + 1)]" }) { y in
                sum(over: 0..<projectCount) { data.cost[y][$0] * V.fund($0 + 1) } <= data.budget[y]
            }
        return try BuiltExample(model.compile()) { compiled, x in
            let funded = (1...projectCount).filter { compiled.value(of: .fund($0), in: x) > 0.5 }
            return [.info("Funded \(funded.count) of \(projectCount) projects")]
        }
    }

    enum Job: String, CaseIterable, Sendable { case a, b, c, d }

    enum Sequencing: LPVariable {
        case start(Job)
        case before(Job, Job)
        var domain: VariableDomain {
            switch self {
            case .start: return .integer(.range(0...100))
            case .before: return .binary
            }
        }
    }

    static let duration: [Job: Double] = [.a: 7, .b: 4, .c: 9, .d: 5]
    static let weight: [Job: Double] = [.a: 3, .b: 1, .c: 4, .d: 2]
    static let jobM = 1e6

    static let jobs = Example(
        id: "jobs",
        title: "Job sequencing with a big M",
        subtitle: "4 jobs, one machine, M = 10⁶",
        summary: """
            Order four jobs on one machine to minimize the weighted sum of completion times. \
            Each pair of jobs is kept apart by two big-M rows with M = 10⁶ against durations \
            of 4 to 9: a weak, badly scaled formulation. CP-SAT reasons in exact integer \
            arithmetic, so the big M costs it nothing. Known answer: c → a → d → b, total 151.
            """,
        formulation: """
            minimize   Σ weight[j] · (start[j] + duration[j])
            subject to start[i] + duration[i] ≤ start[j] + 10⁶ · (1 − before[i,j])
                       start[j] + duration[j] ≤ start[i] + 10⁶ · before[i,j]
                       start[j] ∈ {0 … 100}, before[i,j] ∈ {0, 1}     for every pair i < j
            duration a 7, b 4, c 9, d 5 · weight a 3, b 1, c 4, d 2
            """,
        problemClass: .integer,
        conditioning: .bad
    ) {
        typealias V = Sequencing
        let pairs = Job.allCases.enumerated().flatMap { i, first in
            Job.allCases.dropFirst(i + 1).map { (first, $0) }
        }
        let model = LPModel<V>()
            .minimizing(sum(over: Job.allCases) { j in weight[j]! * (V.start(j) + duration[j]!) })
            .subjectTo {
                for (i, j) in pairs {
                    (V.start(i) + duration[i]! <= V.start(j) + jobM * (1 - V.before(i, j))).named("\(i)_before_\(j)")
                    (V.start(j) + duration[j]! <= V.start(i) + jobM * V.before(i, j)).named("\(j)_before_\(i)")
                }
            }
        return try BuiltExample(model.compile()) { compiled, x in
            let starts = Job.allCases.map { ($0, compiled.value(of: .start($0), in: x)) }.sorted { $0.1 < $1.1 }
            var overlaps = 0
            for (k, (job, start)) in starts.enumerated().dropLast()
            where start + duration[job]! > starts[k + 1].1 + 1e-6 {
                overlaps += 1
            }
            let order = starts.map { "\($0.0.rawValue)@\(Format.number($0.1))" }.joined(separator: " → ")
            let text = "Schedule: \(order)"
            return overlaps == 0
                ? [.info(text + "; no overlaps")]
                : [.problem(text + "; \(overlaps) overlapping pair(s)")]
        }
    }

    enum Seating: LPVariable {
        case seat(guest: Int, room: Int)
        var domain: VariableDomain { .binary }
    }

    static let guests = 7
    static let rooms = 6

    static let pigeonhole = Example(
        id: "pigeonhole",
        title: "Seven guests, six rooms",
        subtitle: "pigeonhole: infeasible",
        summary: """
            Every guest needs a room of their own, and there is one room too few. The linear \
            relaxation sees it at once (7 seats needed, at most 6 available). Clause learning \
            alone must refute every partial assignment, which is notoriously expensive: \
            compare the two propagation settings.
            """,
        formulation: """
            find       seat[g,r] ∈ {0, 1}
            subject to Σ_r seat[g,r] = 1     every guest g = 1 … 7 gets a room
                       Σ_g seat[g,r] ≤ 1     every room r = 1 … 6 holds at most one guest
            """,
        problemClass: .binary,
        conditioning: .well
    ) {
        typealias V = Seating
        let model = LPModel<V>()
            .subjectTo(forEach: 1...guests, name: { "guest\($0)" }) { g in
                sum(over: 1...rooms) { r in V.seat(guest: g, room: r) } == 1
            }
            .subjectTo(forEach: 1...rooms, name: { "room\($0)" }) { r in
                sum(over: 1...guests) { g in V.seat(guest: g, room: r) } <= 1
            }
        return try BuiltExample(model.compile())
    }

    enum Product: String, CaseIterable, Sendable { case chair, table, desk }

    enum Plan: LPVariable {
        case make(Product)
        case overtime
        var domain: VariableDomain {
            switch self {
            case .make: return .integer
            case .overtime: return .binary
            }
        }
    }

    static let overtime = Example(
        id: "overtime",
        title: "Workshop with an overtime shift",
        subtitle: "whole units, open the shift or not",
        summary: """
            The README's example: whole chairs, tables and desks, and a yes-or-no decision to \
            pay 400 for an extra shift of 150 hours. Automatic sees integer variables and \
            hands the model to branch and bound. Known answer: 56 chairs, 6 tables and the \
            overtime shift, for 2,600; the relaxation would open half a shift for 2,725.
            """,
        formulation: """
            maximize   45 chairs + 80 tables + 110 desks − 400 overtime
            subject to  5 chairs + 20 tables + 15 desks ≤ 250 + 150 overtime   (hours)
                       10 chairs + 15 tables + 25 desks ≤ 650                  (wood)
                       chairs, tables, desks ∈ {0, 1, 2, …}, overtime ∈ {0, 1}
            """,
        problemClass: .mixedInteger,
        conditioning: .well
    ) {
        typealias V = Plan
        let profit: [Product: Double] = [.chair: 45, .table: 80, .desk: 110]
        let hours: [Product: Double] = [.chair: 5, .table: 20, .desk: 15]
        let wood: [Product: Double] = [.chair: 10, .table: 15, .desk: 25]
        let model = LPModel<V>()
            .maximizing(sum(over: Product.allCases) { profit[$0]! * V.make($0) } - 400 * V.overtime)
            .subjectTo {
                (sum(over: Product.allCases) { hours[$0]! * V.make($0) } <= 250 + 150 * V.overtime).named("hours")
                (sum(over: Product.allCases) { wood[$0]! * V.make($0) } <= 650).named("wood")
            }
        return try BuiltExample(model.compile())
    }
}
