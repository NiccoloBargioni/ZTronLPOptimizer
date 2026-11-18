#!/usr/bin/env python3
"""Build VERIFICATION-FINDINGS.md from the finder results and the skeptic verdicts.

Inputs: verification/cycle-{A,B}/F*.json (finder results) and the workflow journals of the
launching session (skeptic verdicts). Main-session tool: this file and its output hold both
cycles' results, so keep them away from the cycles' agents while a verification run is active.

Usage: python3 verification/make-findings-md.py [output.md]
"""
import glob
import json
import os
import re
import sys

ROOT = "/Users/admin/Documents/ZTronLPOptimizer"
VER = ROOT + "/verification"
SESSION = os.path.expanduser(
    "~/.claude/projects/-Users-admin-Documents-ZTronLPOptimizer/7aab57cc-e0cf-4457-93b0-57da6847eb38")
OUT = sys.argv[1] if len(sys.argv) > 1 else ROOT + "/VERIFICATION-FINDINGS.md"
SNAPSHOT = os.environ.get("SNAPSHOT", "2026-11-18, 14:12 CET")
COMMIT = "d9afebe"

AREAS = [
    (1, "core", "Core: DSL, compile, presolve, scaling, MPS/LP I/O, result types"),
    (2, "simplex", "Simplex engine and numerics"),
    (3, "ipm", "Interior point, crossover, conditioning, Conditioned"),
    (4, "bnb", "Branch and bound"),
    (5, "cpsat", "CP-SAT"),
    (6, "runtime", "Runtime: cancellation, limits, events, concurrency, memory budget, Metal, Automatic, Portfolio"),
    (7, "integrity", "Package integrity: gates, docs, published numbers, tests, layering"),
]
SEV = ["critical", "high", "medium", "low", "info"]
RANK = {s: i for i, s in enumerate(SEV)}
CYCLE = {"A": "cycle A (claims first)", "B": "cycle B (oracles first)"}

# Hand matching by the main session, from titles and locations. The workflow's own
# reconciliation has not run yet.
SAME = [
    ["A1-01", "B1-04"], ["A1-02", "A3-07", "B3-05"], ["A1-03", "B1-10"], ["A1-04", "B1-08"],
    ["A1-05", "B1-07"], ["A1-06", "B1-09"], ["A1-10", "B1-05"], ["A2-01", "B1-03"],
    ["A2-02", "B2-02"], ["A2-05", "A3-10", "A7-02", "B7-03"], ["A2-06", "B2-04"],
    ["A3-01", "B3-01"], ["A3-04", "B3-06"], ["A3-09", "B3-07"], ["A4-01", "B4-01"],
    ["A4-02", "B4-04"], ["A4-04", "B4-03"], ["A4-05", "A6-01"], ["A4-06", "B4-06"],
    ["A4-07", "B4-09"], ["A4-08", "A6-07", "A7-01"], ["A5-01", "B5-01"], ["A5-02", "B5-02"],
    ["A6-02", "B6-02"], ["A6-03", "B6-01"], ["A6-04", "B6-06"], ["A6-05", "B6-03"],
    ["A7-03", "B7-02"], ["A7-04", "B7-01"], ["A7-07", "B7-05", "B7-07"],
]
RELATED = [
    (["A2-03", "B2-01"], "both in the simplex refinement pass, on badly scaled data with scaling: .none"),
    (["A3-03", "B3-04"], "same stall and mu gates, IPMWorker.swift:720-741"),
    (["A3-05", "A3-06", "B3-02"], "same convergence test of InteriorPoint(crossover: .none), IPMWorker.swift:687-706"),
    (["A4-03", "B4-02"], "both prune the optimum through the objective-step cutoff"),
    (["B4-02", "A4-01", "B4-01"], "B4-02's inflated incumbent comes from the same unchecked LP-integral path"),
    (["A4-04", "B4-05"], "B4-05 is the test that cannot catch this bound defect"),
    (["A5-01", "B5-05"], "same 4-ulp snap, at the 2^53 edge"),
    (["A5-05", "B4-07"], "same doc comment, SolutionAnalysis.bound (Analysis.swift:22)"),
    (["A3-08", "B7-04"], "interior-point tests that cannot fail"),
]

