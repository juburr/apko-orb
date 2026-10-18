#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
ARCH=$(printf '%s' "${PARAM_ARCH}" | circleci env subst)
CONFIG=$(printf '%s' "${PARAM_CONFIG}" | circleci env subst)
IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
LOG_LEVEL=$(printf '%s' "${PARAM_LOG_LEVEL}" | circleci env subst)
OUTPUT_PATH=$(printf '%s' "${PARAM_OUTPUT_PATH}" | circleci env subst)

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

# Validate configuration YAML file path
if [[ ! -f "${CONFIG}" ]]; then
    echo "Configuration YAML does not exist at: ${CONFIG}"
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
