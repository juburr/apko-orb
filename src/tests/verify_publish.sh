#!/usr/bin/env bash
#
# Checks what publish-test pushed to a local registry that requires a login,
# in CircleCI's test-deploy and the GitHub Actions workflow alike: the login
# command stored the credentials, the image index publish exported is the one
# every tag points to, it lists both architectures, the image_refs file names
# each pushed image by digest with the index last, and the SBOMs were kept.
#
#   verify_publish.sh REPOSITORY REFS_FILE SBOM_DIR TAG...
#
# REPOSITORY is HOST:PORT/NAME. Reads APKO_DIGEST and APKO_DIGEST_REF, which
# publish exported, and REGISTRY_USERNAME and REGISTRY_PASSWORD.

set -euo pipefail

REPOSITORY=$1
REFS_FILE=$2
SBOM_DIR=$3
shift 3
HOST=${REPOSITORY%%/*}
NAME=${REPOSITORY#*/}
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json"

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

# registry_digest REFERENCE: prints the digest the registry serves for a tag
# or digest of the repository, read with the credentials.
registry_digest() {
    curl -fsS -I -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" -H "Accept: ${ACCEPT}" \
        "http://${HOST}/v2/${NAME}/manifests/$1" | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }'
}

echo "Exported: APKO_DIGEST=${APKO_DIGEST:-}, APKO_DIGEST_REF=${APKO_DIGEST_REF:-}"
[[ "${APKO_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "APKO_DIGEST is not a sha256 digest"
[[ "${APKO_DIGEST_REF:-}" == "${REPOSITORY}@${APKO_DIGEST:-}" ]] || fail "APKO_DIGEST_REF is not ${REPOSITORY}@APKO_DIGEST"

jq -e --arg host "${HOST}" '.auths[$host]' ~/.docker/config.json > /dev/null || fail "no credentials for ${HOST} in ~/.docker/config.json"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}/v2/${NAME}/tags/list")
[[ "${STATUS}" == 401 ]] || fail "the registry answered ${STATUS} without credentials, not 401"

for tag in "$@"; do
    digest=$(registry_digest "${tag}")
    echo "${REPOSITORY}:${tag} -> ${digest}"
    [[ "${digest}" == "${APKO_DIGEST:-}" ]] || fail "${tag} points to ${digest}, not ${APKO_DIGEST:-}"
done

PLATFORMS=$(curl -fsS -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" -H "Accept: ${ACCEPT}" \
    "http://${HOST}/v2/${NAME}/manifests/${APKO_DIGEST}" | jq -r '[.manifests[].platform.architecture] | sort | join(",")')
echo "Index platforms: ${PLATFORMS}"
[[ "${PLATFORMS}" == "amd64,arm64" ]] || fail "expected an index of amd64 and arm64 images"

echo "image_refs:"
sed 's/^/  /' "${REFS_FILE}"
[[ "$(grep -c . "${REFS_FILE}")" == 3 ]] || fail "expected two images and the index in ${REFS_FILE}"
[[ "$(tail -n 1 "${REFS_FILE}")" == "${APKO_DIGEST_REF:-}" ]] || fail "the last reference in ${REFS_FILE} is not the index"
while read -r ref; do
    [[ "${ref}" == "${REPOSITORY}@sha256:"* ]] || fail "${ref} is not an image of ${REPOSITORY} by digest"
    [[ "$(registry_digest "${ref#*@}")" == "${ref#*@}" ]] || fail "the registry does not serve ${ref}"
done < "${REFS_FILE}"

for sbom in sbom-index.spdx.json sbom-x86_64.spdx.json sbom-aarch64.spdx.json; do
    [[ -s "${SBOM_DIR}/${sbom}" ]] || fail "expected ${sbom} in ${SBOM_DIR}"
done

if [[ "${FAILURES}" -gt 0 ]]; then
    exit 1
fi
echo "PASS: publish pushed the image under every tag and exported its digest."
