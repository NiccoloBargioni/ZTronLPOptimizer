#!/bin/bash
# Fetches the SATLIB instances the CP-SAT tests use (specification §14.2):
#
#   uf50-218   1,000 satisfiable   uniform random 3-SAT instances, 50 variables, 218 clauses
#   uuf50-218  1,000 unsatisfiable uniform random 3-SAT instances, 50 variables, 218 clauses
#
# They are not bundled with the package. This script downloads the two archives from the
# SATLIB benchmark page, verifies their pinned SHA-256 checksums and extracts the .cnf files,
# flat, into
#
#   <package root>/.corpora/satlib/uf50-218/
#   <package root>/.corpora/satlib/uuf50-218/
#
# which is where ZTronLPTestSupport's `Corpora.satlib(_:)` looks (or under $ZTRONLP_CORPORA
# when that is set). The tests that need the corpus are skipped while it is absent.
#
# Usage: Scripts/fetch-satlib.sh [--force]
#   --force   download and extract again even if the instances are already there

set -euo pipefail

BASE_URL="https://www.cs.ubc.ca/~hoos/SATLIB/Benchmarks/SAT/RND3SAT"

# family : sha256 of <family>.tar.gz : number of .cnf files it contains
FAMILIES=(
  "uf50-218:a40862e52dfdce78620b037254579a02dbda8182d2879433658a4c15cb00327c:1000"
  "uuf50-218:24cc9f492673e0f975fecc56b3a4d8ac21c385cc46205d83b7491a787f43e13d:1000"
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPORA="${ZTRONLP_CORPORA:-$ROOT/.corpora}"
DEST="$CORPORA/satlib"
FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; fi

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for entry in "${FAMILIES[@]}"; do
  family="${entry%%:*}"
  rest="${entry#*:}"
  expected="${rest%%:*}"
  count="${rest##*:}"
  target="$DEST/$family"

  if [[ $FORCE -eq 0 && -d "$target" ]]; then
    present=$(find "$target" -maxdepth 1 -name '*.cnf' | wc -l | tr -d ' ')
    if [[ "$present" == "$count" ]]; then
      echo "$family: $present instances already in $target"
      continue
    fi
  fi

  archive="$WORK/$family.tar.gz"
  echo "$family: downloading $BASE_URL/$family.tar.gz"
  curl --fail --silent --show-error --location --max-time 300 -o "$archive" "$BASE_URL/$family.tar.gz"

  actual="$(sha256 "$archive")"
  if [[ "$actual" != "$expected" ]]; then
    echo "$family: checksum mismatch" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi

  # The two archives are laid out differently (one is flat, the other has a top-level
  # directory), so extract into a scratch directory and move the .cnf files out of it.
  unpacked="$WORK/$family"
  mkdir -p "$unpacked"
  tar -xzf "$archive" -C "$unpacked"
  rm -rf "$target"
  mkdir -p "$target"
  find "$unpacked" -type f -name '*.cnf' -exec mv {} "$target/" \;

  present=$(find "$target" -maxdepth 1 -name '*.cnf' | wc -l | tr -d ' ')
  if [[ "$present" != "$count" ]]; then
    echo "$family: expected $count instances, found $present" >&2
    exit 1
  fi
  echo "$family: $present instances in $target (sha256 verified)"
done
