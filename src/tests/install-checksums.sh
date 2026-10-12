#!/bin/bash

# Verifies the checksum policy of scripts/install.sh without network access.
# A fake "cached" apko.tar.gz is seeded for a version that is not in the
# SHA-512 lookup table, then the installer is run under each verify_checksums
# mode. The orb's default mode is read from commands/install.yml so this test
# tracks the published default rather than a hardcoded value.

set -eu

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALL_SCRIPT="${REPO_ROOT}/src/scripts/install.sh"
UNLISTED_VERSION="0.0.0"

DEFAULT_MODE=$(yq '.parameters.verify_checksums.default' "${REPO_ROOT}/src/commands/install.yml")
echo "Default verify_checksums mode: ${DEFAULT_MODE}"

# Runs the installer in a fresh directory containing a fake cached tarball.
# Arguments: <verify_checksums mode> <expected outcome: pass|fail>
run_install() {
    local mode=$1
    local expected=$2
    local work
    work=$(mktemp -d)

    mkdir -p "${work}/bin" "${work}/src"
    for arch in amd64 arm64; do
        mkdir -p "${work}/src/apko_${UNLISTED_VERSION}_linux_${arch}"
        printf '#!/bin/sh\necho unverified\n' > "${work}/src/apko_${UNLISTED_VERSION}_linux_${arch}/apko"
    done
    tar -czf "${work}/apko.tar.gz" -C "${work}/src" \
        "apko_${UNLISTED_VERSION}_linux_amd64" "apko_${UNLISTED_VERSION}_linux_arm64"

    echo ""
    echo "=== verify_checksums=${mode} (expecting ${expected})"
    local status=0
    (
        cd "${work}"
        PARAM_INSTALL_PATH="${work}/bin" \
        PARAM_VERIFY_CHECKSUMS="${mode}" \
        PARAM_VERSION="${UNLISTED_VERSION}" \
        bash "${INSTALL_SCRIPT}"
    ) > "${work}/output.log" 2>&1 || status=$?
    cat "${work}/output.log"

    if [[ "${expected}" == "fail" ]]; then
        if [[ ${status} -eq 0 ]]; then
            echo "FAIL: installer succeeded for unlisted version under '${mode}'"
            exit 1
        fi
        if ! grep -q "No checksum available for version ${UNLISTED_VERSION}" "${work}/output.log"; then
            echo "FAIL: installer failed for an unexpected reason under '${mode}'"
            exit 1
        fi
        if [[ -e "${work}/bin/apko" ]]; then
            echo "FAIL: unverified binary was installed under '${mode}'"
            exit 1
        fi
    else
        if [[ ${status} -ne 0 ]]; then
            echo "FAIL: installer exited ${status} under '${mode}'"
            exit 1
        fi
        if [[ ! -x "${work}/bin/apko" ]]; then
            echo "FAIL: binary was not installed under '${mode}'"
            exit 1
        fi
    fi
    echo "PASS: verify_checksums=${mode}"
    rm -rf "${work}"
}

run_install "${DEFAULT_MODE}" fail
run_install strict fail
run_install known_versions pass
run_install false pass