VERB = {"confirmed": "confirmed it", "refuted": "refuted it", "uncertain": "could not decide",
        "plausible": "ruled it plausible"}

# ----------------------------------------------------------------------------- text helpers

SCRATCH = re.compile(r"/(?:private/)?tmp/claude-\d+/[^\s'\"`)\]]*")
SPECIAL = {"\\": "\\\\", "*": "\\*", "_": "\\_", "~": "\\~", "$": "\\$", "[": "\\[", "<": "&lt;"}


def san(s):
    s = "" if s is None else str(s)
    s = s.replace(ROOT + "/", "").replace(ROOT, ".")
    s = SCRATCH.sub("<scratch>", s)
    return s.replace("/Users/admin/", "~/")


def esc_plain(t):
    return "".join(SPECIAL.get(ch, ch) for ch in t)


def prose(s, table=False):
    s = san(s).replace("\r", "").replace("\n", " ").strip()
    if s.count("`") % 2:
        out = esc_plain(s).replace("`", "\\`")
    else:
        parts = re.split(r"(`[^`]+`)", s)
        out = "".join(p if (len(p) > 1 and p[0] == "`" and p[-1] == "`") else esc_plain(p) for p in parts)
    return out.replace("|", "\\|") if table else out


def prose_block(s):
    """Multi-line text: keeps its line and paragraph structure (lists stay lists)."""
    out, para = [], []
    for line in san(s).replace("\r", "").split("\n"):
        if line.strip():
            para.append(prose(line))
        elif para:
            out.append("\n".join(para))
            para = []
    if para:
        out.append("\n".join(para))
    return "\n\n".join(out)


def fence(body, lang="text"):
    body = san(body).rstrip("\n")
    f = "```"
    while f in body:
        f += "`"
    return f + lang + "\n" + body + "\n" + f


def anchor(fid):
    return fid.lower()


def link(fid):
    return "[" + fid + "](#" + anchor(fid) + ")"


# ----------------------------------------------------------------------------- data

def load_finders():
    out = {}
    for c in "AB":
        for k, slug, _ in AREAS:
            with open(f"{VER}/cycle-{c}/F{k}-{slug}.json") as fh:
                out[(c, k)] = json.load(fh)
    return out


def load_verdicts():
    """(finding id, lens) -> verdict object, from every workflow journal of the session."""
    journals = sorted(glob.glob(SESSION + "/subagents/workflows/*/journal.jsonl"), key=os.path.getmtime)
    out = {}
    for path in journals:
        labels, results = {}, {}
        with open(path) as fh:
            for line in fh:
                e = json.loads(line)
                if e.get("type") == "started":
                    labels[e["key"]] = e.get("label", "")
                elif e.get("type") == "result":
                    results[e["key"]] = e.get("result")
        for key, label in labels.items():
            m = re.match(r"(verify|tiebreak)\s+(\S+)(?:\s+\((\w+)\))?", label)
            r = results.get(key)
            if m and isinstance(r, dict) and r.get("verdict"):
                out[(m.group(2), m.group(3) or "tiebreak")] = r
    return out


def lenses_for(sev):
    return ["reproduce", "contract"] if sev in ("critical", "high") else ["combined"]


