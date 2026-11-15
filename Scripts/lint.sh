#!/bin/bash
# Lint greps of the specification's concurrency rules (§12.1). CI runs this; it exits non-zero
# on the first rule that is broken.
#
#   C2  no global mutable variables in library code
#   C2  `nonisolated(unsafe)` is banned
#   C3  every `@unchecked Sendable` is listed and must carry an `// INVARIANT:` comment
#   C6  no DispatchSemaphore, Thread.sleep, blocking command-buffer wait or DispatchGroup wait
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
STATUS=0

fail() {
    echo "lint: $1" >&2
    STATUS=1
}

# Swift sources of the library and executable targets; comment-only lines are not code.
code() {
    grep -rn --include='*.swift' -E "$1" Sources | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*//' || true
}

# --- C2: nonisolated(unsafe) ------------------------------------------------------------------
HITS="$(grep -rn --include='*.swift' -F 'nonisolated(unsafe)' Sources Tests || true)"
if [ -n "${HITS}" ]; then
    fail "nonisolated(unsafe) is banned (rule C2):"
    echo "${HITS}" >&2
fi

# --- C2: global mutable variables --------------------------------------------------------------
# A `var` declared at column 0 is a global; a stored `static var` is one too. Computed
# properties (a `{` before any `=`) are fine.
HITS="$(code '^(public |package |internal |fileprivate |private )?var [A-Za-z_]')"
if [ -n "${HITS}" ]; then
    fail "global mutable variables are not allowed (rule C2):"
    echo "${HITS}" >&2
fi
HITS="$(code 'static var [A-Za-z_][A-Za-z0-9_]*(:[^={]*)?[[:space:]]*=[^=]')"
if [ -n "${HITS}" ]; then
    fail "stored static variables are global mutable state (rule C2):"
    echo "${HITS}" >&2
fi

# --- C3: @unchecked Sendable -------------------------------------------------------------------
echo "@unchecked Sendable occurrences (rule C3):"
COUNT=0
while IFS= read -r HIT; do
    [ -z "${HIT}" ] && continue
    FILE="${HIT%%:*}"
    REST="${HIT#*:}"
    LINE="${REST%%:*}"
    COUNT=$((COUNT + 1))
    echo "  ${FILE}:${LINE}"
    START=$((LINE > 8 ? LINE - 8 : 1))
    if ! sed -n "${START},${LINE}p" "${FILE}" | grep -q '// INVARIANT:'; then
        fail "${FILE}:${LINE}: @unchecked Sendable without an // INVARIANT: comment directly above it (rule C3)"
    fi
done <<EOF
$(code '@unchecked[[:space:]]+Sendable')
EOF
echo "  ${COUNT} in total"

# --- C6: blocking primitives -------------------------------------------------------------------
for PATTERN in 'DispatchSemaphore' 'Thread\.sleep' 'waitUntilCompleted' 'DispatchGroup' 'usleep\(' '[^A-Za-z_.]sleep\('; do
    HITS="$(grep -rn --include='*.swift' --include='*.metal' -E "${PATTERN}" Sources || true)"
    if [ -n "${HITS}" ]; then
        fail "blocking primitive matching /${PATTERN}/ (rule C6):"
        echo "${HITS}" >&2
    fi
done

if [ "${STATUS}" -eq 0 ]; then
    echo "lint: all rules hold"
fi
exit "${STATUS}"
