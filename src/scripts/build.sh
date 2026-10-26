#!/bin/bash

set -euo pipefail

# subst VALUE: expands environment variables in VALUE with the CircleCI CLI,
# which reads it on stdin. Without the CLI, as in GitHub Actions or a local
# run, the value is used as it is.
subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# Ensure CircleCI environment variables can be passed in as orb parameters
ARCH=$(subst "${PARAM_ARCH}")
CONFIG=$(subst "${PARAM_CONFIG}")
IMAGE=$(subst "${PARAM_IMAGE}")
LOG_LEVEL=$(subst "${PARAM_LOG_LEVEL}")
OUTPUT_PATH=$(subst "${PARAM_OUTPUT_PATH}")

# Computed parameters
OUTPUT_DIR=$(dirname "${OUTPUT_PATH}")

# Print command parameters for debugging purposes.
echo "Running Apko build with the following parameters:"
echo "  ARCH: ${ARCH:-(from configuration file)}"
echo "  CONFIG: ${CONFIG}"
echo "  IMAGE: ${IMAGE}"
echo "  LOG_LEVEL: ${LOG_LEVEL}"
echo "  OUTPUT_DIR: ${OUTPUT_DIR}"
echo "  OUTPUT_PATH: ${OUTPUT_PATH}"
echo ""

# CircleCI checks the command's log_level enum before the step runs; the
# GitHub Action passes any string.
case "${LOG_LEVEL}" in
    debug | info | warn | error | fatal | panic) ;;
    *)
        echo "ERROR: log_level must be debug, info, warn, error, fatal or panic, not '${LOG_LEVEL}'." >&2
        exit 1
        ;;
esac

# Validate configuration YAML file path
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: Configuration YAML does not exist at: ${CONFIG}" >&2
    exit 1
fi

# Create output directory if it does not yet exist
if [[ -d "${OUTPUT_DIR}" ]]; then
    echo "Output directory already exists: ${OUTPUT_DIR}"
else
    echo "Creating directory ${OUTPUT_DIR}..."
    mkdir -p "${OUTPUT_DIR}"
    echo "  Done."
fi

# Build image
BUILD_ARGS=(--log-level "${LOG_LEVEL}")
if [[ -n "${ARCH}" ]]; then
    BUILD_ARGS+=(--arch "${ARCH}")
fi

echo "Building container image with apko..."
apko build "${BUILD_ARGS[@]}" "${CONFIG}" "${IMAGE}" "${OUTPUT_PATH}"
