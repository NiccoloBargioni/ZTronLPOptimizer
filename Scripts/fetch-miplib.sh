#!/bin/bash
# Fetches the ten MIPLIB 3 instances of the specification's §14.2 table into
# .corpora/miplib3/ at the package root. They are not bundled with the package (§14.1).
#
# Source: the COIN-OR mirror of MIPLIB 3, https://github.com/coin-or-tools/Data-miplib3,
# pinned to one commit so the URLs are immutable; every download is checked against a pinned
# SHA-256 before it is unpacked. Re-running the script skips files that are already in place.
#
# Usage: Scripts/fetch-miplib.sh [destination-directory]
set -euo pipefail

COMMIT="36c786b3274f75d9a0062471589813b92d3da91b"
BASE="https://raw.githubusercontent.com/coin-or-tools/Data-miplib3/${COMMIT}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-${ROOT}/.corpora/miplib3}"

# name  sha256-of-the-.gz
INSTANCES="
p0033   815a50e5129884f15817deb9642fec1be4784d6ed58c71f72dd545a27b96e072
stein27 fea07a38e2eed889ef4c6a8d6fee2ae2c63b09c1c9b9fe1d066498b1aaecb941
stein45 ae20a108ca34d80e85f7f754c95a53581c2b38471564784cfd571481b10065a2
enigma  2cd57ad9c0b32b6b13a91c6c61211a00cbf47568bb8f0da01f969c1442c503dc
lseu    a65806a868cdb9bb472aaec7fbcc1a50b7d30b7103c123c771a34bcce8179ee4
mod008  71e4592509bcdfccdb57df170cf6ce04fb40eec0262a8fa3fa7b3afe5474ca43
flugpl  69e6bd80fbf91ba6c7156d88280c4a9680434ff357fa3101225712cf485834df
egout   dc0502c0699d287c6f57f2769897b3aa603645b6d6266bd0a60e38a87f49bd96
misc03  c5506404d8e1036dcad892baa7e0a5aae56ebc952449352cd5038db3a9c11587
p0201   375733347f3fe1e4e67480da43b72c6a4992c26e0c576d83136dcff8382208ee
"

mkdir -p "${DEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "${INSTANCES}" | while read -r NAME SUM; do
    [ -z "${NAME}" ] && continue
    if [ -s "${DEST}/${NAME}.mps" ]; then
        echo "${NAME}: already present"
        continue
    fi
    curl --fail --silent --show-error --location --max-time 120 -o "${TMP}/${NAME}.gz" "${BASE}/${NAME}.gz"
    ACTUAL="$(shasum -a 256 "${TMP}/${NAME}.gz" | cut -d' ' -f1)"
    if [ "${ACTUAL}" != "${SUM}" ]; then
        echo "${NAME}: checksum mismatch (expected ${SUM}, got ${ACTUAL})" >&2
        exit 1
    fi
    gunzip -c "${TMP}/${NAME}.gz" > "${DEST}/${NAME}.mps"
    echo "${NAME}: fetched and verified"
done
echo "MIPLIB 3 instances are in ${DEST}"
