import Testing
import ZTronLPCore
import ZTronLPTestSupport

@Suite struct FixtureTests {
    /// Day-1 gate: every netlib fixture parses, with the dimensions of the specification's table.
    @Test(arguments: ReferenceValues.netlib)
    func netlibFixtureParses(_ instance: ReferenceInstance) throws {
        let lp = try NetlibFixtures.load(instance.name)
        #expect(lp.m == instance.rows)
        #expect(lp.n == instance.columns)
        #expect(lp.integerColumns.isEmpty)
        #expect(lp.sense == .minimize)
        // Round trip through the writer.
        let again = try MPSFormat.read(MPSFormat.write(lp))
        #expect(again == lp)
    }

    /// §14.1: the reference optima must match the netlib README bundled with the fixtures.
    @Test func referenceValuesMatchTheNetlibReadme() throws {
        let readme = try #require(NetlibFixtures.readme())
        for instance in ReferenceValues.netlib {
            let key = instance.name.uppercased()
            // Every number the README prints on a line that starts with the instance's name.
            var published: [Double] = []
            for line in readme.split(separator: "\n") {
                let tokens = line.split(separator: " ")
                guard tokens.first.map(String.init) == key else { continue }
                for token in tokens.dropFirst() where token.contains("E+") || token.contains("E-") {
                    if let value = Double(token) { published.append(value) }
                }
            }
            #expect(!published.isEmpty, "\(key) is not in the README")
            let best = published.map { ReferenceValues.relativeError($0, reference: instance.optimalObjective) }.min() ?? 1
            #expect(best < 1e-10, "\(key): \(instance.optimalObjective) is not a value the README publishes")
        }
    }

    @Test func constructedInstancesAreFeasibleAndComplementary() {
        for instance in InstanceGenerator.constructedSuite(count: 40, seed: 11) {
            let lp = instance.lp
            let violation = lp.maxViolation(at: instance.primal)
            #expect(violation.bounds <= 1e-9 && violation.rows <= 1e-9)
            // Dual feasibility of the constructed pair, in the minimization form.
            let d = lp.reducedCosts(forDuals: instance.dual)
            for j in 0..<lp.n {
                let x = instance.primal[j]
                if x > lp.xl[j] + 1e-9 { #expect(d[j] <= 1e-9) }
                if x < lp.xu[j] - 1e-9 { #expect(d[j] >= -1e-9) }
            }
            #expect(abs(lp.objective(at: instance.primal) - instance.objective) <= 1e-9 * max(1, abs(instance.objective)))
        }
    }
}
