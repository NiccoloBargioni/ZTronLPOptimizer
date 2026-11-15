// Specification §4.2 and §4.5: variables, domains, default names, and the model's chaining
// methods with their mutating twins.

import Testing
import ZTronLPCore

/// Payload types of several shapes, for the default-name tests.
private enum Color: Hashable, Sendable { case red, green }

private enum Outer {
    struct Inner: Hashable, Sendable { let id: Int }
}

private enum Named: LPVariable {
    case city(String)
    case edge(from: Int, to: Int)
    case paint(Color)
    case nested(Outer.Inner)
    case negative(Int)
    case real(Double)
}

/// Every variable of this family claims the same name.
private enum Clash: LPVariable {
    case a, b, c
    var name: String { "v" }
}

/// A family that overrides the name of one case only.
private enum Custom: LPVariable {
    case plain(Int)
    case special
    var name: String {
        if case .special = self { return "TheSpecialOne" }
        return LPName.derived(fromDescription: String(describing: self))
    }
}

@Suite("DSL · variables and model")
struct DSLModelTests {
    // MARK: Bounds and domains

    @Test func boundsConstructors() {
        #expect(Bounds.nonNegative == Bounds(lower: 0, upper: inf))
        #expect(Bounds.free == Bounds(lower: -inf, upper: inf))
        #expect(Bounds.unit == Bounds(lower: 0, upper: 1))
        #expect(Bounds.fixed(2.5) == Bounds(lower: 2.5, upper: 2.5))
        #expect(Bounds.range(-1...4) == Bounds(lower: -1, upper: 4))
        #expect(Bounds.atLeast(3) == Bounds(lower: 3, upper: inf))
        #expect(Bounds.atMost(3) == Bounds(lower: -inf, upper: 3))
        #expect(Bounds.fixed(2).isFixed)
        #expect(!Bounds.unit.isFixed)
        #expect(!Bounds(lower: inf, upper: inf).isFixed)
        #expect(Bounds.range(0...5).intersection(.range(2...9)) == Bounds.range(2...5))
        let empty = Bounds.atLeast(4).intersection(.atMost(1))
        #expect(empty.lower > empty.upper)
    }

    @Test func domains() {
        #expect(VariableDomain.continuous == VariableDomain(kind: .continuous, bounds: .nonNegative))
        #expect(VariableDomain.free == VariableDomain(kind: .continuous, bounds: .free))
        #expect(VariableDomain.integer == VariableDomain(kind: .integer, bounds: .nonNegative))
        #expect(VariableDomain.binary == VariableDomain(kind: .binary, bounds: .unit))
        #expect(VariableDomain.continuous(.range(1...2)) == VariableDomain(kind: .continuous, bounds: .range(1...2)))
        #expect(VariableDomain.integer(.range(0...9)) == VariableDomain(kind: .integer, bounds: .range(0...9)))

        // The default domain is continuous, x ≥ 0; a family can override it per case.
        #expect(XY.x.domain == .continuous)
        #expect(Mixed.free(0).domain == .free)
        #expect(Mixed.count(0).domain == .integer)
        #expect(Mixed.flag(0).domain == .binary)
        #expect(Mixed.boxed(0).domain.bounds == .range(-2...5))
        #expect(FacilityVars.open(Plant(id: 0)).domain.kind == .binary)
        #expect(FacilityVars.ship(Plant(id: 0), Market(id: 0)).domain == .continuous)
    }

    // MARK: Default names

    @Test func defaultNamesOfBareAndIndexedCases() {
        #expect(XY.x.name == "x")
        #expect(XY.z(3).name == "z[3]")
        #expect(Grid.cell(3, 7).name == "cell[3,7]")
        #expect(Grid.cube(1, 2, 3).name == "cube[1,2,3]")
        #expect(Named.edge(from: 4, to: 9).name == "edge[from_4,to_9]")
        #expect(Named.negative(-1).name == "negative[_1]")
        #expect(Named.real(2.5).name == "real[2.5]")
    }

    @Test func defaultNamesOfStructEnumAndStringPayloads() {
        // Module qualifiers that `String(describing:)` adds are removed.
        #expect(FacilityVars.open(Plant(id: 2)).name == "open[Plant[id_2]]")
        #expect(FacilityVars.ship(Plant(id: 1), Market(id: 2)).name == "ship[Plant[id_1],Market[id_2]]")
        #expect(Named.paint(.green).name == "paint[green]")
        #expect(Named.nested(Outer.Inner(id: 5)).name == "nested[Inner[id_5]]")
        // `Color` and `Outer` are private to this file. The runtime prints such types with an
        // "(unknown context at $address)" segment whose address changes between runs; none of
        // it may reach a name.
        for name in [Named.paint(.red).name, Named.nested(Outer.Inner(id: 0)).name] {
            #expect(!name.contains("unknown") && !name.contains("$") && !name.contains("ZTronLPCoreTests"), "\(name)")
        }
        // Quotes and spaces are dropped; a dot inside a string literal is not a qualifier.
        #expect(Named.city("New York").name == "city[NewYork]")
        #expect(Named.city("a.b").name == "city[a.b]")
    }