def status(fid, sev, V):
    """(short label, sentence) for a finding."""
    if sev == "info":
        return "n/a", "Not verified: info items are recorded only."
    tb = V.get((fid, "tiebreak"))
    if tb:
        return tb["verdict"] + " (tiebreak)", "The tiebreaker " + VERB.get(tb["verdict"], tb["verdict"]) + "."
    lenses = lenses_for(sev)
    done = [V[(fid, l)] for l in lenses if (fid, l) in V]
    if len(lenses) == 2:
        if len(done) == 2:
            a, b = done[0]["verdict"], done[1]["verdict"]
            if a == b == "confirmed":
                return "confirmed 2/2", "Both skeptics confirmed it."
            if a == b == "refuted":
                return "refuted 2/2", "Both skeptics refuted it."
            return "split", f"The skeptics split ({a}, {b}); a tiebreak is pending."
        if len(done) == 1:
            v = done[0]["verdict"]
            return v + " 1/2", "One skeptic " + VERB.get(v, v) + "; the second check is pending."
        return "pending", "Not yet checked by a skeptic."
    if done:
        v = done[0]
        if v["verdict"] == "confirmed" and v.get("severity") in ("critical", "high"):
            return ("confirmed 1/1, escalated",
                    f"The skeptic confirmed it and rated it {v['severity']}; by the policy a second "
                    "skeptic and a tiebreak are pending.")
        return v["verdict"] + " 1/1", "The skeptic " + VERB.get(v["verdict"], v["verdict"]) + "."
    return "pending", "Not yet checked by a skeptic."


VRANK = ["confirmed 2/2", "confirmed 1/1, escalated", "confirmed 1/1", "confirmed 1/2",
         "split", "uncertain 1/2", "uncertain 1/1", "pending", "refuted 1/2", "refuted 1/1",
         "refuted 2/2", "n/a"]


def vrank(label):
    return VRANK.index(label) if label in VRANK else len(VRANK)


# ----------------------------------------------------------------------------- build

