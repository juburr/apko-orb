#!/bin/bash
#
# Resolves the packages an apko configuration installs with apko lock, for
# the lock command, and writes them, with their versions and checksums, the
# repositories and the keys, to a lock file. build and publish take it as
# lockfile, so later builds install exactly those packages.

set -euo pipefail

if [[ -z "${SCRIPT_APKO_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_APKO_LIB is not set. The command passes the orb's lib/apko.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_APKO_LIB}"

CONFIG=$(apko_subst "${PARAM_CONFIG}")
OUTPUT=$(apko_subst "${PARAM_OUTPUT}")
ARCH=$(apko_subst "${PARAM_ARCH}")
LOG_LEVEL=$(apko_subst "${PARAM_LOG_LEVEL}")
KEYRING_APPEND=$(apko_subst "${PARAM_KEYRING_APPEND}")
REPOSITORY_APPEND=$(apko_subst "${PARAM_REPOSITORY_APPEND}")
CACHE_DIR=$(apko_subst "${PARAM_CACHE_DIR}")
EXTRA_ARGS=$(apko_subst "${PARAM_EXTRA_ARGS}")

apko_log_level "${LOG_LEVEL}"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: Configuration YAML does not exist at: ${CONFIG}" >&2
    exit 1
fi
# apko's own default: the configuration's path with .lock.json in place of
# its extension, so apko.yaml gets apko.lock.json. The command passes it
# either way, so it knows which file to report.
if [[ -z "${OUTPUT}" ]]; then
    CONFIG_NAME=${CONFIG##*/}
    if [[ "${CONFIG_NAME}" == *.* ]]; then
        OUTPUT="${CONFIG%.*}.lock.json"
    else
        OUTPUT="${CONFIG}.lock.json"
    fi
fi
if [[ -d "${OUTPUT}" ]]; then
    echo "ERROR: output ${OUTPUT} is a directory; it must name the lock file to write." >&2
    exit 1
fi
apko_arch_args "${ARCH}"
apko_words extra_args "${EXTRA_ARGS}"
# The command reports the file it passes as --output.
apko_refuse extra_args --output
apko_require

OUTPUT_DIR=$(dirname -- "${OUTPUT}")
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    echo "Creating ${OUTPUT_DIR} for the lock file."
    mkdir -p -- "${OUTPUT_DIR}"
fi

ARGS=(lock "--log-level=${LOG_LEVEL}" "--output=${OUTPUT}")
# These arrays can be empty, and bash before 4.4 treats an empty array as
# unset under set -u, so they are expanded only when they have elements.
ARGS+=(${APKO_ARCH_ARGS[@]+"${APKO_ARCH_ARGS[@]}"})
apko_flags --keyring-append "${KEYRING_APPEND}"
ARGS+=(${APKO_FLAGS[@]+"${APKO_FLAGS[@]}"})
apko_flags --repository-append "${REPOSITORY_APPEND}"
ARGS+=(${APKO_FLAGS[@]+"${APKO_FLAGS[@]}"})
if [[ -n "${CACHE_DIR}" ]]; then
    ARGS+=("--cache-dir=${CACHE_DIR}")
fi
ARGS+=(${APKO_WORDS[@]+"${APKO_WORDS[@]}"})
# After --, a value that starts with "-" is not read as a flag.
ARGS+=(-- "${CONFIG}")

apko_run apko "${ARGS[@]}"

if [[ ! -s "${OUTPUT}" ]]; then
    echo "ERROR: apko lock wrote no lock file at ${OUTPUT}." >&2
    exit 1
fi
echo "Wrote the lock file ${OUTPUT}. Pass it to build or publish as lockfile."
