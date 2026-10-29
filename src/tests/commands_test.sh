#!/usr/bin/env bash
#
# Tests src/scripts/build.sh, publish.sh, lock.sh and login.sh against a
# stand-in apko that records its arguments, working directory and stdin, and
# writes the files publish and lock would:
#
#   - each command builds exactly the apko arguments expected from its
#     defaults and from every parameter, with no empty argument where an
#     optional list is empty, even on bash < 4.4, and ends its options with
#     -- so a value that starts with "-" is never read as a flag
#   - a parameter left at its default adds no flag
#   - lists split on commas, spaces and newlines without globbing; annotations
#     take one key:value per line, and a value with a comma or a quote is
#     quoted for apko's comma-separated flags
#   - extra_args split like shell words, a $(...) or backtick outside quotes
#     stops the step before apko runs, and options the command sets itself
#     are refused
#   - publish exports the index's digest and its reference by digest from the
#     references apko writes, keeps them in image_refs when asked, and fails
#     when apko reports no index digest
#   - lock writes beside the configuration by default, and fails when apko
#     wrote no lock file
#   - login hands apko the password on stdin, never on the command line or in
#     the log, even with xtrace on
#   - bad values stop the step before apko runs, and a failing apko fails the
#     step
#   - parameters reach the CircleCI CLI on stdin, and without the CLI, as on
#     GitHub's runners, are used as they are
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
CLI="${WORK}/cli"
mkdir -p "${STUBS}" "${CLI}"
LOG="${WORK}/apko.log"
STDIN_LOG="${WORK}/apko.stdin"

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
DIGEST_I="sha256:$(printf 'c%.0s' {1..64})"

# The apko stand-in. Each call logs "--- <cwd>" and then its arguments, one
# per line, and saves its stdin. publish writes APKO_REFS (by default an
# image per architecture and the index, by digest) to the --image-refs file;
# lock writes a lock file to --output unless APKO_LOCK_EMPTY is set.
# APKO_EXIT sets its exit status.
cat > "${STUBS}/apko" << 'EOF'
#!/bin/bash
{ printf -- '--- %s\n' "$(pwd)"; printf '%s\n' "$@"; } >> "${STUB_LOG}"
if [[ "${1:-}" == login ]]; then
    cat > "${STUB_STDIN}"
fi
for arg in "$@"; do
    case "${arg}" in
        --image-refs=*)
            printf '%s' "${APKO_REFS-${DEFAULT_REFS}}" > "${arg#--image-refs=}"
            ;;
        --output=*)
            if [[ -z "${APKO_LOCK_EMPTY:-}" ]]; then
                echo '{"version":"v1"}' > "${arg#--output=}"
            fi
            ;;
    esac
