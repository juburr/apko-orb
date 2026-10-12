#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# tables in install.sh.

set -e
set +o history

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${WORK_DIR}"

# Upstream's checksums.txt lists the SHA-256 of each release tarball. It is
# used as a consistency check on the download before the binary is hashed.
BASE_URL="https://github.com/chainguard-dev/apko/releases/download/v${VERSION}"
wget "${BASE_URL}/checksums.txt" -O checksums.txt -q

# Download each supported architecture and print the SHA-512 checksum of
# the apko binary inside, formatted for the matching table in install.sh.
# Output is suppressed for readability; this is a dev script, so simply
# re-enable output if you need to debug anything.
for ARCH in amd64 arm64; do
    RELEASE_NAME="apko_${VERSION}_linux_${ARCH}"
    wget "${BASE_URL}/${RELEASE_NAME}.tar.gz" -O "${RELEASE_NAME}.tar.gz" -q
    if ! grep -q " ${RELEASE_NAME}.tar.gz$" checksums.txt; then
        echo "No upstream checksum for ${RELEASE_NAME}.tar.gz" >&2
        exit 1
    fi
    grep " ${RELEASE_NAME}.tar.gz$" checksums.txt | sha256sum --check --quiet
    tar zxvf "${RELEASE_NAME}.tar.gz" "${RELEASE_NAME}/apko" > /dev/null 2>&1
    CHECKSUM=$(sha512sum "${RELEASE_NAME}/apko" | awk '{ print $1 }')
    echo "# sha512sums_${ARCH}"
    echo "[\"${VERSION}\"]=\"${CHECKSUM}\""
done