def main():
    F = load_finders()
    V = load_verdicts()

    findings = {}   # id -> (cycle, k, finding)
    for (c, k), res in F.items():
        for f in res["findings"]:
            findings[f["id"]] = (c, k, f)
    for g in SAME + [ids for ids, _ in RELATED]:
        for i in g:
            if i not in findings:
                sys.exit(f"unknown finding id in matching tables: {i}")

    same_of = {i: g for g in SAME for i in g}
    related_of = {}
    for ids, why in RELATED:
        for i in ids:
            related_of.setdefault(i, []).append(([j for j in ids if j != i], why))

    st = {fid: status(fid, f["severity"], V) for fid, (_, _, f) in findings.items()}

    # Distinct issues.
    seen, issues = set(), []
    for fid in sorted(findings):
        if fid in seen:
            continue
        members = sorted(same_of.get(fid, [fid]))
        seen.update(members)
        sev = min((findings[m][2]["severity"] for m in members), key=lambda s: RANK[s])
        rep = min(members, key=lambda m: (RANK[findings[m][2]["severity"]], m))
        best = min((st[m][0] for m in members), key=vrank)
        issues.append({"members": members, "sev": sev, "rep": rep, "best": best,
                       "cycles": {m[0] for m in members}})
    issues.sort(key=lambda i: (RANK[i["sev"]], vrank(i["best"]), i["members"][0]))

    n_total = len(findings)
    n_a = sum(1 for c, _, _ in findings.values() if c == "A")
    planned = sum(len(lenses_for(f["severity"])) for _, _, f in findings.values() if f["severity"] != "info")
    checks = {k: v for k, v in V.items() if k[1] != "tiebreak"}
    n_conf = sum(1 for v in checks.values() if v["verdict"] == "confirmed")
    n_ref = sum(1 for v in checks.values() if v["verdict"] == "refuted")
    n_unc = len(checks) - n_conf - n_ref
    by_sev = {s: sum(1 for i in issues if i["sev"] == s) for s in SEV}
    n_both = sum(1 for i in issues if len(i["cycles"]) == 2)
    interim = len(checks) < planned

    L = []
    w = L.append
    w("# ZTronLPOptimizer: verification findings" + (" (interim)" if interim else ""))
    w("")
    w(f"Snapshot of {SNAPSHOT} against `main` @ `{COMMIT}`. Verification only: nothing in the "
      "package was changed to produce these results.")
    w("")
    if interim:
        w(f"> **Status: interim.** All 14 finders have finished. {len(checks)} of the {planned} "
          f"planned skeptic checks are done ({n_conf} confirmed, {n_ref} refuted"
          + (f", {n_unc} undecided" if n_unc else "") + "), and the cross-cycle reconciliation has "
          "not run yet. A finding marked *pending* is its finder's claim, backed by the finder's own "
          "reproduction, but no skeptic has checked it yet.")
        w("")

    w("## Contents")
    w("")
    w("- [Summary](#summary)")
    w("- [How the findings were produced](#how-the-findings-were-produced)")
    w("- [All issues, most severe first](#all-issues-most-severe-first)")
    w("- [Findings by area](#findings-by-area)")
    for k, slug, title in AREAS:
        w(f"  - [F{k} {title}](#f{k}-{slug})")
    w("- [Reproducing a finding](#reproducing-a-finding)")
    w("")

    w("## Summary")
    w("")
    w(f"The two cycles reported {n_total} findings: {n_a} in cycle A and {n_total - n_a} in cycle B. "
      f"Counting findings that describe the same defect once leaves {len(issues)} distinct issues, "
      f"and {n_both} of them were found independently by both cycles. By the highest rating a finder "
      f"gave them, {by_sev['critical']} are critical, {by_sev['high']} high, {by_sev['medium']} medium, "
      f"{by_sev['low']} low and {by_sev['info']} info.")
    w("")
    w(SUMMARY_THEMES)
    w("")
    w("Findings by the finder's severity and by verification status:")
    w("")
    w("| Severity | Findings | Confirmed | Refuted | Pending | Not verified (info) |")
    w("|---|---:|---:|---:|---:|---:|")
    for s in SEV:
        ids = [fid for fid, (_, _, f) in findings.items() if f["severity"] == s]
        conf = sum(1 for i in ids if st[i][0].startswith("confirmed"))
        ref = sum(1 for i in ids if st[i][0].startswith("refuted"))
        na = sum(1 for i in ids if st[i][0] == "n/a")
        w(f"| {s} | {len(ids)} | {conf} | {ref} | {len(ids) - conf - ref - na} | {na} |")
    w("")
    w("A finding counts as confirmed here once at least one skeptic has confirmed it; the "
      "\"Verification\" line of each finding says how many have.")
    w("")

    w("## How the findings were produced")
    w("")
    w(METHOD)
    w("")
    w("### Severity scale")
    w("")
    w(SEVERITY)
    w("")
    w("### Verification labels")
    w("")
    w(LABELS)
    w("")
    w("### Baseline: the package's own gates")
    w("")
    w(BASELINE)
    w("")

    w("## All issues, most severe first")
    w("")
    w("One row per distinct issue. Severity is the highest rating any finder gave; the findings "
      "column gives each finding's verification status.")
    w("")
    w("| Severity | Issue | Findings |")
    w("|---|---|---|")
    for i in issues:
        _, _, rep = findings[i["rep"]]
        cells = "<br>".join(link(m) + " " + st[m][0] for m in i["members"])
        w(f"| {i['sev']} | {prose(rep['title'], table=True)} | {cells} |")
    w("")

    w("## Findings by area")
    w("")
    for k, slug, title in AREAS:
        w(f"### <a id=\"f{k}-{slug}\"></a>F{k} {prose(title)}")
        w("")
        w("<details><summary>Finder summaries, what they did not check, and further notes</summary>")
        w("")
        for c in "AB":
            res = F[(c, k)]
            w(f"**{CYCLE[c][0].upper() + CYCLE[c][1:]}.** {prose(res.get('summary', ''))}")
            w("")
            held = res.get("claimsHeld") or []
            w(f"Claims and properties that held: {len(held)}.")
            w("")
            nc = res.get("notChecked") or []
            if nc:
                w("Not checked:")
                w("")
                for x in nc:
                    w("- " + prose(x))
                w("")
            ov = res.get("overflow") or []
            if ov:
                w("Further notes (not verified):")
                w("")
                for x in ov:
                    w("- " + prose(x))
                w("")
        w("</details>")
        w("")
        area = [(fid, c, f) for fid, (c, kk, f) in findings.items() if kk == k]
        area.sort(key=lambda t: (RANK[t[2]["severity"]], t[0]))
        for fid, c, f in area:
            emit_finding(w, fid, c, f, st, V, same_of, related_of, findings)

    w("## Reproducing a finding")
    w("")
    w(REPRO)
    w("")

    text = "\n".join(L) + "\n"
    with open(OUT, "w") as fh:
        fh.write(text)
    print(f"wrote {OUT}: {len(text)} bytes, {n_total} findings, {len(issues)} issues, "
          f"{len(checks)}/{planned} checks")


