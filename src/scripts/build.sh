#!/bin/bash
#
# Builds an image with apko build, for the build command, and writes it to
# output_path: an OCI image tarball, or an OCI image layout when output_path
# is an existing directory. Nothing is pushed. With SBOMs on, apko writes one
# per architecture and one for the index, to sbom_path or the working
# directory.

set -euo pipefail

if [[ -z "${SCRIPT_APKO_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_APKO_LIB is not set. The command passes the orb's lib/apko.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_APKO_LIB}"

CONFIG=$(apko_subst "${PARAM_CONFIG}")
IMAGE=$(apko_subst "${PARAM_IMAGE}")
OUTPUT_PATH=$(apko_subst "${PARAM_OUTPUT_PATH}")
ARCH=$(apko_subst "${PARAM_ARCH}")
LOG_LEVEL=$(apko_subst "${PARAM_LOG_LEVEL}")
EXTRA_ARGS=$(apko_subst "${PARAM_EXTRA_ARGS}")

apko_log_level "${LOG_LEVEL}"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: Configuration YAML does not exist at: ${CONFIG}" >&2
    exit 1
fi
if [[ -z "${IMAGE}" ]]; then
    echo "ERROR: image must not be empty. apko records it in the output, such as ghcr.io/myorg/myapp:1.0.0." >&2
    exit 1
fi
if [[ -z "${OUTPUT_PATH}" ]]; then
    echo "ERROR: output_path must not be empty, such as build/image.tar." >&2
    exit 1
fi
apko_arch_args "${ARCH}"
apko_words extra_args "${EXTRA_ARGS}"
apko_require
apko_image_options

# apko writes a tarball into an existing directory, but creates none.
OUTPUT_DIR=$(dirname -- "${OUTPUT_PATH}")
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    echo "Creating ${OUTPUT_DIR} for the image."
    mkdir -p -- "${OUTPUT_DIR}"
fi

ARGS=(build "--log-level=${LOG_LEVEL}")
# These arrays can be empty, and bash before 4.4 treats an empty array as
# unset under set -u, so they are expanded only when they have elements.
ARGS+=(${APKO_ARCH_ARGS[@]+"${APKO_ARCH_ARGS[@]}"})
ARGS+=(${APKO_IMAGE_OPTIONS[@]+"${APKO_IMAGE_OPTIONS[@]}"})
ARGS+=(${APKO_WORDS[@]+"${APKO_WORDS[@]}"})
# After --, a value that starts with "-" is not read as a flag.
ARGS+=(-- "${CONFIG}" "${IMAGE}" "${OUTPUT_PATH}")

apko_run apko "${ARGS[@]}"
echo "Wrote the image to ${OUTPUT_PATH}."
