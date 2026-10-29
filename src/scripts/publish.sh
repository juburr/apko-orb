#!/bin/bash
#
# Builds an image with apko publish and pushes it to a registry under every
# reference in tags, for the publish command, then exports the image index's
# digest and its reference by digest for later steps. apko pushes each
# architecture's image to the repository of the first tag, by digest, then
# the index under each tag. It reads registry credentials where docker and
# crane store them (the login command, docker login) and, for ghcr.io, from
# GITHUB_TOKEN.

set -euo pipefail

if [[ -z "${SCRIPT_APKO_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_APKO_LIB is not set. The command passes the orb's lib/apko.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_APKO_LIB}"

CONFIG=$(apko_subst "${PARAM_CONFIG}")
TAGS=$(apko_subst "${PARAM_TAGS}")
ARCH=$(apko_subst "${PARAM_ARCH}")
LOG_LEVEL=$(apko_subst "${PARAM_LOG_LEVEL}")
IMAGE_REFS=$(apko_subst "${PARAM_IMAGE_REFS}")
EXTRA_ARGS=$(apko_subst "${PARAM_EXTRA_ARGS}")
apko_env_var_name digest_env_var "${PARAM_DIGEST_ENV_VAR}"
apko_env_var_name digest_ref_env_var "${PARAM_DIGEST_REF_ENV_VAR}"

apko_log_level "${LOG_LEVEL}"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: The apko configuration ${CONFIG} does not exist." >&2
    exit 1
fi
apko_list "${TAGS}"
TAG_LIST=(${APKO_LIST[@]+"${APKO_LIST[@]}"})
if [[ ${#TAG_LIST[@]} -eq 0 ]]; then
    echo "ERROR: tags must name at least one image reference to push, such as ghcr.io/myorg/myapp:1.0.0." >&2
    exit 1
fi
for TAG in "${TAG_LIST[@]}"; do
    if [[ "${TAG}" == -* ]]; then
        echo "ERROR: tags must hold image references, such as ghcr.io/myorg/myapp:1.0.0, not '${TAG}'." >&2
        exit 1
    fi
done
apko_arch_args "${ARCH}"
apko_words extra_args "${EXTRA_ARGS}"
# The command reads the pushed references from the file --image-refs names,
# and --local would push nothing.
apko_refuse extra_args --image-refs --local
apko_require
apko_image_options

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
REFS_FILE="${WORK}/image-refs"

ARGS=(publish "--log-level=${LOG_LEVEL}")
# These arrays can be empty, and bash before 4.4 treats an empty array as
# unset under set -u, so they are expanded only when they have elements.
ARGS+=(${APKO_ARCH_ARGS[@]+"${APKO_ARCH_ARGS[@]}"})
ARGS+=(${APKO_IMAGE_OPTIONS[@]+"${APKO_IMAGE_OPTIONS[@]}"})
ARGS+=("--image-refs=${REFS_FILE}")
ARGS+=(${APKO_WORDS[@]+"${APKO_WORDS[@]}"})
# After --, a value that starts with "-" is not read as a flag.
ARGS+=(-- "${CONFIG}" "${TAG_LIST[@]}")

apko_run apko "${ARGS[@]}"

# apko writes each architecture's image by digest, then the index last.
if [[ ! -s "${REFS_FILE}" ]]; then
    echo "ERROR: apko publish wrote no image references, so the pushed digest is unknown." >&2
    exit 1
fi
DIGEST_REF=$(awk 'NF { last = $0 } END { print last }' "${REFS_FILE}")
DIGEST=${DIGEST_REF##*@}
if [[ "${DIGEST_REF}" != *@* ]] || ! apko_match "${DIGEST}" '^sha256:[0-9a-f]{64}$'; then
    echo "ERROR: apko publish wrote '${DIGEST_REF}' as the index, not a reference by sha256 digest." >&2
    exit 1
fi

echo "Pushed references:"
sed 's/^/  /' "${REFS_FILE}"
if [[ -n "${IMAGE_REFS}" ]]; then
    mkdir -p -- "$(dirname -- "${IMAGE_REFS}")"
    cp -- "${REFS_FILE}" "${IMAGE_REFS}"
    echo "Wrote them to ${IMAGE_REFS}."
fi
echo "  Index digest: ${DIGEST}"
echo "  Index reference: ${DIGEST_REF}"
apko_export "${PARAM_DIGEST_ENV_VAR}" "${DIGEST}"
apko_export "${PARAM_DIGEST_REF_ENV_VAR}" "${DIGEST_REF}"
echo "Exported ${PARAM_DIGEST_ENV_VAR} and ${PARAM_DIGEST_REF_ENV_VAR} for later steps."