def emit_finding(w, fid, c, f, st, V, same_of, related_of, findings):
    sev = f["severity"]
    w(f'#### <a id="{anchor(fid)}"></a>{fid} · {prose(f["title"])}')
    w("")
    skeptic_sevs = sorted({v["severity"] for (i, _), v in V.items() if i == fid and v.get("severity")} - {sev},
                          key=lambda s: RANK[s])
    sev_text = f"{sev} (finder)" + ("; skeptic: " + ", ".join(skeptic_sevs) if skeptic_sevs else "")
    w(f"- **Severity:** {sev_text} · **Category:** {prose(f.get('category', ''))} · "
      f"**Confidence:** {prose(f.get('confidence', ''))} · **Found by:** {CYCLE[c]}")
    w(f"- **Verification:** {st[fid][1]}")
    same = [m for m in same_of.get(fid, []) if m != fid]
    if same:
        w("- **Same defect:** " + ", ".join(link(m) + " (" + CYCLE[findings[m][0]].split(" (")[0] + ")" for m in same))
    for others, why in related_of.get(fid, []):
        others = [m for m in others if m not in same]
        if others:
            w("- **Related:** " + ", ".join(link(m) for m in others) + ": " + prose(why))
    w(f"- **Location:** {prose(f.get('location', ''))}")
    w(f"- **Claim tested:** {prose(f.get('claim', ''))}")
    w(f"- **Observed:** {prose(f.get('observed', ''))}")
    w(f"- **Why it is wrong:** {prose(f.get('whyWrong', ''))}")
    w(f"- **Documented:** {prose(f.get('documented', '')) or 'not stated'}")
    w("")
    repro = (f.get("repro") or "").strip()
    if repro:
        w("**Reproduction**")
        w("")
        w(fence(repro, "sh"))
        w("")
    else:
        w("**Reproduction:** none recorded (found by code reading).")
        w("")
    ev = (f.get("evidence") or "").strip()
    if ev:
        w("<details><summary>Probe output</summary>")
        w("")
        w(fence(ev))
        w("")
        w("</details>")
        w("")
    for lens in ["reproduce", "contract", "combined", "tiebreak"]:
        v = V.get((fid, lens))
        if not v:
            continue
        doc = "yes" if v.get("documented") else "no"
        w(f"<details><summary>Skeptic, {lens} lens: {v['verdict']}, rated {v.get('severity', '?')}, "
          f"documented: {doc}</summary>")
        w("")
        w(prose_block(v.get("reasoning", "")))
        w("")
        if v.get("reproCommand"):
            w("Command:")
            w("")
            w(fence(v["reproCommand"], "sh"))
            w("")
        w(f"The skeptic's full notes, commands and output: `verification/cycle-{c}/verdicts/{fid}-{lens}.md`.")
        w("")
        w("</details>")
        w("")


# ----------------------------------------------------------------------------- fixed text

