#!/usr/bin/env bash
#
# Checks the two images build-options-test builds from src/tests/multi-arch.yaml
# and the lock file the lock command wrote for it, in CircleCI's test-deploy
# and the GitHub Actions workflow alike. Run from the checkout:
#
#   verify_build_options.sh cached TARBALL LOCKFILE
#       The build with vcs and sbom at their defaults, which filled the cache:
#       the image index records the checkout's commit, the SBOMs are
#       in the working directory (and are removed), and the image holds the
#       locked package versions.
#   verify_build_options.sh offline TARBALL LOCKFILE SBOM_DIR
#       The offline build from that cache: the annotations it was given, a
#       creation time of 2099-01-02T03:04:05Z (build_date, later than any
#       package), no VCS annotations, SBOMs in SBOM_DIR only, and the locked
#       package versions.

set -euo pipefail

STAGE=$1
TARBALL=$2
LOCKFILE=$3
SBOM_DIR=${4:-.}

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

# Prints "index KEY=VALUE" for the image index's annotations, then "image
# KEY=VALUE" for each architecture's image. apko's tarball holds the index as
# index.json and each image manifest under its digest.
annotations() {
    local digest
    tar -xOf "${TARBALL}" index.json | jq -r '(.annotations // {}) | to_entries[] | "index \(.key)=\(.value)"'
    for digest in $(tar -xOf "${TARBALL}" index.json | jq -r '.manifests[].digest'); do
        tar -xOf "${TARBALL}" "${digest}" | jq -r '(.annotations // {}) | to_entries[] | "image \(.key)=\(.value)"'
    done
}
ANNOTATIONS=$(annotations)
IMAGES=$(tar -xOf "${TARBALL}" index.json | jq '.manifests | length')
echo "Annotations of the index and its ${IMAGES} image(s):"
while IFS= read -r line; do
    echo "  ${line}"
done <<< "${ANNOTATIONS}"

# expect_everywhere KEY=VALUE: the index and every image carry it.
expect_everywhere() {
    local count
    count=$(grep -cxF -e "index $1" -e "image $1" <<< "${ANNOTATIONS}" || true)
    if [[ "${count}" != "$((IMAGES + 1))" ]]; then
        fail "expected $1 on the index and all ${IMAGES} image(s), found it ${count} time(s)"
    fi
}
# expect_index KEY=VALUE: the index carries it. (apko records the VCS
# annotations on the index only.)
expect_index() {
    if ! grep -qxF "index $1" <<< "${ANNOTATIONS}"; then
        fail "expected $1 on the index"
    fi
}
# expect_nowhere KEY: neither the index nor any image carries it.
expect_nowhere() {
    if grep -qE "^(index|image) $1=" <<< "${ANNOTATIONS}"; then
        fail "expected no $1 annotation"
    fi
}

# Every locked package is in the image at its locked version, as the SBOM of
# the amd64 image lists it.
check_locked_versions() {
    local sbom=$1 name version installed count
    count=$(jq '[.contents.packages[] | select(.architecture == "x86_64")] | length' "${LOCKFILE}")
    if [[ "${count}" == 0 ]]; then
        fail "${LOCKFILE} locks no x86_64 packages"
    fi
    while read -r name version; do
        installed=$(jq -r --arg name "${name}" '[.packages[] | select(.name == $name) | .versionInfo][0] // ""' "${sbom}")
        if [[ "${installed}" != "${version}" ]]; then
            fail "${name} is locked at ${version}, but the image has '${installed}'"
        fi
    done < <(jq -r '.contents.packages[] | select(.architecture == "x86_64") | "\(.name) \(.version)"' "${LOCKFILE}")
    echo "Checked ${count} locked package(s) against ${sbom}."
}

case "${STAGE}" in
    cached)
        expect_index "org.opencontainers.image.revision=$(git rev-parse HEAD)"
        for sbom in sbom-index.spdx.json sbom-x86_64.spdx.json; do
            [[ -s "${sbom}" ]] || fail "expected ${sbom} in the working directory"
        done
        if [[ -s sbom-x86_64.spdx.json ]]; then
            check_locked_versions sbom-x86_64.spdx.json
        fi
        rm -f sbom-*.spdx.json
        ;;
    offline)
        expect_everywhere "org.example.description=Built by apko-orb, for its \"offline\" test"
        expect_everywhere "org.example.team=platform"
        expect_everywhere "org.opencontainers.image.created=2099-01-02T03:04:05Z"
        expect_nowhere "org.opencontainers.image.revision"
        expect_nowhere "org.opencontainers.image.source"
        for sbom in sbom-index.spdx.json sbom-x86_64.spdx.json; do
            [[ -s "${SBOM_DIR}/${sbom}" ]] || fail "expected ${sbom} in ${SBOM_DIR}"
        done
        if compgen -G 'sbom-*.spdx.json' > /dev/null; then
            fail "expected no SBOMs in the working directory with sbom_path set"
        fi
        if [[ -s "${SBOM_DIR}/sbom-x86_64.spdx.json" ]]; then
            check_locked_versions "${SBOM_DIR}/sbom-x86_64.spdx.json"
        fi
        ;;
    *)
        echo "usage: $0 cached|offline TARBALL LOCKFILE [SBOM_DIR]" >&2
        exit 2
        ;;
esac

if [[ "${FAILURES}" -gt 0 ]]; then
    exit 1
fi
echo "PASS: the ${STAGE} build is as expected."