    @Test func sanitizedNamesUseOnlyTheDocumentedAlphabet() {
        #expect(LPName.sanitized("x(3, 7)") == "x[3,7]")
        #expect(LPName.sanitized("a-b+c") == "a_b_c")
        #expect(LPName.sanitized("") == "_")
        #expect(LPName.sanitized("3rd") == "_3rd")
        #expect(LPName.sanitized(".hidden") == "_.hidden")
        #expect(LPName.sanitized("[x]") == "_[x]")
        #expect(LPName.sanitized("über") == "_ber")
        #expect(LPName.sanitized("keep_this.Name[1,2]") == "keep_this.Name[1,2]")
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.[],")
        for raw in ["ship(Plant(id: 1), Market(id: 2))", "x y\tz\n", "\"quoted\" 'single'", "a:b;c=d", "€42"] {
            let name = LPName.sanitized(raw)
            #expect(!name.isEmpty)
            #expect(name.allSatisfy { allowed.contains($0) }, "\(name)")
        }
        #expect(LPName.derived(fromDescription: "ship(App.Plant(id: 0), App.Market(id: 1))") == "ship[Plant[id_0],Market[id_1]]")
        #expect(LPName.derived(fromDescription: "v(App.Model.Kind.small)") == "v[small]")
        #expect(LPName.derived(fromDescription: "x(1.5)") == "x[1.5]")
        #expect(LPName.derived(fromDescription: "p(App.(unknown context at $10fa3c8).Kind.small)") == "p[small]")
        #expect(LPName.derived(fromDescription: "q(\"a.b\", App.T(id: 2))") == "q[a.b,T[id_2]]")
        #expect(LPName.derived(fromDescription: "plain") == "plain")
    }

    @Test func uniquingIsDeterministic() {
        #expect(LPName.uniqued(["a", "b", "c"]) == ["a", "b", "c"])
        #expect(LPName.uniqued(["a", "a", "b", "a", "a_2"]) == ["a", "a_2", "b", "a_3", "a_2_2"])
        let many = LPName.uniqued([String](repeating: "v", count: 50))
        #expect(Set(many).count == 50)
        #expect(many[0] == "v" && many[1] == "v_2" && many[49] == "v_50")
    }

    @Test func namesAreMadeUniqueAtCompileTime() throws {
        let model = LPModel<Clash>().minimizing(Clash.a + Clash.b + Clash.c)
        let compiled = try model.compile()
        #expect(compiled.lp.names.columns == ["v", "v_2", "v_3"])

        let custom = LPModel<Custom>().minimizing(Custom.plain(1) + Custom.special + Custom.plain(2))
        #expect(try custom.compile().lp.names.columns == ["plain[1]", "TheSpecialOne", "plain[2]"])
    }

    // MARK: Model — chaining

    @Test func anEmptyModel() {
        let model = LPModel<XY>()
        #expect(model.sense == .minimize)
        #expect(model.objective == LinearExpr<XY>())
        #expect(model.constraints.isEmpty && model.boundOverrides.isEmpty && model.kindOverrides.isEmpty)
    }

    @Test func objectiveChaining() {
        let minimized = LPModel<XY>().minimizing(XY.x + 2 * XY.y)
        #expect(minimized.sense == .minimize && minimized.objective == XY.x + 2 * XY.y)
        let maximized = minimized.maximizing(XY.x)          // a bare variable is an expression
        #expect(maximized.sense == .maximize && maximized.objective == LinearExpr(XY.x))
        // The original is untouched: every chaining call returns a modified copy.
        #expect(minimized.sense == .minimize && minimized.objective.count == 2)
    }

    @Test func constraintChaining() {
        let base = LPModel<XY>().minimizing(XY.x)
        let one = base.subjectTo(XY.x >= 1)
        let more = one.subjectTo {
            XY.y >= 2
            XY.x + XY.y <= 9
        }
        let family = more.subjectTo(forEach: 0..<3, name: { "cap[\($0)]" }) { i in XY.z(i) <= Double(i + 1) }
        let unnamedFamily = family.subjectTo(forEach: [10, 20]) { i in XY.z(i) >= 0.5 }

        #expect(base.constraints.isEmpty)
        #expect(one.constraints.count == 1)
        #expect(more.constraints.count == 3)
        #expect(family.constraints.count == 6)
        #expect(family.constraints[3].name == "cap[0]" && family.constraints[5].name == "cap[2]")
        #expect(family.constraints[5].upper == 3)
        #expect(unnamedFamily.constraints.count == 8)
        #expect(unnamedFamily.constraints[7].name == nil && unnamedFamily.constraints[7].lower == 0.5)
    }