SUMMARY_THEMES = """Where the defects are:

- **Wrong answers under a success status.** These are the critical findings: `.optimal` at an infeasible or non-optimal point, or a false `.infeasible`.
  - Branch and bound. An LP-integral node solution is rounded and accepted without re-checking its rows ([A4-01](#a4-01), [B4-01](#b4-01)). Heuristic incumbents pass a feasibility test that is relative to the row bound ([A4-02](#a4-02), [B4-04](#b4-04)). The objective-step cutoff prunes the optimum ([A4-03](#a4-03), [B4-02](#b4-02)).
  - CP-SAT. Data of magnitude 2^49 and above is rounded by a 4-ulp snap ([A5-01](#a5-01), [B5-01](#b5-01)). Coefficients that should be rejected are rounded instead ([A5-02](#a5-02), [B5-02](#b5-02)).
  - Simplex. Crossed bounds are solved to `.optimal` ([A2-01](#a2-01), [B1-03](#b1-03)). Phase 1 declares feasible LPs infeasible, with a ray that proves nothing ([A2-02](#a2-02), [B2-02](#b2-02)). The refinement pass can return the all-slack starting basis as optimal ([B2-01](#b2-01)).
  - Interior point. It reports `.optimal` on an infeasible LP, overriding the crossover's own verdict ([A3-01](#a3-01), [B3-01](#b3-01)). It answers `.infeasible` on feasible LPs at condition numbers of 1e8 to 1e10 ([A3-02](#a3-02)). With `crossover: .none` it can report answers far from the optimum ([B3-02](#b3-02)).
  - Core. Presolve rounds integer bounds outward once they reach about 1e9 ([B1-01](#b1-01)). The default geometric scaling can lead to `.optimal` at a non-optimal vertex, with no warning ([B1-02](#b1-02)).
- **Bounds and gaps that are not proofs.** A search that completes after pruning by the gap, or that stops while the root is being expanded, reports bound = incumbent and gap 0 ([A4-04](#a4-04), [B4-03](#b4-03), [A4-05](#a4-05), [A6-01](#a6-01)).
- **Limits not honoured.** CP-SAT root propagation ignores the time limit, cancellation and the memory budget ([B5-04](#b5-04)). `Conditioned` runs its analysis after a cancelled solve ([A6-03](#a6-03), [B6-01](#b6-01)). Interior-point cancellation latency grows with problem size ([A6-02](#a6-02), [B6-02](#b6-02)).
- **Tests that cannot fail** for the bug they are named for, and test runs that count skipped cases as passed. Examples: [A7-01](#a7-01), [A3-08](#a3-08), [A5-03](#a5-03), [B4-05](#b4-05), [B6-05](#b6-05), [B7-01](#b7-01).
- **Documentation and published numbers** that disagree with what was measured: the README §5 tables, the defect descriptions in README §4, and several doc comments.

Most failures need edge inputs: badly scaled or very large data, values at a tolerance boundary, crossed bounds, or a limit that lands at a particular moment. On well-posed inputs, the large oracle sweeps found nothing:

- Simplex: about 75,000 solves on KKT-constructed LPs in cycle A, and 129,600 solves over 432 configurations on planted LPs in cycle B.
- Netlib: every optimum within a relative 1.33e-11, in every configuration.
- Branch and bound: 9,240 runs checked against exhaustive enumeration, and all 10 MIPLIB 3 instances solved to their published optima.
- CP-SAT: every SATLIB uf50-218 and uuf50-218 instance answered correctly, and thousands of models checked against enumeration."""

METHOD = """- **Two independent cycles** covered the same seven areas, and neither saw the other's work.
  - Cycle A worked claims first. It listed what the README, HANDBOOK, doc comments and tests claim, and tried to falsify each claim by running a check.
  - Cycle B worked oracles first. It derived the contract from first principles (KKT conditions, Farkas certificates, enumeration, round trips), built its own oracles, and attacked the public API with adversarial inputs.
- **One finder per area and cycle** wrote probe programs against the public API. For each discrepancy it recorded the reproduction command, the observed output, why it is wrong, the likely culprit as file:line, and whether the behaviour is documented. Findings come from three sources: the mathematical contract, a claim the package makes about itself, or an internal invariant. A test that cannot fail for the bug it targets also counts.
- **Skeptics try to refute each finding.**
  - Critical and high findings get two skeptics, one with a *reproduce* lens and one with a *contract* lens, and a tiebreak if they disagree.
  - Medium and low findings get one skeptic, with a *combined* lens. The finding is escalated if that skeptic rates it high or critical.
  - Info items are recorded, not verified. At most 10 findings per finder are verified.
- **The finders and skeptics are AI agents (Claude Code).** Each result rests on executed probes unless its confidence says "code-reading-only".
- **"Same defect" and "Related" links** were made by hand from titles and locations. The workflow's own cross-cycle reconciliation has not run yet."""

