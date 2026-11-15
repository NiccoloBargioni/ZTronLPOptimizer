// Reference values for the public corpora (specification §14.1).
//
// The netlib optima were re-verified against the netlib README bundled next to the fixtures
// (`Fixtures/netlib/README.netlib.txt`, fetched from https://www.netlib.org/lp/data/readme)
// before the tests were enabled, as the specification requires: a mistyped constant must not
// become the oracle. Twelve values are the README's PROBLEM SUMMARY TABLE entries verbatim.
// SCAGR7 is the exception the README itself documents: its summary table carries the MINOS 5.0
// value −2.3313892548E+06, and its later table of differing results gives the CPLEX value
// −2.3313898243E+06, which is the one the specification lists and the accepted optimum. The two
// differ by 2.4e-7 relative, inside the 1e-6 test tolerance either way.
//
// Row counts exclude the objective row (the README counts it; subtract one).

/// One instance of a public corpus with its published optimum.
public struct ReferenceInstance: Sendable, Hashable {
    public let name: String
    /// Constraint rows (objective row not counted).
    public let rows: Int
    public let columns: Int
    /// The published optimal objective.
    public let optimalObjective: Double
    /// Whether every column is integer. CP-SAT accepts only those; §14.2 lists it as an
    /// engine for the first six MIPLIB instances.
    public let pureInteger: Bool

    public init(name: String, rows: Int, columns: Int, optimalObjective: Double, pureInteger: Bool = false) {
        self.name = name
        self.rows = rows
        self.columns = columns
        self.optimalObjective = optimalObjective
        self.pureInteger = pureInteger
    }
}

public enum ReferenceValues {
    /// The relative error above which a corpus test fails.
    public static let relativeTolerance = 1e-6

    /// The thirteen netlib LP instances of §14.1, bundled as MPS.
    public static let netlib: [ReferenceInstance] = [
        ReferenceInstance(name: "afiro", rows: 27, columns: 32, optimalObjective: -4.6475314286e+02),
        ReferenceInstance(name: "sc50a", rows: 50, columns: 48, optimalObjective: -6.4575077059e+01),
        ReferenceInstance(name: "sc50b", rows: 50, columns: 48, optimalObjective: -7.0000000000e+01),
        ReferenceInstance(name: "sc105", rows: 105, columns: 103, optimalObjective: -5.2202061212e+01),
        ReferenceInstance(name: "kb2", rows: 43, columns: 41, optimalObjective: -1.7499001299e+03),
        ReferenceInstance(name: "adlittle", rows: 56, columns: 97, optimalObjective: 2.2549496316e+05),
        ReferenceInstance(name: "blend", rows: 74, columns: 83, optimalObjective: -3.0812149846e+01),
        ReferenceInstance(name: "share2b", rows: 96, columns: 79, optimalObjective: -4.1573224074e+02),
        ReferenceInstance(name: "stocfor1", rows: 117, columns: 111, optimalObjective: -4.1131976219e+04),
        ReferenceInstance(name: "scagr7", rows: 129, columns: 140, optimalObjective: -2.3313898243e+06),
        ReferenceInstance(name: "beaconfd", rows: 173, columns: 262, optimalObjective: 3.3592485807e+04),
        ReferenceInstance(name: "israel", rows: 174, columns: 142, optimalObjective: -8.9664482186e+05),
        ReferenceInstance(name: "degen2", rows: 444, columns: 534, optimalObjective: -1.4351780000e+03),
    ]

    /// The ten MIPLIB 3 instances of §14.2. They are not bundled: `Scripts/fetch-miplib.sh`
    /// downloads them with pinned SHA-256 checksums into `.corpora/miplib3`.
    public static let miplib3: [ReferenceInstance] = [
        ReferenceInstance(name: "p0033", rows: 16, columns: 33, optimalObjective: 3089, pureInteger: true),
        ReferenceInstance(name: "stein27", rows: 118, columns: 27, optimalObjective: 18, pureInteger: true),
        ReferenceInstance(name: "stein45", rows: 331, columns: 45, optimalObjective: 30, pureInteger: true),
        ReferenceInstance(name: "enigma", rows: 21, columns: 100, optimalObjective: 0, pureInteger: true),
        ReferenceInstance(name: "lseu", rows: 28, columns: 89, optimalObjective: 1120, pureInteger: true),
        ReferenceInstance(name: "mod008", rows: 6, columns: 319, optimalObjective: 307, pureInteger: true),
        ReferenceInstance(name: "flugpl", rows: 18, columns: 18, optimalObjective: 1_201_500),
        ReferenceInstance(name: "egout", rows: 98, columns: 141, optimalObjective: 568.1007),
        ReferenceInstance(name: "misc03", rows: 96, columns: 160, optimalObjective: 3360),
        ReferenceInstance(name: "p0201", rows: 133, columns: 201, optimalObjective: 7615, pureInteger: true),
    ]

    /// The netlib instance with the given name.
    public static func netlib(named name: String) -> ReferenceInstance? {
        netlib.first { $0.name == name }
    }

    /// The MIPLIB 3 instance with the given name.
    public static func miplib3(named name: String) -> ReferenceInstance? {
        miplib3.first { $0.name == name }
    }

    /// |value − reference| / max(1, |reference|).
    public static func relativeError(_ value: Double, reference: Double) -> Double {
        abs(value - reference) / max(1, abs(reference))
    }
}