    @Test func boundingWithOneTwoAndThreeIndices() {
        let model = LPModel<Grid>()
            .bounding(.line(9), .fixed(4))
            .bounding(forEach: 0..<3, Grid.line, .range(0...5))
            .bounding(forEach: 0..<2, 0..<3, Grid.cell, .free)
            .bounding(forEach: 0..<2, 0..<2, 0..<2, Grid.cube, .atMost(7))
        #expect(model.boundOverrides.count == 1 + 3 + 6 + 8)
        #expect(model.boundOverrides[.line(9)] == .fixed(4))
        #expect(model.boundOverrides[.line(2)] == .range(0...5))
        #expect(model.boundOverrides[.cell(1, 2)] == .free)
        #expect(model.boundOverrides[.cube(1, 0, 1)] == .atMost(7))
        #expect(model.boundOverrides[.cell(2, 0)] == nil)

        // A closure works as well as a case constructor, and a later call replaces an earlier one.
        let replaced = model.bounding(forEach: [1, 2], { Grid.line($0) }, .unit)
        #expect(replaced.boundOverrides[.line(1)] == .unit && replaced.boundOverrides[.line(0)] == .range(0...5))
        #expect(model.boundOverrides[.line(1)] == .range(0...5))
    }

    @Test func kindOverrides() {
        let model = LPModel<XY>()
            .integer(.x)
            .binary(.y)
            .integer(forEach: 0..<3) { XY.z($0) }
            .continuous(.z(1))
        #expect(model.kindOverrides[.x] == .integer)
        #expect(model.kindOverrides[.y] == .binary)
        #expect(model.kindOverrides[.z(0)] == .integer && model.kindOverrides[.z(2)] == .integer)
        #expect(model.kindOverrides[.z(1)] == .continuous)

        let families = LPModel<XY>()
            .binary(forEach: 0..<2, XY.z)
            .continuous(forEach: [5], XY.z)
        #expect(families.kindOverrides == [.z(0): .binary, .z(1): .binary, .z(5): .continuous])
    }

    // MARK: Model — mutating twins

    @Test func mutatingTwinsMatchTheChainingMethods() throws {
        let chained = LPModel<XY>()
            .maximizing(3 * XY.x + XY.y)
            .subjectTo(XY.x + XY.y <= 4)
            .subjectTo {
                XY.x - XY.y >= -2
                for i in 0..<2 { XY.z(i) <= XY.x }
            }
            .subjectTo(forEach: 0..<2, name: { "n\($0)" }) { i in XY.z(i) + XY.y >= Double(i) }
            .bounding(.x, .range(0...3))
            .integer(.y)
            .binary(.z(0))
            .continuous(.z(1))

        var mutated = LPModel<XY>()
        mutated.setObjective(.maximize, 3 * XY.x + XY.y)
        mutated.add(XY.x + XY.y <= 4)
        mutated.add {
            XY.x - XY.y >= -2
            for i in 0..<2 { XY.z(i) <= XY.x }
        }
        mutated.add(forEach: 0..<2, name: { "n\($0)" }) { i in XY.z(i) + XY.y >= Double(i) }
        mutated.setBounds(.x, .range(0...3))
        mutated.setKind(.y, .integer)
        mutated.setKind(.z(0), .binary)
        mutated.setKind(.z(1), .continuous)

        #expect(mutated.sense == chained.sense)
        #expect(mutated.objective == chained.objective)
        #expect(mutated.constraints == chained.constraints)
        #expect(mutated.boundOverrides == chained.boundOverrides)
        #expect(mutated.kindOverrides == chained.kindOverrides)
        #expect(try mutated.compile().lp == chained.compile().lp)

        // The stored properties are plain vars as well.
        mutated.sense = .minimize
        mutated.constraints.removeLast()
        mutated.boundOverrides[.y] = .unit
        #expect(mutated.constraints.count == chained.constraints.count - 1)
        #expect(chained.sense == .maximize)
    }

    @Test func aModelIsAValue() {
        let base = LPModel<XY>().minimizing(XY.x).subjectTo(XY.x >= 1)
        var copy = base
        copy.add(XY.y >= 2)
        copy.setBounds(.x, .unit)
        #expect(base.constraints.count == 1 && base.boundOverrides.isEmpty)
        #expect(copy.constraints.count == 2 && copy.boundOverrides.count == 1)
        requireSendable(LPModel<FacilityVars>.self)
        requireSendable(CompiledModel<FacilityVars>.self)
        requireSendable(CompiledLP.self)
    }

    @Test func exportConveniences() throws {
        let model = LPModel<XY>()
            .minimizing(XY.x + 2 * XY.y)
            .subjectTo((XY.x + XY.y >= 3).named("need"))
        let compiled = try model.compile().lp
        #expect(try model.mpsString() == MPSFormat.write(compiled))
        #expect(try model.mpsString(free: false) == MPSFormat.write(compiled, free: false))
        #expect(try model.lpString() == LPFormat.write(compiled))
        #expect(try model.mpsString().contains("need"))
    }
}