SEVERITY = """- **critical:** a wrong answer reported with a success status (`.optimal` or `.feasible` with a wrong value or an infeasible point, a false `.infeasible` or `.unbounded`), memory unsafety, or a data race.
- **high:** a crash, trap or hang on valid input; a limit or cancellation not honoured; a published claim that is materially false.
- **medium:** a wrong status or an invalid certificate on edge cases; misleading API behaviour; a test that cannot catch the bug it is named for; a malformed file that traps instead of throwing.
- **low:** a minor documentation or number mismatch; a small inconsistency.
- **info:** an observation worth recording, not verified further."""

LABELS = """- **confirmed 2/2:** both skeptics (reproduce and contract lenses) confirmed the finding.
- **confirmed 1/2:** one of the two skeptics confirmed it; the other check is pending.
- **confirmed 1/1:** the single skeptic (combined lens) confirmed it.
- **confirmed 1/1, escalated:** the skeptic confirmed it and rated it high or critical, so by the policy a second skeptic and a tiebreak are due.
- **refuted:** the skeptic found that the finding does not hold as stated.
- **pending:** no skeptic has checked it yet. The finding rests on its finder's own reproduction.
- **n/a:** an info item, not verified by design."""

BASELINE = """All of these passed on a quiet machine before any agent ran. The machine was an Apple M3 (8 cores, 24 GiB) running macOS 27.0 with Apple Swift 6.4 (swiftlang-6.4.0.34.1).

- `swift build --build-tests -Xswiftc -warnings-as-errors`: passed (31 s).
- `Scripts/lint.sh`: passed.
- `swift test` (debug): passed (250 s).
- `swift test -c release --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests'`: passed (246 s). Its summary line reads "17 tests in 5 suites passed … with 1 known issue".
- Thread Sanitizer, `ZTRONLP_LATENCY_SCALE=20 swift test --sanitize=thread --filter 'ZTronLPIntegrationTests|ZTronLPLivenessTests|ZTronLPBranchAndBoundTests|ZTronLPCPSATTests'`: passed (838 s), with no ThreadSanitizer warnings.

Two integrity findings qualify these passes: debug and Thread Sanitizer runs count skipped MIPLIB cases as passed ([A7-04](#a7-04), [B7-01](#b7-01))."""

REPRO = """Most reproduction commands run probe programs from two SwiftPM workspaces, `verification/probes/cycle-A` and `verification/probes/cycle-B`. These workspaces are not part of the package.

- Each one depends on the package by path and has one executable target ("slot") per agent: `F1`–`F7` for the finders and `V001`–`V240` for the skeptics.
- A slot's code is in `Slots/<slot>/main.swift`.
- The workspaces are available only if `verification/probes/` is pushed along with this file.

To run a command:

1. In the workspace's `Package.swift`, point `.package(path: ...)` at your checkout of the package.
2. Run the command as written. It starts with `cd verification/probes/cycle-X`.

`swift build --product <slot>` builds one slot; add `-c release` when the command runs `.build/release/<slot>`. `perl -e 'alarm shift; exec @ARGV' <s> <binary>` limits a run to s seconds, and exit status 142 means that limit was reached. Commands of the form `swift test --filter …` run the package's own tests.

Timings were measured on a machine shared with other agents' runs, so treat absolute times as rough."""


if __name__ == "__main__":
    main()
