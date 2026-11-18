// Compile-time check of the shapes README §2 lists. Never executed: if this file compiles, each
// referenced declaration exists with the argument labels the README gives.
import Foundation
import ZTronLPOptimizer

enum APIVar: LPVariable { case x(Int), y }

@inline(never)
func f7APIShapes(_ lp: CompiledLP, _ model: LPModel<APIVar>, _ ctx: SolveContext) async throws {
    // 2.1 Modelling
    _ = APIVar.y.domain; _ = APIVar.y.name
    let _: [VariableKind] = [.continuous, .integer, .binary]
    let _: [Bounds] = [.nonNegative, .free, .unit, .fixed(1), .range(0...1), .atLeast(1), .atMost(2)]
    _ = Bounds.unit.intersection(.nonNegative); _ = Bounds.unit.isFixed
    let _: [VariableDomain] = [.continuous, .free, .integer, .binary, .continuous(.unit), .integer(.unit)]
    _ = LPName.derived(fromDescription: "a"); _ = LPName.sanitized("a b"); _ = LPName.uniqued(["a", "a"])
    var e = LinearExpr<APIVar>()
    _ = APIVar.y.linearExpr; _ = APIVar.y.within(0...1); _ = APIVar.y.equal(to: 1)
    _ = e.constant; _ = e.variables; _ = e.coefficients; _ = e.count; _ = e.isConstant; _ = e[.y]
    e.add(.y, 2); e.add(constant: 1); e.reserveCapacity(4); _ = e.evaluated { _ in 1 }; _ = e.description
    var h = Hasher(); e.hash(into: &h)
    _ = sum(over: 0..<3) { APIVar.x($0) }; _ = LinearExpr<APIVar>.sum(over: 0..<3) { APIVar.x($0) }
    let con = (APIVar.y <= 3).named("c")
    _ = con.expr; _ = con.lower; _ = con.upper; _ = con.name; _ = con.description
    let _: [ObjectiveSense] = [.minimize, .maximize]
    _ = model.objective; _ = model.sense; _ = model.constraints; _ = model.boundOverrides; _ = model.kindOverrides
    _ = model.minimizing(APIVar.y).maximizing(APIVar.y)
        .subjectTo(APIVar.y <= 1)
        .subjectTo { APIVar.y >= 0 }
        .subjectTo(forEach: 0..<2, name: { "r\($0)" }) { APIVar.x($0) <= 1 }
        .bounding(.y, .unit)
        .bounding(forEach: 0..<2, { APIVar.x($0) }, .unit)
        .integer(.y).binary(.y).continuous(.y)
        .integer(forEach: 0..<2, APIVar.x).binary(forEach: 0..<2, APIVar.x).continuous(forEach: 0..<2, APIVar.x)
    var mm = model
    mm.setObjective(.minimize, APIVar.y)
    mm.add(APIVar.y <= 1); mm.add { APIVar.y >= 0 }; mm.add(forEach: 0..<2, name: { "q\($0)" }) { APIVar.x($0) <= 1 }
    mm.setBounds(.y, .unit); mm.setKind(.y, .integer)
    let compiled = try model.compile(options: CompileOptions())
    _ = try model.lpString(); _ = try model.mpsString(free: true)
    var co = CompileOptions(); co.lowerSingletonConstraints = true; co.dropTolerance = 1e-14; co.diagnostics = nil
    // 2.2
    _ = compiled.lp; _ = compiled.column[.y]; _ = compiled.variableAt.first; _ = compiled.rowNamed["c"]; _ = compiled.lowered; _ = compiled.diagnostics
    if let l = compiled.lowered.values.first { _ = l.column; _ = l.coefficient; _ = l.lower; _ = l.upper }
    _ = lp.m; _ = lp.n; _ = lp.a; _ = lp.aT; _ = lp.c; _ = lp.c0; _ = lp.sense; _ = lp.xl; _ = lp.xu; _ = lp.rl; _ = lp.ru
    _ = lp.integerColumns; _ = lp.names; _ = lp.scaling; _ = lp.nnz; _ = lp.hasIntegerColumns; _ = lp.integerMask()
    let x = [Double](repeating: 0, count: lp.n)
    _ = lp.objective(at: x); _ = lp.internalObjective(at: x); _ = lp.reportedObjective(1); _ = lp.rowActivity(x)
    _ = lp.maxViolation(at: x); _ = lp.reducedCosts(forDuals: [Double](repeating: 0, count: lp.m))
    _ = lp.withColumnBounds(xl: lp.xl, xu: lp.xu); _ = lp.withRowBounds(rl: lp.rl, ru: lp.ru)
    _ = lp.withObjective(lp.c, constant: 0); _ = lp.relaxed(); _ = lp.applying([BoundChange(column: 0, lower: 0, upper: 1)])
    _ = lp.names.columns; _ = lp.names.rows; _ = lp.names.column(0); _ = lp.names.row(0); _ = LPNames.default(columns: 2, rows: 1)
    let a = lp.a
    _ = a.rows; _ = a.cols; _ = a.colStart; _ = a.rowIndex; _ = a.values; _ = a.nnz; _ = a.range(ofColumn: 0); _ = a.count(inColumn: 0); _ = a[0, 0]; _ = a.density
    _ = SparseCSC.fromTriplets(rows: 1, cols: 1, [(row: 0, col: 0, value: 1.0)]); _ = a.transposed()
    var out = [Double](repeating: 0, count: lp.m), outT = [Double](repeating: 0, count: lp.n)
    _ = a.multiply(x); _ = a.multiplyTranspose(out); a.multiply(x, into: &out, accumulate: false); a.multiplyTranspose(out, into: &outT)
    _ = a.multiplyTranspose(out, columns: 0..<1); _ = a.dot(column: 0, out); a.axpy(column: 0, 1.0, into: &out); a.scatter(column: 0, into: &out); _ = a.maxAbs(inColumn: 0)
    _ = sparseMultiplyThreshold
    let pre = Presolve.run(lp, tolerances: .default, mode: .full); _ = Presolve.identity(lp)
    _ = pre.outcome; _ = pre.original; _ = pre.reduced; _ = pre.columnOrigin; _ = pre.rowOrigin; _ = pre.removedRows; _ = pre.removedColumns
    _ = pre.isIdentityMapping; _ = pre.unboundedColumn; _ = pre.unboundedDirection
    let _: [Presolve.Mode] = [.off, .boundsOnly, .full]
    switch pre.outcome { case .reduced, .solved, .infeasible: break }
    _ = pre.expandPrimal(x); _ = pre.expandPrimalRay(x); _ = pre.reducePrimal(x); _ = pre.expandDual(out, objective: false)
    let basis = Basis.allLogical(for: lp)
    _ = pre.expandBasis(basis); _ = pre.reduceBasis(basis)
    let factors = Scaler.factors(for: lp, mode: .geometricEquilibration); _ = Scaler.apply(factors, to: lp); _ = Scaler.scale(lp, mode: .equilibration); _ = Scaler.powerOfTwo(nearest: 3)
    let s = factors
    _ = s.rows; _ = s.columns; _ = s.isIdentity; _ = s.unscalePrimal(x); _ = s.scalePrimal(x); _ = s.unscaleDual(out); _ = s.unscaleReducedCosts(x); _ = s.unscaleRowActivity(out)
    let _: [ScalingMode] = [.none, .equilibration, .geometricEquilibration]
    var ro = MPSFormat.ReadOptions(); ro.keepFreeRows = true; ro.fixedColumns = false
    _ = try MPSFormat.read("", options: ro); _ = try MPSFormat.read(contentsOf: URL(fileURLWithPath: "/dev/null"), options: ro); _ = MPSFormat.write(lp, free: true, name: "x")
    _ = try LPFormat.write(lp); _ = try LPFormat.read(""); _ = try LPFormat.read(contentsOf: URL(fileURLWithPath: "/dev/null"))
    // 2.3
    _ = Simplex(.dual).engineName; _ = try await Simplex(.dual).solve(lp); _ = try await Simplex(.dual).solve(model, context: ctx)
    var c2 = ctx
    c2.timeLimit = 1; c2.threads = 1; c2.memoryBudgetBytes = 1; c2.metal = .off; c2.warmStart = .none; c2.progress = nil; c2.accelerator = nil
    _ = c2.resolvedThreads; _ = c2.makeEventStream(); _ = c2.nested(); _ = c2.silenced(); _ = c2.candidateKernels
    c2.attachMetal(MetalAccelerator.shared); _ = c2.attachingMetal(MetalAccelerator.shared); _ = c2.attachingMetal()
    let _: [WarmStart] = [.none, .basis(basis), .incremental(parent: basis, changes: []), .primalPoint(x), .crash(.slack), .crash(.triangular)]
    _ = basis.status; _ = basis.basic; _ = Basis.nonbasicStatus(lower: 0, upper: 1); _ = basis.approximateBytes
    let _: [BasisStatus] = [.basic, .atLower, .atUpper, .free, .fixed]
    let bc = BoundChange(column: 0, lower: 0, upper: 1); _ = bc.column; _ = bc.lower; _ = bc.upper
    let _: [MetalPolicy] = [.off, .automatic, .forced]
    let st: [SolveStatus] = [.optimal, .infeasible, .unbounded, .infeasibleOrUnbounded, .feasible(stoppedBy: .timeLimit), .noSolution(stoppedBy: .cancelled), .numericalFailure("x")]
    _ = st[0].isOptimal; _ = st[0].hasSolution; _ = st[0].stopReason
    let _: [StopReason] = [.timeLimit, .iterationLimit, .nodeLimit, .cancelled, .gapReached, .memoryBudget]
    let diag = ModelDiagnostic(severity: .warning, kind: .syntax(line: 0, message: ""), message: "")
    let _: [SolverError] = [.invalidModel(diag), .unsupported(""), .internalInconsistency("")]
    _ = diag.severity; _ = diag.kind; _ = diag.message
    let _: [ModelDiagnostic.Severity] = [.warning, .error]
    // 2.4
    let sa = try await Simplex(.dual).solve(lp)
    _ = sa.status; _ = sa.objectiveValue; _ = sa.bound; _ = sa.primal; _ = sa.dual; _ = sa.reducedCosts; _ = sa.seconds; _ = sa.warnings
    _ = sa.base; _ = sa.finalBasis
    _ = sa.method; _ = sa.basis; _ = sa.iterations; _ = sa.phase1Iterations; _ = sa.refactorizations; _ = sa.degeneracy; _ = sa.primalRay; _ = sa.dualRay
    let any = AnySolutionAnalysis(sa, engine: "x"); _ = any.engine; _ = any.unwrap(as: SimplexAnalysis.self); _ = any.finalBasis
    let sol = try await Simplex(.dual).solve(model)
    _ = sol.analysis; _ = sol.compiled; _ = sol.status; _ = sol.objectiveValue; _ = sol.value(of: .y); _ = sol.values { _ in true }
    _ = sol.dual(ofConstraintNamed: "c"); _ = sol.reducedCost(of: .y)
    // 2.5
    _ = Simplex(.primal, pricing: .devex, factorization: .automatic, perturbation: .onStall, maxIterations: nil, presolve: true, scaling: .geometricEquilibration, tolerances: .default)
    let _: [Simplex.Pricing] = [.dantzig, .devex, .steepestEdge, .partial(sections: 4)]
    let _: [Simplex.Factorization] = [.automatic, .denseLU, .sparseQR]
    let _: [Simplex.Perturbation] = [.off, .always, .onStall]
    _ = Simplex.denseBasisLimit; _ = Simplex(.dual).makeFactorization(rows: 3); _ = Simplex(.dual).iterationCap(rows: 1, columns: 1)
    var engine = SimplexEngine(lp: lp, strategy: Simplex(.dual), factorization: DenseLUBasis())
    var gate = WorkGate(deadline: .none)
    _ = try await engine.solve(method: .dual, warmStart: .none, cutoff: nil, gate: &gate)
    engine.applyBoundChanges([bc]); _ = engine.basis
    let ip = InteriorPoint(crossover: .lite, maxIterations: 200, regularization: .init(primal: 1e-8, dual: 1e-10), presolve: true, scaling: .geometricEquilibration, tolerances: .default)
    let ia = try await ip.solve(lp)
    _ = ia.iterations; _ = ia.finalMu; _ = ia.primalResidual; _ = ia.dualResidual; _ = ia.crossover; _ = ia.finalBasis
    let bb = BranchAndBound(engine: Simplex(.dual), branching: .mostFractional, nodeSelection: .depthFirst, heuristics: .none, gap: Gap(), nodeLimit: 10, deterministic: true, seed: 1)
    let ba = try await bb.solve(lp)
    _ = ba.root; _ = ba.gap; _ = ba.nodesProcessed; _ = ba.nodesOpen; _ = ba.lpIterations; _ = ba.incumbents; _ = ba.incumbentHistory; _ = ba.finalBasis
    if let ev = ba.incumbentHistory.first { _ = ev.objective; _ = ev.node; _ = ev.seconds; _ = ev.source }
    let _: [BranchingRule] = [.mostFractional, .pseudocost(reliability: 4), .strong(candidates: 8)]
    let _: [NodeSelection] = [.bestBound, .bestBoundWithPlunging(maxDepth: 32), .depthFirst]
    let _: Basis.Type = Simplex.State.self
    let _: SimplexEngine.Type = Simplex.Worker.self
    let _: Basis.Type = InteriorPoint.State.self
    let _: InteriorPointNodeWorker.Type = InteriorPoint.Worker.self
    let cp = CPSAT(workers: 1, restarts: .luby(unit: 100), clauseSharing: true, lpPropagator: true, seed: 0, deterministic: true)
    let _: [RestartPolicy] = [.luby(unit: 100), .geometric(first: 100, factor: 1.5), .never]
    _ = RestartPolicy.lubyTerm(3)
    let ca = try await cp.solve(lp)
    _ = ca.conflicts; _ = ca.decisions; _ = ca.propagations; _ = ca.restarts; _ = ca.learnedClauses; _ = ca.workers; _ = ca.winningWorker; _ = ca.lpSolves
    let _: [Automatic.Choice] = [.branchAndBound, .dualSimplex, .sparseSimplex, .interiorPoint]
    _ = Automatic.choice(for: lp); _ = Automatic.hasDenseColumn(lp)
    let pf = Portfolio([Simplex(.dual), Simplex(.primal)]); _ = pf.strategies
    let pa = try await pf.solve(lp); _ = pa.winner; _ = pa.others
    let cd = Conditioned(Simplex(.dual)); _ = cd.inner
    let cda = try await cd.solve(lp); _ = cda.base; _ = cda.report; _ = cda.finalBasis
    // 2.6
    let rep = await ConditioningAnalyzer.analyze(lp, basis: nil, primal: nil, context: ctx, options: .init(), budget: nil)
    _ = await ConditioningAnalyzer.analyze(lp, after: sa, context: ctx, options: .init(), budget: nil)
    _ = rep.coefficientRange.matrix; _ = rep.coefficientRange.objective; _ = rep.suggestedScaling; _ = rep.basisConditionEstimate
    _ = rep.findings; _ = rep.omittedFindings; _ = rep.basisAnalysis; _ = rep.dimensions; _ = rep.scalingIsApplied; _ = rep.worstSeverity
    _ = rep.findings(of: .severe); _ = rep.summary; _ = rep.markdown
    let _: [Finding.Severity] = [.info, .warning, .severe]
    let _: [BasisAnalysisOutcome] = [.noBasis, .invalidBasis, .tooManyRows(5), .overMemoryBudget, .analyzed]
    // 2.7
    let v: DenseVector = [1, 2]
    _ = Vec.dot(v, v); _ = Vec.norm2(v); _ = Vec.maxAbs(v); _ = Vec.sum(v); _ = Vec.toSingle(v)
    _ = IndexedVector.sparseDensity
    let dm = DenseMatrix.identity(2); _ = dm.rows; _ = dm.cols; _ = dm.storage; _ = dm[0, 0]; _ = DenseMatrix(a)
    _ = dm.multiply(v); _ = dm.multiplyTranspose(v); _ = dm.multiplied(by: dm); _ = dm.weightedGram(v); _ = dm.oneNorm(); _ = dm.transposed()
    let lu = try DenseLU(dm); var r = v
    lu.solve(&r, transpose: false); _ = lu.deficientPivots(relativeTolerance: 1e-9); _ = lu.reciprocalCondition(); _ = lu.conditionEstimate()
    _ = lu.factors; _ = lu.pivots; _ = lu.oneNorm; _ = lu.smallestPivot; _ = lu.largestPivot
    let ch = try DenseCholesky(lowerTriangleOf: dm); ch.solve(&r); _ = ch.factor
    let qr = try DenseQR(dm); _ = qr.rank(relativeTolerance: 1e-11); _ = qr.solveLeastSquares(v); _ = qr.factors; _ = qr.tau
    _ = denseSolve(dm, v); triangularSolve(dm, &r, upper: true, transpose: false, unitDiagonal: false)
    let _: [NumericalError] = [.singular(positions: [], rows: []), .notPositiveDefinite(0), .unstableUpdate(pivot: 0), .factorizationFailed("")]
    let _: [SparseSymmetricSolver.Kind] = [.cholesky, .ldlt]
    var lub = DenseLUBasis(); _ = lub.refactorInterval; _ = lub.dropTolerance; _ = lub.singularityTolerance
    try lub.refactor(basic: [], lp: lp); _ = lub.updatesSinceRefactor; _ = lub.needsRefactor; _ = lub.conditionEstimate()
    var qb = SparseQRBasis(); _ = qb.refactorInterval; _ = qb.dropTolerance; _ = qb.updatesSinceRefactor
    _ = basisDensity(basic: [], lp: lp)
    _ = KernelThresholds.allowsReducedCostScan(columns: 1, nonzeros: 1, policy: .automatic); _ = KernelThresholds.allowsBatchedActivity(points: 1, nonzeros: 1, policy: .automatic)
    _ = [PricingEligibility.none, PricingEligibility.increase, PricingEligibility.decrease, PricingEligibility.either]
    var gd = KernelDisagreementGuard(); gd.record(candidates: 1, disagreements: 0); _ = gd.disagreementRate; _ = gd.candidates; _ = gd.disagreements; _ = gd.isDisabled; _ = gd.minimumSample
    // 2.8
    let dl = Deadline.after(seconds: 1); _ = dl.uptimeNanoseconds; _ = Deadline.none; _ = Deadline.now; _ = dl.hasPassed; _ = dl.remainingSeconds; _ = dl.earlier(.none)
    let _: [StopSignal] = [.cancelled, .deadline]; _ = StopSignal.cancelled.stopReason
    let flag = StopFlag(); flag.set(); _ = flag.isSet
    var g2 = WorkGate(deadline: .none, checkEvery: 64, yieldEvery: 10_000_000); try await g2.tick(); try await g2.check()
    _ = g2.stopFlag; _ = g2.checks; _ = g2.yields; _ = g2.elapsedNanoseconds; _ = g2.elapsedSeconds; _ = g2.currentDeadline
    let budget = ConcurrencyBudget(threads: 2); _ = budget.capacity; let got = await budget.borrow(upTo: 1); await budget.giveBack(got); _ = await budget.slotsInUse; _ = await budget.peakInUse
    _ = await parallelBlocks(count: 10, blocks: 2, budget: budget) { (r: Range<Int>) in r.count }
    _ = MemoryBudget.availableBytes(); _ = MemoryBudget.resolve(ctx); _ = secondsSince(Deadline.now)
    // 2.9
    _ = MetalAccelerator.shared; _ = MetalAccelerator(); _ = await MetalAccelerator.shared.status(); _ = await MetalAccelerator.shared.isAvailable
    _ = await MetalAccelerator.shared.reducedCostScanner(for: lp, policy: .forced); _ = await MetalAccelerator.shared.activityEvaluator(for: lp, policy: .forced)
    let _: [MetalContext.LibrarySource] = [.precompiled, .compiledFromSource]
}