done
exit "${APKO_EXIT:-0}"
EOF
# The CircleCI CLI stand-in: env subst reads its value on stdin, fails on any
# other argument, and expands $ORB_TEST_VAR.
cat > "${CLI}/circleci" << 'EOF'
#!/bin/bash
if [[ $# -ne 2 || "$1" != env || "$2" != subst ]]; then
    echo "circleci stand-in: unexpected arguments: $*" >&2
    exit 2
fi
value=$(cat; printf x)
value=${value%x}
value=${value//'${ORB_TEST_VAR}'/${ORB_TEST_VAR:-}}
value=${value//'$ORB_TEST_VAR'/${ORB_TEST_VAR:-}}
printf '%s' "${value}"
EOF
chmod +x "${STUBS}/apko" "${CLI}/circleci"

# The system PATH without a real circleci (cimg images keep git beside it,
# so such a directory is replaced by links to everything else in it).
BASE_PATH=""
SHADOWS=0
IFS=: read -r -a path_dirs <<< "${PATH}"
for dir in "${path_dirs[@]}"; do
    [[ -n "${dir}" ]] || continue
    if [[ -x "${dir}/circleci" ]]; then
        SHADOWS=$((SHADOWS + 1))
        shadow="${WORK}/path-${SHADOWS}"
        mkdir -p "${shadow}"
        for entry in "${dir}"/*; do
            if [[ -e "${entry}" && "${entry##*/}" != circleci ]]; then
                ln -s "${entry}" "${shadow}/${entry##*/}"
            fi
        done
        dir=${shadow}
    fi
    BASE_PATH="${BASE_PATH:+${BASE_PATH}:}${dir}"
done

# Each command's parameters, at the defaults its YAML gives them (booleans as
# CircleCI passes them). run reads them by name.
IMAGE_OPTION_DEFAULTS=(PARAM_ARCH= PARAM_LOCKFILE= PARAM_BUILD_DATE= PARAM_VCS=1 PARAM_SBOM=1 PARAM_SBOM_PATH=
    PARAM_KEYRING_APPEND= PARAM_REPOSITORY_APPEND= PARAM_PACKAGE_APPEND= PARAM_ANNOTATIONS= PARAM_CACHE_DIR=
    PARAM_OFFLINE=0 PARAM_EXTRA_ARGS=)
# shellcheck disable=SC2034
BUILD_DEFAULTS=(PARAM_CONFIG=apko.yaml PARAM_IMAGE=registry.example.com/app:1.0 PARAM_OUTPUT_PATH=build/image.tar
    PARAM_LOG_LEVEL=debug "${IMAGE_OPTION_DEFAULTS[@]}")
# shellcheck disable=SC2034
PUBLISH_DEFAULTS=(PARAM_CONFIG=apko.yaml PARAM_TAGS=registry.example.com/app:1.0 PARAM_IMAGE_REFS=
    PARAM_DIGEST_ENV_VAR=APKO_DIGEST PARAM_DIGEST_REF_ENV_VAR=APKO_DIGEST_REF PARAM_LOG_LEVEL=info
    "${IMAGE_OPTION_DEFAULTS[@]}")
# shellcheck disable=SC2034
LOCK_DEFAULTS=(PARAM_CONFIG=apko.yaml PARAM_OUTPUT= PARAM_ARCH= PARAM_KEYRING_APPEND= PARAM_REPOSITORY_APPEND=
    PARAM_CACHE_DIR= PARAM_LOG_LEVEL=info PARAM_EXTRA_ARGS=)
# shellcheck disable=SC2034
LOGIN_DEFAULTS=(PARAM_REGISTRY=registry.example.com PARAM_USERNAME=REGISTRY_USERNAME PARAM_PASSWORD=REGISTRY_PASSWORD)

DEFAULT_REFS="registry.example.com/app@${DIGEST_A}
registry.example.com/app@${DIGEST_B}
registry.example.com/app@${DIGEST_I}
"

CASE=0
WITH_CLI=true
PREPARE=""
# run SCRIPT DEFAULTS_ARRAY [VAR=value ...]: runs src/scripts/SCRIPT in a new
# job directory (JOB) holding apko.yaml, with the command's defaults
# overridden by the given assignments, and the circleci stand-in on the PATH
# unless WITH_CLI is false. PREPARE names a function run in JOB first. Sets
# RC, OUTPUT, JOB, CALLS (the apko calls' arguments, without the cwd lines)
# and EXPORTS (what the script wrote to BASH_ENV). (Bash 4.0 takes an empty
# "$@" for an unbound variable, so the assignments are copied only when
# there are some.)
run() {
    local script=$1 defaults_name=$2
    shift 2
    local -a vars=()
    if [[ $# -gt 0 ]]; then
        vars=("$@")
    fi
    local -a defaults
    eval "defaults=(\"\${${defaults_name}[@]}\")"
    local path="${STUBS}:${BASE_PATH}"
    if [[ "${WITH_CLI}" == true ]]; then
        path="${CLI}:${path}"
    fi
    CASE=$((CASE + 1))
    JOB="${WORK}/job ${CASE}"
    mkdir -p "${JOB}" "${WORK}/tmp-${CASE}"
    printf 'contents:\n  packages:\n    - busybox\n' > "${JOB}/apko.yaml"
    : > "${LOG}"
    : > "${STDIN_LOG}"
    : > "${WORK}/bash_env-${CASE}"
    if [[ -n "${PREPARE}" ]]; then
        (cd "${JOB}" && "${PREPARE}")
    fi
    OUTPUT=$(cd "${JOB}" && env -i PATH="${path}" HOME="${WORK}" TMPDIR="${WORK}/tmp-${CASE}" \
        BASH_ENV="${WORK}/bash_env-${CASE}" STUB_LOG="${LOG}" STUB_STDIN="${STDIN_LOG}" \
        DEFAULT_REFS="${DEFAULT_REFS}" SCRIPT_APKO_LIB="$(cat "${SCRIPTS}/lib/apko.sh")" \
        "${defaults[@]}" ${vars[@]+"${vars[@]}"} \
        bash "${SCRIPTS}/${script}" 2>&1)
    RC=$?
    CALLS=$(grep -v '^--- ' "${LOG}" | paste -sd' ' -)
    EXPORTS=$(cat "${WORK}/bash_env-${CASE}")
}

PASSES=0
FAILURES=0
check() {
    local name=$1
    shift
    if "$@"; then
        PASSES=$((PASSES + 1))
        printf 'ok: %s\n' "${name}"
    else
        FAILURES=$((FAILURES + 1))
        printf 'FAIL: %s\n' "${name}"
        printf '%s\n' "${OUTPUT}" | sed 's/^/    | /'
        printf 'calls: %s\n' "${CALLS}" | sed 's/^/    | /'
    fi
}
rc_is() { [[ "${RC}" == "$1" ]]; }
rc_not() { [[ "${RC}" != "$1" ]]; }
equals() { [[ "$1" == "$2" ]]; }
output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }
output_lacks() { [[ "${OUTPUT}" != *"$1"* ]]; }
calls_are() { [[ "${CALLS}" == "$1" ]]; }
calls_have() { [[ " ${CALLS} " == *" $1 "* ]]; }
calls_lack() { [[ " ${CALLS} " != *"$1"* ]]; }
not_run() { [[ ! -s "${LOG}" ]]; }
exports_has() { grep -qxF -- "$1" <<< "${EXPORTS}"; }
exports_empty() { [[ -z "${EXPORTS}" ]]; }
tmp_empty() { [[ -z "$(ls -A "${WORK}/tmp-${CASE}")" ]]; }
in_job() { [[ -e "${JOB}/$1" ]]; }
not_in_job() { [[ ! -e "${JOB}/$1" ]]; }

# --- build ------------------------------------------------------------------

run build.sh BUILD_DEFAULTS
check "build runs with the defaults" rc_is 0
check "build's default arguments" calls_are "build --log-level=debug -- apko.yaml registry.example.com/app:1.0 build/image.tar"
check "build runs in the job's working directory" grep -qxF -- "--- ${JOB}" "${LOG}"
check "build creates the output's directory" test -d "${JOB}/build"
check "build shows the apko command it runs" output_has "Running: apko build --log-level=debug -- apko.yaml"

options_prepare() {
    echo '{"version":"v1"}' > apko.lock.json
    echo key > extra.rsa.pub
}
PREPARE=options_prepare
run build.sh BUILD_DEFAULTS "PARAM_ARCH=amd64, arm64" PARAM_LOCKFILE=apko.lock.json \
    PARAM_BUILD_DATE=2025-01-31T12:00:00Z PARAM_VCS=0 PARAM_SBOM_PATH=out/sboms \
    "PARAM_KEYRING_APPEND=extra.rsa.pub, https://example.com/key.rsa.pub
*.pub" "PARAM_REPOSITORY_APPEND=./packages https://example.com/os" PARAM_PACKAGE_APPEND=busybox,curl=8.11.0-r0 \
    "PARAM_ANNOTATIONS=org.opencontainers.image.source:https://github.com/myorg/myapp

org.opencontainers.image.description:A small, quiet \"image\"
org.example.team:platform" \
    PARAM_CACHE_DIR=apk-cache PARAM_OFFLINE=1 "PARAM_EXTRA_ARGS=--include-paths=base 'two words'" PARAM_LOG_LEVEL=warn
PREPARE=""
check "build with every parameter set" rc_is 0
check "build passes every parameter, in order" calls_are "build --log-level=warn --arch=amd64,arm64 --lockfile=apko.lock.json --build-date=2025-01-31T12:00:00Z --vcs=false --sbom-path=out/sboms --keyring-append=extra.rsa.pub --keyring-append=https://example.com/key.rsa.pub --keyring-append=*.pub --repository-append=./packages --repository-append=https://example.com/os --package-append=busybox --package-append=curl=8.11.0-r0 --annotations=org.opencontainers.image.source:https://github.com/myorg/myapp --annotations=\"org.opencontainers.image.description:A small, quiet \"\"image\"\"\" --annotations=org.example.team:platform --cache-dir=apk-cache --offline --include-paths=base two words -- apko.yaml registry.example.com/app:1.0 build/image.tar"
check "build creates sbom_path" test -d "${JOB}/out/sboms"

run build.sh BUILD_DEFAULTS PARAM_SBOM=0 PARAM_SBOM_PATH=sboms
check "sbom false passes --sbom=false" calls_have "--sbom=false"
check "sbom false leaves sbom_path out" calls_lack "--sbom-path"
check "sbom false creates no sbom_path" not_in_job sboms

WITH_CLI=false
run build.sh BUILD_DEFAULTS PARAM_VCS=true PARAM_SBOM=true PARAM_OFFLINE=false
check "true and false are booleans too" calls_are "build --log-level=debug -- apko.yaml registry.example.com/app:1.0 build/image.tar"
WITH_CLI=true

run build.sh BUILD_DEFAULTS PARAM_LOCKFILE=missing.lock.json
check "a missing lock file fails" output_has "ERROR: The lock file missing.lock.json, which lockfile names, does not exist."
check "a missing lock file fails before apko runs" not_run
run build.sh BUILD_DEFAULTS PARAM_BUILD_DATE=yesterday
check "a malformed build_date fails" output_has "ERROR: build_date must be an RFC 3339 date and time, such as 2025-01-31T12:00:00Z, not 'yesterday'."
check "a malformed build_date fails before apko runs" not_run
run build.sh BUILD_DEFAULTS PARAM_BUILD_DATE=2025-01-31T12:00:00.5+02:00
check "build_date takes fractions and offsets" calls_have "--build-date=2025-01-31T12:00:00.5+02:00"
run build.sh BUILD_DEFAULTS "PARAM_ANNOTATIONS=Org.Example:x"
check "an annotation key with capitals fails" output_has "ERROR: Each line of annotations must be key:value"
check "a malformed annotation fails before apko runs" not_run
run build.sh BUILD_DEFAULTS "PARAM_ANNOTATIONS=org.example.empty:"
check "an annotation without a value fails" output_has "'org.example.empty:' is not."
run build.sh BUILD_DEFAULTS $'PARAM_ANNOTATIONS=org.example.a:1\r\norg.example.b:2\r\n'
check "annotations take CRLF lines" calls_have "--annotations=org.example.a:1 --annotations=org.example.b:2"
run build.sh BUILD_DEFAULTS "PARAM_ARCH=amd64;id"
check "a malformed arch fails" output_has "ERROR: arch must list architectures separated by commas, such as amd64,arm64, or host; 'amd64;id' is not one."
check "a malformed arch fails before apko runs" not_run
run build.sh BUILD_DEFAULTS "PARAM_ARCH=arm/v7
host"
check "arch takes arm/v7 and host" calls_have "--arch=arm/v7,host"
run build.sh BUILD_DEFAULTS PARAM_VCS=yes
check "a bad boolean fails" output_has "ERROR: vcs must be true or false, not 'yes'."
check "a bad boolean fails before apko runs" not_run
run build.sh BUILD_DEFAULTS PARAM_LOG_LEVEL=trace
check "an unknown log_level fails" output_has "ERROR: log_level must be debug, info, warn, error, fatal or panic, not 'trace'."
run build.sh BUILD_DEFAULTS PARAM_CONFIG=missing.yaml
check "a missing configuration fails" output_has "ERROR: Configuration YAML does not exist at: missing.yaml"
check "a missing configuration fails before apko runs" not_run
run build.sh BUILD_DEFAULTS PARAM_IMAGE=
check "an empty image fails" output_has "ERROR: image must not be empty."
run build.sh BUILD_DEFAULTS PARAM_OUTPUT_PATH=
check "an empty output_path fails" output_has "ERROR: output_path must not be empty"

dash_prepare() { cp apko.yaml ./-apko.yaml; }
PREPARE=dash_prepare
run build.sh BUILD_DEFAULTS PARAM_CONFIG=-apko.yaml PARAM_IMAGE=-image PARAM_OUTPUT_PATH=-image.tar
PREPARE=""
check "values that start with - come after --" calls_are "build --log-level=debug -- -apko.yaml -image -image.tar"

# shellcheck disable=SC2016 # a command substitution the script must refuse
run build.sh BUILD_DEFAULTS 'PARAM_EXTRA_ARGS=--include-paths=$(id)'
check "a command substitution in extra_args fails" output_has "ERROR: extra_args could not be split into arguments: it has a \$(...) or backtick outside quotes."
check "a command substitution in extra_args fails before apko runs" not_run

run build.sh BUILD_DEFAULTS APKO_EXIT=3
check "a failing apko fails the step" rc_is 3

# shellcheck disable=SC2016 # expanded by the circleci stand-in
run build.sh BUILD_DEFAULTS 'PARAM_IMAGE=registry.example.com/app:$ORB_TEST_VAR' ORB_TEST_VAR=1.2.3
check "parameters go through circleci env subst" calls_have "registry.example.com/app:1.2.3"
WITH_CLI=false
# shellcheck disable=SC2016 # left as it is without the CLI
run build.sh BUILD_DEFAULTS 'PARAM_IMAGE=registry.example.com/app:$ORB_TEST_VAR' ORB_TEST_VAR=1.2.3
check "without the CLI, values are used as they are" calls_have "registry.example.com/app:\$ORB_TEST_VAR"
WITH_CLI=true

SAVED_STUBS=${STUBS}
STUBS="${WORK}/empty-stubs"
mkdir -p "${STUBS}"
run build.sh BUILD_DEFAULTS PARAM_SBOM_PATH=sboms
STUBS=${SAVED_STUBS}
check "a missing apko fails" output_has "ERROR: apko is not on the PATH. Run the install command in an earlier step."
check "a missing apko creates nothing" not_in_job sboms

# --- publish ----------------------------------------------------------------

run publish.sh PUBLISH_DEFAULTS
check "publish runs with the defaults" rc_is 0
check "publish's default arguments" \
    equals "${CALLS//--image-refs=${WORK}\/tmp-${CASE}\/tmp.*\/image-refs/--image-refs=REFS}" "publish --log-level=info --image-refs=REFS -- apko.yaml registry.example.com/app:1.0"
check "publish exports the index digest" exports_has "export APKO_DIGEST=${DIGEST_I}"
check "publish exports the index reference by digest" exports_has "export APKO_DIGEST_REF=registry.example.com/app@${DIGEST_I}"
check "publish shows the pushed references" output_has "  registry.example.com/app@${DIGEST_A}"
check "publish removes its work directory" tmp_empty

run publish.sh PUBLISH_DEFAULTS "PARAM_TAGS=registry.example.com/app:1.0, registry.example.com/app:latest
mirror.example.com/app:1.0" PARAM_ARCH=amd64,arm64 PARAM_SBOM_PATH=sboms PARAM_LOG_LEVEL=debug \
    "PARAM_ANNOTATIONS=org.example.team:platform" "PARAM_EXTRA_ARGS=--build-repository-append=packages"
check "publish passes every tag after the configuration" \
    calls_have "--build-repository-append=packages -- apko.yaml registry.example.com/app:1.0 registry.example.com/app:latest mirror.example.com/app:1.0"
check "publish passes the image options" calls_have "--log-level=debug --arch=amd64,arm64 --sbom-path=sboms --annotations=org.example.team:platform"
check "publish creates sbom_path" in_job sboms

run publish.sh PUBLISH_DEFAULTS PARAM_IMAGE_REFS=out/refs.txt PARAM_DIGEST_ENV_VAR=IMAGE_DIGEST PARAM_DIGEST_REF_ENV_VAR=IMAGE_REF
check "publish writes image_refs" equals "$(cat "${JOB}/out/refs.txt" 2> /dev/null)" "$(printf '%s' "${DEFAULT_REFS}")"
check "publish exports to the variables named" exports_has "export IMAGE_DIGEST=${DIGEST_I}"
check "publish exports the reference to the variable named" exports_has "export IMAGE_REF=registry.example.com/app@${DIGEST_I}"

run publish.sh PUBLISH_DEFAULTS PARAM_TAGS=
check "publish without tags fails" output_has "ERROR: tags must name at least one image reference to push"
check "publish without tags fails before apko runs" not_run
run publish.sh PUBLISH_DEFAULTS "PARAM_TAGS=registry.example.com/app:1.0 --local"
check "a tag that looks like a flag fails" output_has "ERROR: tags must hold image references, such as ghcr.io/myorg/myapp:1.0.0, not '--local'."
check "a tag that looks like a flag fails before apko runs" not_run
run publish.sh PUBLISH_DEFAULTS "PARAM_DIGEST_ENV_VAR=APKO DIGEST"
check "a bad digest_env_var fails" output_has "ERROR: digest_env_var must name an environment variable, not 'APKO DIGEST'."
check "a bad digest_env_var fails before apko runs" not_run
run publish.sh PUBLISH_DEFAULTS PARAM_EXTRA_ARGS=--local
check "--local in extra_args is refused" output_has "ERROR: extra_args must not hold --local: the command sets it itself."
check "--local in extra_args fails before apko runs" not_run
run publish.sh PUBLISH_DEFAULTS PARAM_EXTRA_ARGS=--image-refs=refs.txt
check "--image-refs in extra_args is refused" output_has "ERROR: extra_args must not hold --image-refs"

run publish.sh PUBLISH_DEFAULTS APKO_REFS=
check "publish fails when apko reports no references" output_has "ERROR: apko publish wrote no image references, so the pushed digest is unknown."
check "publish exports nothing without references" exports_empty
run publish.sh PUBLISH_DEFAULTS "APKO_REFS=registry.example.com/app:1.0"
check "publish fails when the index is not by digest" output_has "ERROR: apko publish wrote 'registry.example.com/app:1.0' as the index, not a reference by sha256 digest."
check "publish exports nothing for a bad index reference" exports_empty
run publish.sh PUBLISH_DEFAULTS APKO_EXIT=1
check "a failing publish fails the step" rc_is 1
check "a failing publish exports nothing" exports_empty

# --- lock -------------------------------------------------------------------

run lock.sh LOCK_DEFAULTS
check "lock runs with the defaults" rc_is 0
check "lock's default arguments" calls_are "lock --log-level=info --output=apko.lock.json -- apko.yaml"
check "lock writes the lock file" in_job apko.lock.json
check "lock names the lock file it wrote" output_has "Wrote the lock file apko.lock.json."

nested_prepare() { mkdir -p images; cp apko.yaml images/app.yaml; cp apko.yaml apkoconf; }
PREPARE=nested_prepare
run lock.sh LOCK_DEFAULTS PARAM_CONFIG=images/app.yaml
check "the default lock file sits beside the configuration" calls_have "--output=images/app.lock.json"
run lock.sh LOCK_DEFAULTS PARAM_CONFIG=apkoconf
PREPARE=""
check "a configuration without an extension gets .lock.json added" calls_have "--output=apkoconf.lock.json"

run lock.sh LOCK_DEFAULTS PARAM_OUTPUT=locks/app.lock.json PARAM_ARCH=amd64,arm64 \
    PARAM_KEYRING_APPEND=melange.rsa.pub "PARAM_REPOSITORY_APPEND=packages https://example.com/os" \
    PARAM_CACHE_DIR=apk-cache "PARAM_EXTRA_ARGS=--include-paths=base"
check "lock passes every parameter, in order" \
    calls_are "lock --log-level=info --output=locks/app.lock.json --arch=amd64,arm64 --keyring-append=melange.rsa.pub --repository-append=packages --repository-append=https://example.com/os --cache-dir=apk-cache --include-paths=base -- apko.yaml"
check "lock creates the lock file's directory" in_job locks/app.lock.json

run lock.sh LOCK_DEFAULTS PARAM_EXTRA_ARGS=--output=other.json
check "--output in extra_args is refused" output_has "ERROR: extra_args must not hold --output: the command sets it itself."
check "--output in extra_args fails before apko runs" not_run
dir_prepare() { mkdir -p locks; }
PREPARE=dir_prepare
run lock.sh LOCK_DEFAULTS PARAM_OUTPUT=locks
PREPARE=""
check "an output that is a directory fails" output_has "ERROR: output locks is a directory; it must name the lock file to write."
run lock.sh LOCK_DEFAULTS APKO_LOCK_EMPTY=1
check "lock fails when apko wrote no lock file" output_has "ERROR: apko lock wrote no lock file at apko.lock.json."
run lock.sh LOCK_DEFAULTS PARAM_CONFIG=missing.yaml
check "lock with a missing configuration fails" output_has "ERROR: Configuration YAML does not exist at: missing.yaml"
run lock.sh LOCK_DEFAULTS APKO_EXIT=2
check "a failing lock fails the step" rc_is 2

# --- login ------------------------------------------------------------------

PASSWORD="-n s3cr3t \$HOME"
run login.sh LOGIN_DEFAULTS REGISTRY_USERNAME=robot "REGISTRY_PASSWORD=${PASSWORD}"
check "login runs" rc_is 0
check "login's arguments" calls_are "login --username=robot --password-stdin -- registry.example.com"
check "the password reaches apko on stdin" equals "$(cat "${STDIN_LOG}")" "${PASSWORD}"
check "the password is not on the command line" calls_lack "s3cr3t"
check "the password is not in the log" output_lacks "s3cr3t"

run login.sh LOGIN_DEFAULTS PARAM_USERNAME=GHCR_USER PARAM_PASSWORD=GHCR_TOKEN GHCR_USER=me GHCR_TOKEN=token \
    PARAM_REGISTRY=localhost:5000
check "login reads the variables named" calls_are "login --username=me --password-stdin -- localhost:5000"
check "login reads the password from the variable named" equals "$(cat "${STDIN_LOG}")" "token"

run login.sh LOGIN_DEFAULTS REGISTRY_USERNAME=robot "REGISTRY_PASSWORD=${PASSWORD}" SHELLOPTS=xtrace
check "login with xtrace on runs" rc_is 0
check "login with xtrace on never prints the password" output_lacks "s3cr3t"

run login.sh LOGIN_DEFAULTS REGISTRY_PASSWORD=token
check "a missing username fails" output_has "ERROR: The REGISTRY_USERNAME environment variable, which username names, is empty or unset."
check "a missing username fails before apko runs" not_run
run login.sh LOGIN_DEFAULTS REGISTRY_USERNAME=robot
check "a missing password fails" output_has "ERROR: The REGISTRY_PASSWORD environment variable, which password names, is empty or unset."
check "a missing password fails before apko runs" not_run
for registry in https://ghcr.io ghcr.io/myorg -ghcr.io; do
    run login.sh LOGIN_DEFAULTS "PARAM_REGISTRY=${registry}" REGISTRY_USERNAME=robot REGISTRY_PASSWORD=token
    check "registry ${registry} fails" output_has "ERROR: registry must be a host with an optional port, such as ghcr.io or localhost:5000, not '${registry}'."
done
run login.sh LOGIN_DEFAULTS PARAM_REGISTRY= REGISTRY_USERNAME=robot REGISTRY_PASSWORD=token
check "an empty registry fails" output_has "ERROR: registry is required"
check "a bad registry fails before apko runs" not_run
run login.sh LOGIN_DEFAULTS "PARAM_PASSWORD=A PASSWORD"
check "a bad password variable name fails" output_has "ERROR: password must name an environment variable, not 'A PASSWORD'."
run login.sh LOGIN_DEFAULTS REGISTRY_USERNAME=robot REGISTRY_PASSWORD=token APKO_EXIT=1
check "a failing login fails the step" rc_is 1

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} of $((PASSES + FAILURES)) checks failed."
    exit 1
fi
echo "All ${PASSES} checks passed."
