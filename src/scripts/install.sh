#!/bin/bash
#
# Installs apko for the install command: the Linux amd64 or arm64 build that
# matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (apko only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing apko needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="apko-orb"
TOOL_NAME="apko"
TOOL_BINARY="apko"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'apko_%s_linux_%s.tar.gz\n' "$1" "$2"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf 'https://github.com/chainguard-dev/apko/releases/download/v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'apko_%s_linux_%s/apko\n' "$1" "$2"
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    "$1" version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty.
orb_extract() {
    local asset=$1 member=$2 dir
    if [[ -z "${member}" ]]; then
        ORB_VERIFIED_FILE=${asset}
        return 0
    fi
    dir="${ORB_WORK_DIR}/extract"
    rm -rf "${dir}"
    mkdir "${dir}"
    if ! tar -xzf "${asset}" -C "${dir}" --no-same-owner -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
        orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
        return 1
    fi
    ORB_VERIFIED_FILE="${dir}/${member}"
    if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            cp "${ORB_CACHE_FILE}" "${asset}"
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            rm -f "${ORB_CACHE_FILE}"
            use_cache=false
            continue
        fi
        orb_die "${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) failed verification and was not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST,
# replacing any existing file in a single rename.
orb_install_file() {
    local dir=${2%/*}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if ! { orb_temp_beside "$2" && cp "$1" "${ORB_TEMP}" && chmod 0755 "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "$2"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# Runs the installed binary once, which catches a build that can't run here:
# one for another architecture (exit code 126), or one that crashes, such as
# with SIGILL on a CPU it doesn't support. tool_version needs no network, so
# any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "${ORB_INSTALL_PATH}/${TOOL_BINARY}" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The installed ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_smoke_test
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["1.4.6/amd64"]="fbde5a5a7062f1294cc4d422c4f977902ea0c5947a7408d2cd6982c45f22d5bdaf65a455314ea240a7aca7e71ca6fc87f28cad3ab387067105726bbcf265f52f"
    ["1.4.6/arm64"]="8d5078949bd2c482bf8ed49a7fe995725a00be9d71e65ecc2ff2b26bb468be3614305e355c10d833a097a896f0d9a67407d3709246df9e050d26f7d55bb19473"
    ["1.4.5/amd64"]="eb7495a9a3179d944d5b3c4030bed24f84e2f247186e7d0dc0522e00dc0ed6890093dd7454d62262f0d3ebb0240d559d7f878e091e026e6cba076731abd35fd0"
    ["1.4.5/arm64"]="1d338e0908d9f1ca9b0497d4af693ef04a56089673d856602a7a9fb05179394d25cf571a8b1ff59b08247c901f7190362ae178c736723eb38bbb35445f11f324"
    ["1.4.4/amd64"]="15e6d4df21b13ad0ee48215fcae6bfa1107322fd9b1b1680df379d5006e46ce6bfec057703d7c71d8b6fb425e0d773ed3bc1f10fe59b3a544f5458923b1fea21"
    ["1.4.4/arm64"]="2d375554ebf10f1534cc60f1f5510a06c3990f8279c06d13e52a23829a9f45fbb324bc76f004e0ae4df120b7add5069f950762990117ee7731c6fa1658c1221b"
    ["1.4.3/amd64"]="13543a8f9677630ad62fb15fa1f1ff45c2a4c031adb21effd0955fee9dd4de0ad83f320ec7758225d1bbee3773c277f27f8378db268e5928ae08e9883a7c434a"
    ["1.4.3/arm64"]="3c9f6dfc57f87311198a59273705d5e8a2e506cb0f567af610c8b82d76b11787096749511a9d661a8ae5d8e73a49541ecbaeaf6f0d5d2a3ab671577ec8abb579"
    ["1.4.2/amd64"]="1e551df4967f00e538b99938aec5654874cf8064f88c41535c5b7cbe31d53850c6673d18d0848f415bcb0bf622725d8d2f8df79f43fb5a9db20ec12fbdbd5b44"
    ["1.4.2/arm64"]="9f0da2a6b36b7d0668c15e8623e32caccf03b3bbdaa1f670374e642e1b8c2460376175bbe7ec89b1a9c7063f87c48f05d0ecdb0a427a93817fb7436ab014e5a6"
    ["1.4.1/amd64"]="1ad9e24ca17203f1f0578c0bda64455d7eed60bf9f1345d5304f9872a7d9ccc82238b691c1a7b3eb6e419782e19ef51c42a16f9be78fe9042425b89049430fd5"
    ["1.4.1/arm64"]="95c10a82a1a301c808a81d9a3e6be4db33a8fc29ae170192322c993ab4c874aef7a3eaf43a75d9b163ef38abe56478adf49ef4b67494b4fb755057d33543b453"
    ["1.4.0/amd64"]="b6bfd9a4424b57c6fcbf874e8dbe3c2c08ac6bba00b613962b728e5aaf0a494942446ab359bae4e4b77d65ac072f6d1ac7dde564061716b6f6f2e41905c8f65f"
    ["1.4.0/arm64"]="c4b1a85d01b0877b5d3917540a48b25586f24e12ea8240e5d9e92e0e4118a8f7019da269d3c88eea79e527d49aef011e6db14a48a69db08e443cfc2e67bdad66"
    ["1.3.1/amd64"]="a6cd20d87fa6ba3173a96dacb39be45e0bf287b87c0286a22184d832741d2db9dc53357747df721235d534e1f022063af30fac15f3f160d99d0b2a54f5703b36"
    ["1.3.1/arm64"]="cbfcb2d86aa92bba331854a58bd9d1b3bcde8bcf44059811c8611f158a985a35020d6072e419a24806ad3f4c9bbc09e3c03227a7e71cf81006b97bb030e8cdea"
    ["1.3.0/amd64"]="d298fd0a152851187301fcfd12963bae59354456156432dcd9e3cb0061a0136d2c9b4555bbb380d7f5434ddd8d45d5289ac15d244e8f2590e593f10ab1680c63"
    ["1.3.0/arm64"]="94b1f76e441b743ee75aa09db6def17f6faf23ff0519be159a78097799527a6f26ad0e181cfb5b3f7916f4172dd414d58620eefa00b22eb5b132c912c5e7c4d7"
    ["1.2.45/amd64"]="c57be2d647c0a7b20338b6e3b239db5af5757fc15abeed2022d312a89334034c8bb8087ee9324e7f8ea7dfc0ee3f76dec97186ddac916eb896a856cbaaab5c5d"
    ["1.2.45/arm64"]="08ee685c7143f3cea394d8582a23c2c1351586d285f5093d082fca1f269e34ba62c4db29d09b765295e6985b42b612a5792a75a57fabdad0a983f64658bd27fe"
    ["1.2.44/amd64"]="5b44b5fb330e35cf9fc8515ced2220788c967ffd6dd10b86773f1e8f5472086e00b8c808234c2efff3e2e583b94cf4f0b06e6e7c29ab19e8c699dba8c992f9cc"
    ["1.2.44/arm64"]="fe20e157764c6a0d2f9a4535d378065176184b44a5d1def28580ffde90b7bc43f52e7b0072b9b3c7ddf1e12237b2e0911dd7827af116ea1d8367c422e85aefc2"
    ["1.2.43/amd64"]="3ed5a57539fa666abddffc52c64476387b8d7983b748fd18c4200e0b0d232e628c87f6b424c4cbe6bc62e003ee3f23800a4711624ccf40ce4bee89ef96fb0bec"
    ["1.2.43/arm64"]="bf1418795106f6f46bab959082fd894773ef6d3c21ef1167dd2cd3a2e9e74440c6a4de43dbccb6b695ca54417f11e2df24b441cbd826cd26a4b00801da01ecf2"
    ["1.2.42/amd64"]="e5190bb4142ca7fc316c8368cc0c04f71f7d02bf0524036144db97edf9f7b7d30644fc0c2d0cae37c609f8ed01d6b2136f04427d40076caf629b6c4b404fb5c5"
    ["1.2.42/arm64"]="08e35dbf3c774dc8153f9287a093155aa6c2afd7dcab43ca7e8d4f55c17b1790006ed230cd5cc88d472a37fcbf858b5f83b09063c851d62696ed8e948917bc2d"
    ["1.2.41/amd64"]="1b01afe1f0e0ace897f2e7daf6a2bb98517ed62486a7820cd9c53d579250da31bbcde5b4a8d485702968332e30e97643faae40e50c47f76138ee06ea718b00fc"
    ["1.2.41/arm64"]="e00be4e1d497694c87e2109f61b9f940955a3a7268c6e9e50b893ca2043caa36468550eb877ae37009cd7b797a22edab445af3f900abbff4818afd190b14101e"
    ["1.2.40/amd64"]="57a59d4b8a23cdaff7b19ab0e6bc2ce4dbaea72e8b6a4f2f7c195e64c005aad023ec95f92bc4a6755d97b76f3382ef8e2fc2469ec58f0d4f41ef72c715a20b6b"
    ["1.2.40/arm64"]="c916021ca8283e61213ce325fa8459ecde4fdbad40563d1967b9f67fb5ebbcf02e741d913c5b70d862855ccfa244c07e83117d169c89ae4ad9adf16a0ef6174c"
    ["1.2.39/amd64"]="d2cb54b07fe0c18136545be807d66738a6c8cabe0e845def256b600f9830859dd41f8c5788757f30362b1392f0d2e42d9711195ceb4da69719b8a829f1f2b73c"
    ["1.2.39/arm64"]="8cf5e1cf685f89f235151e4fe3b8e63d473916e7615eaddf4b8621d3504cd1f46f36b86944856e284684ab9d8b261446ad2ba1e95b20e74d7f869f4416deb27f"
    # Version 1.2.38 did not release successfully.
    ["1.2.37/amd64"]="709f7287a0f21f9503091d33922ff7fa478b043b7c7c0b6ab4a2a56dfb44b740c272dac0cc377278a19f62450d0cdefaf5c056c3a85cb2606a7cfaa267849ba8"
    ["1.2.37/arm64"]="7e1973fafdd62a619c0b3ff3b14d1b13a853eed8ef33fe662a7a3ff23af9c6d30a218893382967bada528a5032b085dfb16bb7a7266e9e945f9370ad265c92cb"
    ["1.2.36/amd64"]="8278a8dc4cc528f33058aa070cecbf8b70244e7061de0dbd462eb0d1cd9e5e83de3fd2ab934c89b299bb2f7f3652866e00da68be5a67fc60d1aee9afdba43ebf"
    ["1.2.36/arm64"]="d18179831cedf40dfca8b983c271271e514d167b1a50846be01407d7fa346866bc83d1ba5c8ab74fca02604f248bc4fd32db0261be60ac380b9a16ab6d9b7193"
    ["1.2.35/amd64"]="68718ef0bb0705961d345bc157fa45c2926fb7c17ce9580e9e7b8fe031816deccac5a4f35af5f5ed61e24b8d67d685896143988209da254a5bcedb38401848fa"
    ["1.2.35/arm64"]="70984d62db676f350e2d7a163c63ee3c3f64d64e03229c74197b70dd7df6dcb3270d11fdef9c28fe52810b5a291ebfc21b5d8defb777e01055dca368f629b734"
    ["1.2.34/amd64"]="4a416fe5359be0daec5e193a04410aa07ab5d2a3a50b71cb9222920b3a58d2c5844c398bf44eb7c0f61acf46757f5fa2b38d0c3a46f60914d66b9a6b819cf8a3"
    ["1.2.34/arm64"]="b2882d3826bdc19e40d846d0360328636fb1ad0b742a15749397e4a49512ed761bd1c4bb2b3d3adc81c6a8fa52ffc5e21be95a09cbb32427a52c4c663da37235"
    ["1.2.33/amd64"]="547fddc68d76f6b7a7a9b3d79e6277db4515e43f1ae0e41422dea8b99742074c7fdfe51c8a52416911c732b4381c72a9f3d95db80e2d712d5b503880f6d4c5eb"
    ["1.2.33/arm64"]="207bdadedb5103cc43412bda60c8d944a6eea8aebdb4c394fb584db96f69dc1b66f3c42b0dc6ff881b27eb9f89af22fa6badb32c7fb7f644752d60dc234dd382"
    ["1.2.32/amd64"]="307af3b208950f17ef7176044456ae62b6c3e853fef7df9355d4387b6eedc7f0c0b2352a6cda606b9d2f6f3b1e3a5563bd26a7428fa5f52e52cd7f39c4a7bfba"
    ["1.2.32/arm64"]="77e1affd502f848ce6081f4cf60c0a4bbbdf081bd5584f468a350fbdafc83ae4e0d92d2b9f1afbd90e28f8757392fb2996cfd6bbf7a60848b29c0f43b9841b9c"
    ["1.2.31/amd64"]="28681f0bfb8748f74b394f210367c0c44e7c82acebd98a2a6bf397e4c9ca7e9733c6346e3484c36e0f63e0ca30d1abbc5c0ce018dfe48400ac5e30c750312324"
    ["1.2.31/arm64"]="03a2aa5801025756a810f6cf64ea8c13ac5a4759a6d1f4dee687b4f773c2cec34312cd5943e94a2da564fee76650efb3a2574b699ce694b0f6dcb9f93ddaab09"
    ["1.2.30/amd64"]="7e5005b7e2a50364e9c8087c14724b2f7afd44cb550b3467ccfb8febd842cf4f288d161a55057ce0dd34c0b025595320beebf7431f79adb0fa4c629f4a4d8b4c"
    ["1.2.30/arm64"]="76c1e567219da279672b74bb9d781a0074af68462e43b903d85389ca39fa4ae8b59b1f6b08923e89a7b51a47151f08dc17ab383549e00d3a4691dcb8e00f5258"
    ["1.2.29/amd64"]="bafc7b09d79738946206671ba623427001085524b93beb39bee47420537c5914912ed5d7e615a9251567d647e807fc37f514d5d4d39326cfbb502d5a85ab1c22"
    ["1.2.29/arm64"]="4f3d7ef32b3b647a91108b4818fa7b853d0bbf1eca706df6fbaac7e06bb477436111e6739cd0d5524fd2647e5516d62f98bdb36734f2a77b68bf62a28e4c6b53"
    ["1.2.28/amd64"]="d241200c4d92b025225ff364b5a179413770b4b34eb7d889a197fbc880a828e91750be9cf79e0b36329d8c77ced5199b6478cb129deb35843593685059d14ca2"
    ["1.2.28/arm64"]="9d253bd08d62992c5680a08df3ce2816e356d58020d32dc2f2b4cc4c58fa49eb2c7c3a82547c1e15203911ec330854ffff3ecd36470e33a0cb07804273828268"
    ["1.2.27/amd64"]="d406dbad0a5ae297544b43da434a44073999a7e47ba4e25668e43bb2c980e07bc33728a924564910309ec825885b0dbf61b42acaa7fad94ceddccaad318412c2"
    ["1.2.27/arm64"]="524b1429d5007b484d4530c6ca75a75f22abaa43decbdb3b6c8aacfe9ce50bbd132aa8f102f80ceb80f56736fe88bfc049a7aa5987fbdfa8bbd1c93a329cb298"
    ["1.2.26/amd64"]="46d273c25c29de71c3a5ca8c582c9082d04f5667c6a9ba87a7b45dfc001a9d73c9abe40e3587dab7e47c9fcd94481714beefecbb4a727559860976ba6775e944"
    ["1.2.26/arm64"]="92daacf26fb815f6bc18aa4f363dcf9b2ced5c82a22bcf17867f472d5aac33f29217ad39f16ab0f77d502a9039b4fa114df94bd8618563074e9190d14cbbfe4b"
    ["1.2.25/amd64"]="8af79e7c744827fb65c6acc2d9dbb2481c78c682a3b26d8171f461c7e67e0787c717d3d66a03ed84773ee6fddfab96791763803e36a9b69a500341e97afc0a26"
    ["1.2.25/arm64"]="5dff4d58b236694c2f26085a8a244775a14ebb972a82dc0878910541c62347911effb1816c8cda2a0e9eeab0dfbe4564dd6d2685487c3dfd1e5999843a80f6f5"
    ["1.2.24/amd64"]="13024bc7c71b869c2a6c4b64178f1612bdfc306b7b303082014d908345f01f20e48c409f4c0b219b48391ebf163bc47c6c21f850b72f2022543f829676eb816d"
    ["1.2.24/arm64"]="fa76ac64077652607dd25d6be8569666f5a771738fc19173d80d266bbdadc7338e27948f424cb5a72b0e3bd5279da255211effc3f605149ed92c02b7a885777a"
    ["1.2.23/amd64"]="ce8f1e98a94b73f4f35430df49544307fcbd3b3c1509de411d6715d1611e25b654e5fd989b5bbe6c4847e8d10fce33b9a1444549ded8842d5440abaf23dfeaf4"
    ["1.2.23/arm64"]="bf167e44ef358c6d8515184aae25263b676fd3e4adce86b832ecfd6a6aef1266a95b134ee65c96e9ea5a1bc969230d3e2e623b822dcf7f593f4259faa4d1a588"
    ["1.2.22/amd64"]="9ce32128978f54ee45b5c6a9891e92364cbd2df62ad4b5369b4e9b8a08097b737a751ed7d3cb8d3a56ea86879927005704e37115f673a72ef1f33193e633ad9f"
    ["1.2.22/arm64"]="99399e2c6fd0c50ca20dd38025494b3fce0b32dc1a1d5bdfb5817eb65a845b60b1ccef646187f73c2a24b91336180e4885b17f2e2ea026f697c38503949e8c5c"
    ["1.2.21/amd64"]="0b335f917934fad20a42c912fcb660e6b6b4864f2303764b1d3f3af8e8c9782438d62bcab9cf211d5947f62867e5dcd5e311ce340c4e8d26356e420cc006623b"
    ["1.2.21/arm64"]="d81cc41b8d53b94c3c32320b742b9c3ec4a70eabe0e5d4bb1d86d7521254faba94294f36151403e2613eede617870a7585ecf8bea6c8682b65a5d35e813b2299"
    ["1.2.20/amd64"]="031a60b210cddf6170df5662bd06fffa32794fd4eecf278d88253aa04323b3d1f9fabc21219795c1a51f2177427e279ccb343be24aa25c1b6cf93568bef3b738"
    ["1.2.20/arm64"]="b62c48ac84020b7b6d67870f18bafd080b89693a2b9637452cffefbb39385d9fd20c464643e10943203b855f81aa7c54600142838aaf83f1991503879ff8e9fd"
    ["1.2.19/amd64"]="00fb72f64d3e75ccca1d930b7b7ec3d257a90876923876763becfdb5be29bfd2d49d504ea79c939d751fbf085afbda2a4c19b4df7e94cd60d567ab3aab434a9b"
    ["1.2.19/arm64"]="800dcae3e973317f25b357c405f9e20ac5bc312568ea123a122c6957381a9e1a91f2dd5e10c0e85ef425a5a7cf4af8aa7b31cee5327632a77126ef6c8ff28540"
    ["1.2.18/amd64"]="85afacdcee7b128f0d57d7f064cd7aaefb4e0c3892d501c95245bd697bc4952d5dfdac980cffce0847a81cada7023e52850a411e758c4d3c8ba18e75029d4f05"
    ["1.2.18/arm64"]="f6ea6045be3d9761b2cf26849dc93ac8d45fa67e46da4e9a22b3c1801907f6c4e346a021069f91c584f52e4d43a5c0e29840a8ebe0af398b32e95be4af47d299"
    ["1.2.17/amd64"]="e811ce1d845a9d11b18c233c268c57143d2fca117c55dd5d32f4d542bc655ecca543ad0b7b4228b1d1237bc04f42b0fb21439915c6758a35eddda89bed18d164"
    ["1.2.17/arm64"]="25a3796dd1652c710d686db9cac9ffeb6834153d60bbe51291c8ab442a0c4a810a7f8772ee4da6dfc8ad7f1d1ce6156f71b999424e8289a544eb453f21a44dd7"
    ["1.2.16/amd64"]="061ec70e4308620328ee0271d005f8d3c59d7275a9c195d076462a5ffd6eace9c646baf169e0ade645b3018f9f08bb36bb8ee847dd299095505c024b7553125e"
    ["1.2.16/arm64"]="751c6ec16d806b2693c6cce25d03990b3a4b749c4ede25829667ec4f64ff83e9501f4d590db4af812103cb976fa77bf6c63d272d9c2f00524246f92520166c71"
    ["1.2.15/amd64"]="a791a05e59ce178bd017b5860043557df91076b8dde7a9ea83f2487bdb00b84fad13871101fafe42b5b6438b76216a4ff52fec4f11347d7900de6164153a2ce7"
    ["1.2.15/arm64"]="f2d47d19744c1afd22ff544d3ddd719522b40cbd0c3664ed6b800343e48cf7b7094d11856a230ddc81d4256eaaaa82d5949fdd515402d87a2ee88e16b6c486f2"
    ["1.2.14/amd64"]="834a59f0f5022cd785387c0358a98dd495e81f2f3aa31d88f75f0abee74672ac87d6f228f75bf1e30ef48c7e4b007b14d20c7650ad028d871169076c49c3fb9b"
    ["1.2.14/arm64"]="e7d9324a64a22b619d99abec00c74b9fca7b1b6099c9f57c44562b7769157ce513633b5d4605c708cdde1b97fe5359f7edd4cea909ad10e8fb0913191c1561f8"
    ["1.2.13/amd64"]="2c97edb11c2b725933e6c6beef6f3dd6ac850e3d51307e048a61e05c231865abc0db2a82e5c75c91c22726cc16c45799412ce7bafb695ccc74b7223a0c707e69"
    ["1.2.13/arm64"]="2279bb773f28b7fa9b2288e340ac3171032014af8208b6fdb372de574cd98269a4cf4115acb93d72dc4342f5b0e9e2def83225d957e8b8ff7f997cda3b40e7ff"
    ["1.2.12/amd64"]="301c882c69f0c4ea0c609e54beee885563d07f0051eb558da827c03f5f8b195925f145ce7a45317f657cc0d2b3843bf79a03b1a8fc4f378a18f90885422d2845"
    ["1.2.12/arm64"]="1270241f76f9633c6cebee9b1ef25eba4af968315d201d08853814fdb944dc284655049adb2efd54426da04a98512bd8d0a3ff3a5ef0147526901223d372467a"
    ["1.2.11/amd64"]="44416d0142847c82ba80bfa29d6442c1707c6d60dab1b0e49be962c17dba1d23ecb1d7350c1d963676e577f00e6edaadf35fe82bc86f15c7808f94e95da670a4"
    ["1.2.11/arm64"]="69006299bf0c30d19ec564234fbe99292b1a423e25eddb3519124e4fc1fda2c276f9d6cfe3e68c62c3fd53146c2a41b741999b18c0c075bcc501d1c15cd38ca0"
    ["1.2.10/amd64"]="3768b994ba12a5c0f37f21e08e52bf8f815a9cf12aedce8242a45d40abc641585a1e4eb7bca08a0e6752adc23ca10f2b6a6dea5e788f31430b4ce746511106a3"
    ["1.2.10/arm64"]="9642951c6c118ab2a4a00ee0626d3ce13a0aebc374fad0a11c3af5808b8900691aa4df98c89ce5a2a9e429fb81e393c655c1279234c148ccc66df068110532b7"
    ["1.2.9/amd64"]="03f00fe63dfd20c20898e6f9759dc6ae725fcb0bb5e446086fbf697521c2a41f94a88c6770bb834ae291fb40417cd9073e904cd0cca5ad01ba2fa3828588c9ae"
    ["1.2.9/arm64"]="f02192e1a8ef1803ce9feb0ad6244c143448374b651092b4fe9b5d2b9359d22d420ae9768c5f69c23fc62a3f31137e7615d783efe7d32140d52670b473f490ac"
    ["1.2.8/amd64"]="e304dc9e213c70f40be95b4b8402042c4a7e6ac35daad9906409e2ae66fae6d827c8a255b55f0d738292044d6bc1b2954fa6ef923dc48bfd69ad6eae18f96e9b"
    ["1.2.8/arm64"]="c35ea194399f27f5e87fb547a30b97277e51c7d1a38841e83e2ba9efd9232caed269e79a38f74544f827288a8380310bf3b7da2b760329fda03666829eb21bc6"
    ["1.2.7/amd64"]="702fd296fd2096e189e9fdfec7e0061fdb70750ec2b62e6c7af5968a76e66d0602f7c36c7db85351c7976604126eec3bb278754e7c50b878e329007cae75b2d1"
    ["1.2.7/arm64"]="0b1cabee955a2baed32bcefdbe46f47a6eaa7f2e22997f01e0b5fb3a829546b74363677dcf1f048b8c78a4f80dde4f442d04a959f18a03ab64b70698bc22a166"
    ["1.2.6/amd64"]="62dd01c19ad3130dba5a9b278572e397df7b674b480016336bd32f7dca6b76b1ad52377b66b91aa14874c837757abcd34e48ff3fa080772928eb1b5ee8de2e05"
    ["1.2.6/arm64"]="39a7f336c92a85b209c2748c48915742e29dd1c62698275fbbffe2aeb1ded9dbf2b24b9dc19aa55fabe8120456d8d1c54cee915f9a9b560d09e74f0c92a4683d"
    ["1.2.5/amd64"]="1684cdff3050f9b7c7c3619d3ce8d4736ccd951d798cf93a138039f4a6d9cdec01264691414b1653f05c3a1c453c0d54b825e351e312f117081b417ca2f3e4cd"
    ["1.2.5/arm64"]="b847df1a824d36148a94a4dd02baf0ecc17d9e656bbeff358537a52e6a512951c8bd41bc0095982f2ed24b5e9539cffef69604dd407919754107b4e408727512"
    ["1.2.4/amd64"]="ef1be767c28621673879f0714ea432e26467d87104dcf364d00e8b0c846b6ef63646856b6e3d26550cb7b13707c169663293c01d7e45e181ed0ffb5f770a05de"
    ["1.2.4/arm64"]="586f891d9a9f6d3fb47924d82490c2898e54d95789d7135deb24f0e2b9ce3a93a4ce8c7ba54925b82a4ced2d17b27937ec7ca5107b3abe038648ac39fefc0804"
    ["1.2.3/amd64"]="5bb0cb18a141924cd4f18f7994528a8a1f4c07b0f92005e39725a75772af9836c5b1d44bd8de97d4b09d07e3b1562f601acad0258a371519c878a73be8831a73"
    ["1.2.3/arm64"]="cf19e47333acbca9c4607a1c87b5dd6c89b30510fd5dde2985b9395688ab7edd9bd2756ce79e6e0e96b8e096c71064fdacbec26affb11f987608017d40a755ee"
    ["1.2.2/amd64"]="00e0585b6421b6af2e2044a2b536fd492d38f4ee595f6fa11153ceb92e638c28b2a7a78e0b41efd4be75331f0dc42f167104293cb7e8ef32254bb1098b8ca2a7"
    ["1.2.2/arm64"]="3e0c50e53a40a16e68bde214075eee4ec6a25e24d0d947f44f4b2cf2d65e9317a98212b0260f55569a4eee3d7a5a53bc0b6d71e69ecf04b2142b4aa5a74b5c3d"
    ["1.2.1/amd64"]="9bf4adb130021712bd6d46828b568434072110dcd2b0b3b02ad587308a404104087c5f439413eb5f197d36d757ce18b3cd46d3ff156e38a57869e18bdc2030f9"
    ["1.2.1/arm64"]="43b4ed8f59cfac67a2064c865aa4b278c63c6c6480df736bab07f7a3bdbf30392a3095cd08331d00a0149b485df0e10a373df5ca92be14ff2516b91ab90c814c"
    ["1.2.0/amd64"]="ffbcdd5d561b2facdb36c0287cf85081239e645d47b8910312663c744184c3524cb37dfde2d6c9307ff4a22e7f2b92e1f430ecbe4d40a5ccb9d35cc3fc87c771"
    ["1.2.0/arm64"]="41b56df0fa6efce048bca31e38c3700350674966f4c6ff080a7b11ac2a44441122010d21119c264cd2dbbdc99e1d4382a72a83a902c79b21c03cd4e9ca5fcb23"
    ["1.1.16/amd64"]="c4749d940c30794f28c2a3213ce11e21c9d7c0856c765c0b845c89a76cfea4e73a6490fae3230621812b969886200e76fc7c94a0e428d193d04887e6e66952b6"
    ["1.1.16/arm64"]="7d4dbc871fae8b5d9c648b09021ac791b1ad4b229d81b68627cd312514579674231a72639e3029e58e84e5c2f74421209da778b3124aa54634c1fd62da84320b"
    ["1.1.15/amd64"]="c2bea4b9af3edde1a34d089a43da2b55155decce0823da2f16dc15bb47cc0bea2452e61ed676314b90bd603fc5209664342332915f149babde042fe3f5c9baf8"
    ["1.1.15/arm64"]="e433f9c349529c9cc03b651650a838bc21739c6bfb9b46da7709523e568850cd97628ab72be6dc647fe6cf7e97664a0fe73c172e453b026bce0bcda3c4499bfd"
    ["1.1.14/amd64"]="0704916528f3192173f3abfaa41cc4aaf8bd4a84e4caba3b855073e4fb3130b613d4338f35e8768935ef8b015ffa36f5d12216b29ca4e5998f49661d7cb8eb4e"
    ["1.1.14/arm64"]="9acc5d64ed933583bb202350897151d448914e6e9cbac491f5f9d610e5458d924be7f7bd1e49447e8fa142fbf54944e977a85da0263362e95d2a472c1f6deb9f"
    ["1.1.13/amd64"]="2dd33b963055d25d8158a23e1e0538c50e17de5340afd61ca46444cd23cd3f7d1da3c7238ca2fbc0153f338789e335ec3768c7ef8ede1d25ca8c3be2017ce69a"
    ["1.1.13/arm64"]="2ce6ca9ecbb95b76d3020700e4960829f52c8c174696146fdd6790b251a98426d24328630d506b71907dafdec2dbfa50744dfcda8b0f44e370bdd2cb187f887c"
    ["1.1.12/amd64"]="dd1622050388034f5e4af2f5eb403456b5ea8133268ae37a628c7ee56f6eeeb6895ee7c121c7783a98532edc0a26b32587ad50305a450b86319e90077802d11f"
    ["1.1.12/arm64"]="c88b855c5a252955a782f7fc1d24900f56f2ec245ecbeba442038c242474866276c60d9ef26b487ec6cd380f8dc8625e9eaa235b09c85d7de1dad8c1babcda88"
    ["1.1.11/amd64"]="1c5dfcb4dc86e7f60c5d093d5bd711fc281c9dc933fd47b64ab5599a501db9fce07b9f1865cbe8078f3dc874747d8dd173dc49288ada03d0dd7fd4617679a1bb"
    ["1.1.11/arm64"]="4c295d7254fcd9def6584d4b582997fcbbffd1f25789bbf00c4a130f222b42e30e544c1f59e6384dee1d370f08d2bc43576fc703a7bbdbb08e46fbd23932cd9d"
    ["1.1.10/amd64"]="a12ae67cbfd5aa5a32f4f862fe4c855095dcbfd19e11d8536e12a3f5851aa7603bcb47404b60eadbbbdebd60125e37d2d7409224ae28fdbe0376921bd38aca9a"
    ["1.1.10/arm64"]="56ac0418724e8c2c2d223260bd1f28fc6e8c582988a04e2421e6a74144e62bdca56671a58f5adfeb60556f8e687408b63e5ebf719927c44097f48e2649d35e99"
    ["1.1.9/amd64"]="671336ffdd35b7eadde51ed1df1a2a494e186822bd146222b1da51bb5d5df8530170514d1080c357c9bcb3bc4f9857ac2354945fa1913f4bfd39ea94cf7f94ee"
    ["1.1.9/arm64"]="de002b84d880595879404e7c23f63d89956cac5c950cabaece074edadf9821c04ebedfb46a75f8335f5c79c292dd89a02ba4e653a815b0a398c216f8fecfd714"
    ["1.1.8/amd64"]="f4140caa18e494ecd2d50d3c149e0522bbf32b6ae3a2a1b3d9a5f2ccb096ec656c04c1a043a0a11cb2e9279a7cd338b5fbce03fafde37d6e58cccf82c9ec9959"
    ["1.1.8/arm64"]="f759be0d4be3cd9c81364b0cbb994b77afce6ea06acedd7642d54e6dc21558fb4f636754748838f2c9e0311dbbfaa0c27f48053fe1e321058dc0caccee8db515"
    ["1.1.7/amd64"]="16e9570cc47cd2406673109f1f733e8f40bf2729658b9e9afd97314886fae9c95873742f0d5aa44609464f6e81bef70779c18fe797038bbd65c993ef5e863612"
    ["1.1.7/arm64"]="232bab832cd2ff93d86a7e8529afbec4467633c1bf80fe859573abb7b8437e207b263a8f10d7243b48b754aebf298854867c7788c04bd6978a3eab0e51afdc15"
    ["1.1.6/amd64"]="b3ad0748ddacaa8380ed655534c92bca2c1a34c0558752796af838f9c1283d43bc0d651543db93a21b4a39fb58c88da61736e083b0e88495dd9b9762fa625061"
    ["1.1.6/arm64"]="869ee65ff7188ce4d3dabbaf6c6e808b7efcea97ef16e4b5b8393e3e42c6ce27ba1201de8a3de7cd908c3d5a5c3d59e1ac1fe44e988215667ca87d69c90c7306"
    ["1.1.5/amd64"]="8ff3f0a0ae524c0d56b34ac04eba500902c3f5722d00fd7041d9b9879df3b4480250ececdaddd5cfc7c2770248d3da9435155471b15d62167274a3254c719847"
    ["1.1.5/arm64"]="fb923890aba469371bcd2933a5f0af6695d2f1fbcb9046aed6e8e151f161da1d28db140a9034a9362b81058a51390514c5969f61d45e2258423f54d6d6b093ee"
    ["1.1.4/amd64"]="17b6782e311c3d2433f2aeab7215f4126061f706054b275b356ea9d422cd285c03d21dabebb7732162ef54b257dba64e01f937e54963e469cc52ede6bf954725"
    ["1.1.4/arm64"]="6ece1aa1daf63920a12c841de1f8b8961ad7520523caa737cb7669fff3714323f6aae30096a46ee5982be70bc886cfb112e495d35f7dd1144d0f38c982c43f7b"
    ["1.1.3/amd64"]="9fbee1aab9f183b8b8caf71044d2b1ef17488f01035cf0868e425e32cdde1c94a130da3b0a8d975726cbadd2513e63af0d2726987a0c929e8eb308db124e9e64"
    ["1.1.3/arm64"]="a8dbf38425362150786c86bc4878e0c87cdb863058897515ab22a0479e36877c6a1418d283c630ccffe0865bac04c1bacce056c1f68713078b53feb7ce709fa1"
    ["1.1.2/amd64"]="f3a7b1c52d3711467e59d233d07ecbf4bd348149563c4abca4b948835fa4a2b6d4b2b7c871d5e4f4423141ab7255c0528e7198e5e988fc54d3bdc432737ffa56"
    ["1.1.2/arm64"]="cecfbbcb5d5e1231cde95af05c6487eee0deae0f536665fb1c2239dd6ed20150ed3c53896f6891692d9b67316f9d8f48d9fb8c7a1bf4e94553ffd0b306aad1c6"
    ["1.1.1/amd64"]="273e50bfc5609aebcdcb3f13dc8684e6fe1e58644cfe75f0c7379ee75e4bf6a10f775093dfae771208f34e6fa9585d98f3dc57d2090303ee65a3ae14553a1fc9"
    ["1.1.1/arm64"]="b9e6618ad107d5a8fd48d0d7b52fabcb403fac3b3195721192d538138ea1e3070153a661a8dce8bd42debba3854811002a86460c4d2821e3679e1e5764ce2db5"
    # Version 1.1.0 did not release successfully.
    ["1.0.5/amd64"]="cab425b57772bf53c898d5840739728f107fe095fff5da94ae70e706052580139dc0488bfd0d3077260afecddc7380bb2e49826be18bc82cd897b4d37f9290da"
    ["1.0.5/arm64"]="fc9db758d42b203975fbd9d2731cac35de3ccde4b4c8557935679a9aac0643139bf2fc96edf82d77363662f1d9cb5cdcefb8290dc83f16dc0840708a75dd13ad"
    ["1.0.4/amd64"]="faf3ad44825099579a2debc4f6317f4a057268ef3d1895717fe4db409f4f054387ab52bdbd6e3d1866721246efae8e89570aba8f8fdc0e62ebf0a0ad31137841"
    ["1.0.4/arm64"]="fa1015d425dda177b19fca308640d1ef35b255d0dc005901accc725ecd8787d1b052a8a3707e28ce461270ca37c372ba09e7fbf8264040ab50466cef7d63ad8f"
    ["1.0.3/amd64"]="e94144bdf613ca9d1053ee03ad6f1436f82155a7d5b665b7aead91205ee27fd8549528c4815bb0dd101cb2ae69ba249808db44b65ee071413a3af7193a050507"
    ["1.0.3/arm64"]="14d4c0a022c0d34b8d1f947a48f47812e8fda63f01c5466df79c7eae16d9061c42ad109efe6273d4d5f9b1473f71cba37c29838aa9f2beae7af521dddb7a804e"
    ["1.0.2/amd64"]="5d8c6a38601708543348af80d9652dd59c4ff2307724b8076b6be7fd26be1ace0e9c6bf707f5a0c927f0f9b4bc1f7aa908592fa78772cb65ad477b7e710e1088"
    ["1.0.2/arm64"]="8640b3bf37fd669bef81543acd5a5dbac6cf166fece76f6bb0814989d31fbd024b7346af540d856ed9a5d99dbcdc438e71b70dfe956eb48ae1fc1eae11385fae"
    ["1.0.1/amd64"]="1e3139fd3fdb6a042d1673d2903d947c0a5f6e7d8301e9824459c77861005a82696a7efbddc18ff7ec5547defbbd6a9898daece68b71ee36ce011d544e9ae25a"
    ["1.0.1/arm64"]="ab6c19137a5ac296ab85e491f217ca693b0a14a168572ea0b36134c4ae476c572bfd8b38523dc5b5c601592780f1483f0a5f85ca06df8a428feb34f5c87cb402"
    ["1.0.0/amd64"]="b12f66adf646ee987d16e08334c3f876737a21fba860965dfc1ff0ecb3eb75e6c5bbac77fe9d7b1689eae6dde4b93c767ccdb166ae23b5d10cc4c92961a3b951"
    ["1.0.0/arm64"]="1cd277ea47c38d97fb8062078a904b83a666fd29b373a2294d7203ecf0a541454f9e3710e6f5fd0b6e8f832fb68f7540e143a1b869f42e0c05734d726cf4c0b7"
    ["0.30.35/amd64"]="9d93c0724ff726f1790e1af7a09093f39e0f7e442534a4fb6620f02c7b72436d69b12132140ca4d1d050fd0d41fef5e536e9e0a0302bbdc86f62005cdc9025fc"
    ["0.30.35/arm64"]="924fc3f56150d3e10f1bf32e5557a73bc402ee7a4816460acb51a2228d04fabf1bd5a2e294b2f8cc604548e2cbe5e70f4f19b2b4dcc519f7346832a9828eb9e2"
    ["0.30.34/amd64"]="61780c6e3c7695e82eaf9377c04e9316ae1230970b8793030299fe795ad8fef50b3657acc45ff0b995bd8c407b7681f56ed84a0cf581ab0bdb38616971ed70a4"
    ["0.30.34/arm64"]="6899d35a38ba5e79364ccf3cf6f77e4c23f98e247399a035c98144f32c80931b7b845c300405db8f04516bd0f59595137b48afa5f2b11b71ab5332e08f2e41f2"
    ["0.30.33/amd64"]="c1d9b4f89957098a206bada1805415208bc8d16ced5cc71b2f4a99dbfff0f1c07cdd0c3edb5a3fd197dac94eec97cbd5fa9bdd2c0b7092493be853b960ed292d"
    ["0.30.33/arm64"]="032f4e1930c7917e44f93e55376d84304b34890f487572c7e289131435806ce7f3d4afe2f180d66b67a0575d4254f80338ca94ed0377c01e72535018a5d5345d"
    ["0.30.32/amd64"]="96477b255dc5976d2c02594c0ac6f823361fbb06ad7f775f5d04db46307fea42e37c6b83908f956857be25276e1909ce336ab6fa4676d591075584e2d747e386"
    ["0.30.32/arm64"]="8be99767036b3e5f72a4c50ab2f72ab67ab003c82e41a592143cdac840a14a8b29a8abcd9645936c312f798c91ed0d61d68247ec208d63d8de3352d2f7339c86"
    ["0.30.31/amd64"]="620ee48998612bfdb11be27c49df7e99a1c58102c61b83c3bae4e7ea58610b25a21cf50ac04ccbaa24dba9e0a189080c49e4905bee653eaffe87ffae1fa6732f"
    ["0.30.31/arm64"]="f34f5f6c1fe798ee86683797525656e4b75f9fd41a4cdd6fe96fcab8adf3bcb7d734f7f4d0bf158034400879b6dfb9700cda07821f584ebe826297195bbeb560"
    ["0.30.30/amd64"]="dc234dc77b5ffc3566b367a61bce1de30689f9d03a05b5684a887a3a98079fc177463aa011faf7895c0ab1f25169d41b5e594ad0ac91d0a79833a7e0e4a71fd0"
    ["0.30.30/arm64"]="a416bc3200890b6d746d49c70dc5f6a778b3af47e0d6cc90409999edff590ab0670703aced06cad25af54d291702f8b4b18e70d33e5a0fa88ce97bab3ea80980"
    ["0.30.29/amd64"]="807d50eb782c372f8ed71b120a0b1e41572584cd8d91c407a75aa66ed67ad2180ef33abb98049be2ff546ba00c8bda09b0477e1a040424ff84ad729cd93c7f4a"
    ["0.30.29/arm64"]="d6a356a97d38ffcedaf64680bc0366adbff797e65b2e59e6744f6cef116646ad26a829e279212b42772d1782e0165b1d1efde88a59e700a23f20a3f674241a67"
    ["0.30.28/amd64"]="36c002b3a2cccd2f24060efed6066a7544730eebdea3c8dcf6f9163229c23d6af7245b188942f7f63ff8140937207be23d835919a89c1f1befe1a6d1f05d876e"
    ["0.30.28/arm64"]="ddece194a623989993d8670a0631a1c244117a0b6267a84dfb780e90586bfd646a515359bb514be8fc1d0286001edddec56b7864fecbead0e697ff188455d869"
    ["0.30.27/amd64"]="cd88eee3b049fed400d6aaec5db1780442b70eea70d42aa3b8e0a56eebdeb2443d5b038f5a10b7f59d2386dced449e5aeca80bb4539046b7182afc13b6581717"
    ["0.30.27/arm64"]="a63caf29e26996205e4205fabcadca3e417e460a0b52a2c1ac958f32826e8a9ede9929b3f2553b68a5d54b49433f309100f0a3b310ad7cf8eb770991e0c7cca2"
    ["0.30.26/amd64"]="5a3be597c546931e8f917fad96beb5fe17030e5bbccc055951d3e0eb30f39e67d383fd34bb69aceca45463568570886ae2af2d8b269a3a8866b39c7aa7272193"
    ["0.30.26/arm64"]="374b8c7639842947065876955566b4b434bed23204f0496a3788ac40ca221d574813b0dcd9787b708ca1cf03c4b17096ed0af65bcfc5dd0049d29ffda34a73e3"
    ["0.30.25/amd64"]="230c45ccfd0959e11facac432c07ea66f5d04ea6adaad477ea4d1af6245254ffa439c1364c5dc22cce8e8f8fc0df266cbea8df3d52dd435361b9743809c5e208"
    ["0.30.25/arm64"]="d6c4de84bcf34e2b3ffe6e563f0d157a47e01a0a44260b743d25ad694847c50304d96a54dd7d3ff875c6c7ff9dc3ddc6d95d5198c2e6c5c18d6ace5f762caf9e"
    ["0.30.24/amd64"]="353284f05fe79a3a712fcbfdf9aa2c1da1967ff6880217f141e77d2d06df750edf5e26c9d58f2c5d54458eece161332c8e086908201f25e0e5ae317dd1b1b479"
    ["0.30.24/arm64"]="eb706c080b106ef0dc1ae84554f61bcfd1324bc12d3f4d82053a2a0e1f0b82b9d1a3ad6fe7091619113d51163829ac4e40f8df2251c8a24f35510ddb0b009066"
    ["0.30.23/amd64"]="51f6978c7f821ee9eb7c8251998d268aa2c9d976aea435f530a93f334da71dbb02892aa521709c26f8ea4aa8fd8b2b4087587ec695929e26b205285984276820"
    ["0.30.23/arm64"]="c85ccb08b0851f9723ca218a29729feca3662da5a20bb7ec4cd9515eb9f4a9a43635f6f85a78fb19be9d4213eb8bf0ca778f0c7c20c34ef13bd55875be067d8c"
    ["0.30.22/amd64"]="829c7f217f7ccbf7446d0971b059c3b1870c3bfaa82868ce812c8c453ad508fc716984a4dbfd3236e093af1c481003ee3f6f4f985140d4f8538e75edbb48b0b8"
    ["0.30.22/arm64"]="0709cbc261dd1240f62ba4026f17d414baba7a0dfad3f7b19eb9a8e74f44aaf4a7f8b4bb31c9d71073ea185feb8f474e86ea89b442bcddb2a556ebbbd53c1813"
    ["0.30.21/amd64"]="fe4a1ead8683e2de8a5e7ea1a85bdb1a3c2db129eacf827d26df9d807ce3d86f7f2cd3a884602e623a5edf0f21912ea1bec867d3164f73f8d6c07e8fd8d7ac6c"
    ["0.30.21/arm64"]="9c0269abe7edbcb17abb79049f4b849cbd10fee6fc73cb189e7ae1ff6c50b370fea5facc9559338473b1e0de15373130112e12544eabf29b712e346e434f0f3e"
    ["0.30.20/amd64"]="6ae56a206dbd6419fb65624e964d8a0f1d2050fb673bbd8d598f46d4e8924fc63c3fd95393961684a78ef59827af39f1ab38b6f3cde48036813e35abc7e5bddb"
    ["0.30.20/arm64"]="fbbe75df7d9d991c2650c5e405bbfdecc90746f3fea636943d5510072b121283ab816813ce4573ea75faebb3dc46443c0b182c82621f0a210330e519b067266b"
    # Version 0.30.19 did not release successfully.
    ["0.30.18/amd64"]="be86b3f89225c3a65f40e00100128c6d25865330fcdca482bacde4c3a0f434c544c7d2ca25b84842472a369019ed182d57b8375ee78f838e9b3566a6521879a2"
    ["0.30.18/arm64"]="c051459e0d4a043de5d3c98f4343498fada6a45b812a795e41f5d116ba9186e0f7b1f1decdf8e426ec42339ee6294aa78bef1b5879d10c8d07e08e12db40aa12"
    ["0.30.17/amd64"]="c27331410bcc3879f0881fd19573cd9865d8372dcc4122d914efa043c138890d9acd789f5409940a8fa7ef11bf888b910c399121ee52829b5ae50479e56e819c"
    ["0.30.17/arm64"]="2d4609638c6411d4d3b71b35841876c4a86e3bed6d95c189c4f3529eae00e39b7d40126650b98c5163400b1ebbce48d4629650fbaa998c1ca295a8bdf89e83a1"
    ["0.30.16/amd64"]="72b857d2ca346c62028c1f1913e09f3f9c801f645032acc81765ad8b565a52d963d3fbfe670ebd35331956f60572cc25cf957214ded7928f717e3d96fa581f84"
    ["0.30.16/arm64"]="bc235d377243eab2adde14869da1f47a3fa05a8cbb41a264a88bdeadab700e7df2dffcaac502f788dab5b634afe5ee4b39a29b56d42ea5d79f41d1037f8a0cd7"
    ["0.30.15/amd64"]="d8ac6dadfba0caa05f19c0da13987f2cbd3b543748ddc796360872d81a389a8cd9aca44b698f5e5abe7b682f19c6448bceca8dcc2f452128ed81bf7cb38adb62"
    ["0.30.15/arm64"]="2df74bba6adb21f3ae49bd3bc47391af671a50d5c4e9f824912457c46fe7246ae4e229fd13d76181a5deb4f7e25f774cf3eec46d81e77542c02b11f171a6c85a"
    ["0.30.14/amd64"]="f4a074e615bf690c1e8e164a2e8046653361fbb2ec796dbf9b7e3cb9c5f2c83f2397c27e3ff819e965bda4fe9ee58878534a34d328f206595f4d292964fcce16"
    ["0.30.14/arm64"]="f160eac050af7f8b14d88cf8115bdb2a4f45dd50e83d82a9fe0daea4292a68d61badd50725ee267e417d01fbb00f5abea10d101ab93ccaa55db9191023f4e63f"
    ["0.30.13/amd64"]="e8571958e32e5424b5c510c459dee578af2e32d635e80dfb4105ea6bd06c5071e60c13ea3f7f0d2926a54cb83814b114e84b512ed0863c06e64f2df2754a3f27"
    ["0.30.13/arm64"]="136259b216211e4d372fbc7a046fd526aa0b2161c9b106a25e2a3ccd66cc7589fafc287495d77dfdd46814b707ae1be03d09c77190e16a9c6fbbd1d943fcf740"
    ["0.30.12/amd64"]="4a0a79ffc7d167accb1eb28bf19bc88736d26b3cf97cac02ab497f40970771a5a20eec716e963f36678751a9c44fc14e010cb62c75f6bd524d2f0c598f94aa1f"
    ["0.30.12/arm64"]="fd763279ae106c3bd954478f6eaa3f346465e50c9e785ce2909790d9355659e0c34cdd360952c8cd82339918b21f8898708e8da96777e2e081c3329c81ea6d0d"
    ["0.30.11/amd64"]="3d23eec2e987be7be90f749fd33cc21b472ff085e8c99b238492dcf5ddf052daabb71b64d1a5bbabba87d7d5bf622413514fab40803a5a6cef9c8fca8defaea5"
    ["0.30.11/arm64"]="3287274e80ca7aaf1201ff3675eb2bc3b55f008cdad5ccf28cea4ff2a0120902915b6b72a7ec0c5e178a2d0a6562dc932497b440f591f5290376ced66d34b22a"
    ["0.30.10/amd64"]="5f8e0456a49f97bd86ebc9820b24927e2d4c7f52a68747f92e38231ac8b549c9d3d9dbcbb2750c4e2f95a1809f31dc26ceef5ceff1abaeede5bd27537957fa5a"
    ["0.30.10/arm64"]="5b18e15590737ad1d2cd7897009d8dc23678c2d00d8cd9da256e42a1623434708b08cd7591e68c2c2f2ecdd8d6b2120a369b0e35c6d918f0fa6cef59c78cdd16"
    ["0.30.9/amd64"]="f72ae5c22cf22fd521a371d8fdf08132d3bb2fe3fdbc37c2e854643f29e6a33c34bd4060b69e1867f57da132c9261296ea8123f3d1fe4fbab00649f28263c057"
    ["0.30.9/arm64"]="8270ab768324da2f9317f16712dc0a66e41f862537901256a17e214319118fa8ca9bdda972e1dae5f6a2d578fe335d2704244dad1940cd8470252a3dde83f6f5"
    # Version 0.30.8 did not release successfully.
    ["0.30.7/amd64"]="cab38a0fb1993b104cafcd993e3d93b92a540a9cf0bff84cedc2c66f053bd3282bd5bc9bd7b2ddae8847dba9c297c904ae9dea135fe86a4c84acb22dc5b440f9"
    ["0.30.7/arm64"]="ac88c8145c932e6196c95aefca258498a6fc582f579cf239426366da7cb6da45e75bd77c88b1010c7e7ef45b52a766a45dde92d7106a6569c80b92c27e174a41"
    ["0.30.6/amd64"]="9d5d1255e8c1d0b553001b04ed2b38560ed7a381a53790debc08ef971b1b7744e65ff48a48a7e6d9f8b4fc2b5283f66fdc6116964ffc057f83e46abbb037e2af"
    ["0.30.6/arm64"]="31f88f889165aece7f1cb31f92bfa19f49d1c18fba8b50e35274e6d7072306060bdc1dbbebca8872d199f4eb5b314c568a5b2825e471ef4d42430a97e29bd090"
    ["0.30.5/amd64"]="272ef290dd79e421b4e0062bd9f3fcf36c61fee82e1d43b0ae8be9cc95505bbb932010c5e03d4de1a45674c8e78dec3b3590c354f4667db5ef6c6f48213aa11b"
    ["0.30.5/arm64"]="10423011f6ef77808ba7c6e79758fbb5238358a9d7a94920f35f404ead8f8a741c915a8f5fcfa9e066e4c129480da1935a51703cf1f0516a35d3800cf0d6d83e"
    ["0.30.4/amd64"]="ac7f87c55d4b3193bffcc5788ccfda274ad0477c367d28937d9dc2cdbc92a125a428628e31378824146b8f12da2b12b1502802479ef8d14bfde59520aa913cea"
    ["0.30.4/arm64"]="3b426a115d71f7ff614c12e2baca3dedc9e9a923921ffc6ef98fe205e77a21cd9e3f9e03c670e5e0d949125f9b92a75f0a0132967da2fe86f836bf822f52e30d"
    ["0.30.3/amd64"]="d4e004e2a63cebb5a43d52211cbe74a36b86c07da3762926a13a01e09c894835050d1c29829a30fc07c36413c10474c21952f7a8415cd9683447439865e67dd8"
    ["0.30.3/arm64"]="e2ccb94db6533422b1f004a5f37d91663a729cf5fe8833ad0251df7d3e16c8605b01a7c51a676de883dbd0c4fd666e53b55c75f2d49e4ebe0e856652b1d96e88"
    ["0.30.2/amd64"]="6828cf461ab736c817bc5f202691ceafa5f51e56c4170a420e634c35d884a201bd9948b412795bfcff4ebc2a912eb5736c9b2d50d9fe7c70b14a3aaf83883278"
    ["0.30.2/arm64"]="86e1b330d2317a02698609504ed3f6ca35c91402aaf7527c335d1ce4501d85bcce5c7e884c78530b8f9bddc57a65e46394addd662b0c58bdebd490e936802f9a"
    ["0.30.1/amd64"]="6ba8139bba371b9e6079f6a0e7aa53bd57a33c121cd62e9c403a5d0740f22365c9bc0fc68dc8096b58bb77a0cc0251a66589d8dcb338d9a0d9c167cfcc383d67"
    ["0.30.1/arm64"]="a2306f5f9cf690941e1797a28bdfca8f8fc278d2e80073d42fc026ae71a6cd83553f1fce14122e0759d4c16f640b3c4a627a364e71bc4d1f811c433439d419f7"
    # Version 0.30.0 did not release successfully.
    ["0.29.10/amd64"]="6e5522465cc58a58714dd8788af6fd212a29ababd3d002a01b74961bb0ee92588d02738167c5accfff723953c95b809f28653f0f1c6016d1c7156250395e7f48"
    ["0.29.10/arm64"]="5c35371043e380f0a699a57eeab0358b2a70ea620678ae844ecd11c2d5ce092c8c984a00a95f65f3ee714823bcb905856fe1940884466a927d965d1f466428eb"
    ["0.29.9/amd64"]="83129d2f31f35c38e0e3b3e82df3be628910ed58feff85b9dd40ebdfedcb64a1ac1d1d555f922f6456e4eec47fe4cd053b14b6b746ed5a16468f41a71ae98d21"
    ["0.29.9/arm64"]="68dd7dbf2095e589f2a801024c95397d07f8fe3000427dae553a77d63ee78d373f719ef7f33e0251a1cf5c949aae951ed94bd6ce3efbd28d946a583c9942dd53"
    ["0.29.8/amd64"]="767e9043da7165b62ce79f6aa7bf6adc2727bff5f8995e855647aea528ecc7ef6874bf0010af6968c3e142fd748af660a7f4b64e600f22ea61ba8a1bb5653b45"
    ["0.29.8/arm64"]="caac06296e4e8d66f4a4130334bae2b15bb829c11a11bbf8c692563287dd6e076dd9f486d12a6972f8b3a5cfa52f33d8a9abaf5adde9ced5420cbad58f0fedae"
    ["0.29.7/amd64"]="c4af875003a2a6233c20bdef609dc663b0c2a89be7caaad32d799152022f3cfb77d9894c66f1bbc255c65596dbf2ce7edb52a58f260608acb52bb0d04489cb50"
    ["0.29.7/arm64"]="6e34b2595b30de3729554d1123f56016dfeffb563073c36382a04d78ea945e5e8d1e9aefa0a69417d1b81af0632d53cae63d1d2d6b046c6f3d6078ba8a291f43"
    ["0.29.6/amd64"]="0063692cbbff5e9bc0c82eda7863d176628b7793b5fbafc0b9036584146696845df77149975d7b76028de3a80d1d735277dae30d59827e674b696797dfa2273e"
    ["0.29.6/arm64"]="22cae90cc27f3d6a41898eca69670387e24777cf4141384e333d42b470bf37d0ed76ee0d6f408a9c42ddd257e47837da7290fc7e66e79741dcf9fa4a30375392"
    # Version 0.29.5 did not release successfully.
    ["0.29.4/amd64"]="bf75ec7331ad1c9bf464f4d99b839488ea4a7a040596e8b22af199dfd4ac96504e01e633549095eefc08bfca63b8074eb8e372e092273e6ef83ecc27ac8877ba"
    ["0.29.4/arm64"]="4c570025df1f1a19a4b96782e6cd1fe25d44392b8420efa947b2d5a4af298d510654aa9d8a7eedd37b1deb6ff70a7f95cff669ffd52d89d95e6eb6c50f26027b"
    ["0.29.3/amd64"]="a26873c5e2632ba77941d86b834b238128865248614c6d9bc6e1e8e8a87b6d8dc65d7e4ab49f8ec00b650104e4e207a5ab7bda12911ab0a9725c8c1f3cefba6b"
    ["0.29.3/arm64"]="74bb7cfdfe37b70c01eb40580e87d73111f1c153cac9d5e881463a478f121acfc7c547bc76687cc2bf655e54d767d643d6d5fa97201549276f70df16d1d0abe8"
    ["0.29.2/amd64"]="b02564fe26ea00ca17156121325a52744889c732ace49a0960dcdb6c320ce4f8d569b511e6f0b2d96de5fc09983cf46d4b8e5bd88bcc16126cfb0a9966de5216"
    ["0.29.2/arm64"]="5f2ceb791246b309077a93b4bfc385d350ab5e9fe2322c89ff8709cb56cdc1ed29fc4ba655b69edf503c13fe266e8284dd2bd411a1d356d64768842c78265181"
    # Version 0.29.1 did not release successfully.
    ["0.29.0/amd64"]="b573ccf6819e358c91e13b906b8d50245a03b094afdc940f683984f93bcc32012fa98284b24e8154ec524156bc9345b397677052f8d1b956fd3a1401477ad0b0"
    ["0.29.0/arm64"]="ab1e1abda45c10d80929607d3b96f33a08792f18ce12d1f9c1e46ec368fe44d0a44f7f9adec1df54e7f95810a28e5c344fab42b0435c7d2da58bd3dfb78e36d2"
    ["0.28.0/amd64"]="312020153cb8e9ffe35bc6f0069fe6c573b5e6fa03c1d6a0f1c179568fb1c911fbadb8997a1dabc957511255979c252462a231cf8ab616b195ea5830a4df206c"
    ["0.28.0/arm64"]="b88dbc0b8de0cdddf3f2a1bafab91f4c13f88c7f6fc67ee5f9d60acb3389480dbcec5e0912e841c080c665112a4863ebadcb4038305624fa4b2d3659ec8e54db"
    ["0.27.9/amd64"]="730261e292f7278cfd4d802dc657369bad36b41e74eb86ebe4fd52929d9f6df873d52dddb233a9f0c3ece6f68e613058755204291540ef1021ff72d38d79b132"
    ["0.27.9/arm64"]="2669929ad4d529cc013a443f4f12f8c0b7320b01071206a27cfe98f5c017d7f36422cca5e5bc325a6b6e052c05af61956233854f6a5112884dbe0e8db90e5d9b"
    # Version 0.27.8 did not release successfully.
    ["0.27.7/amd64"]="776523a75a5c0574cb8a8411e7922ae3a9d2588178b08f565bf83fb8617bd37254b4d4e15e457ebf19ca0b14f556ac8018287548fe9f3fed97d0416336b57d44"
    ["0.27.7/arm64"]="21e979dc77c9c83cb58fc01b97e8a312749763e317276a3c8dbc041c0c909c3b4c36daebbf109a2fab3aee4043d9cf3d03f076c6faf8b58e6e0f8de6a659b58c"
    ["0.27.6/amd64"]="02d862d5e7c27e43e5352d2eb3d1080cff95d5ea1f683baf102b280f2e3de95f87e2c26b129ee1096e43edf5f70c234c3be4b9e4477d3aec1eb2c250e00203b7"
    ["0.27.6/arm64"]="70bb85c7c57f061196d883bcc44ce86b2899b8bef1fe311e8466fef56f07a38cbe6eba22420c96916b0911cee67e9b872ee9be4be2607d28f482f1eea4843cc5"
    ["0.27.5/amd64"]="4b71327e2a0164cc14c73b9988c59b38349dbf8509f0a1c8a6e8605f2af819da70c2a8c8f0b3af09c2705265e93321802a0f0123e7ef03c5393bbe62d0634b7b"
    ["0.27.5/arm64"]="e9331d98a07fbe7e0140fdd014f32ff43e3bcd4e5237c24c67a352e40cfb181b5f87e63b897fde89c43000c064051ad9cfa79092d8f19e6bbde1ce7e90d4389f"
    ["0.27.4/amd64"]="4ad6885f37ee08480154e44bb37a6244bcf58bbff4f36f166c4ab1c571ee575a8212a025830864eb5b46a1a16910fe8aa24d708a8bc2009ce00ac335ace4d9f6"
    ["0.27.4/arm64"]="16233af07363679f057f07b6dc13bc383163e7ad45b05ba67de5b01ebc1f20b6690ade452287f351ac7051de5171541133e3784818830263ec2289c8e8b25473"
    ["0.27.3/amd64"]="42301c32f755def2d1a5d910c5f58fc15995e61b411a38f2a446575d4536fcc6147f61a55ee430cdcd87d0ef19ef4553f1ea28dbc6c1f2346d3731802334e71e"
    ["0.27.3/arm64"]="142ee90c99e221fa3f0ac9bdc590cbcb736ce955d478a4c1211a8d1fae89930ea28f85767e309406e3ac09925573c29a4fa404e9d5330be5998d1ccd808574d9"
    ["0.27.2/amd64"]="2e4631dfa7ac76aed89f146f057aed5a3f8bf8d892b476baf9cd9a2c788434d01031edea414a51871f22fe1452b0c94024fba0393b501f1c363f30dae2254fcc"
    ["0.27.2/arm64"]="9f3a8c589b76f0b2a5e276726789cd2691d782b5a0a23c676d61f97c12f3e4297ed1735434b6c18be536dbaa3b7a1667ba7fed41290fa60f8bc921086fd6b901"
    ["0.27.1/amd64"]="903ec4096d9963a757e0cc6cd9d100f13c07eaba0f6edd31b4acabfa483b5490375e55b41a3a1fe907fa1f9d4f49997575027d6c15b91f4d3ad0cc28a7efd8f9"
    ["0.27.1/arm64"]="10c1b0748248c293f50b4e0682d4620e3ed0c55d993a504d112fe0fb69344699440d4265966edecb5707d998c612e21c299444ffc709ce69f8e56fb88d2a5869"
    ["0.27.0/amd64"]="7c1c217fc3f1943331b3b9b84f386fea0e02060242f6c5ce25fdd68e0d1bb727ebd527e522f59142d350600f2ee166de769ab05a8629c678190abb5c9b6a0ec5"
    ["0.27.0/arm64"]="e3fe89dcf523692e4018886695cc97348545d39bcf4a0b2d058a599578154fabacbbbdbea0ac74cd4f1f3411b5a562db72798479b92a7447d248519f35de234f"
    ["0.26.1/amd64"]="ecff0de964368e579e62f430deb25ab6e07a6e9fc3fa3b4b6590422d1a1a7738ed4bb333a1cbdbaf77efa25f3ae6c2e51ca9e6084413f448bc647ea95dac9c06"
    ["0.26.1/arm64"]="14f8546c6db1076055df91cd3e8f2a2d10206116d3d5051d1b12ceb8207c92923aa4cb69530bdfecef2646a16a8ca1dc9b17db9e80e05ae87ffef0ec3f9db567"
    ["0.26.0/amd64"]="467f18a2e54f4d5c196b2de658401ce398eeffde947b4851d92e91edbde1015ee0805b17fc8c240c75240754ff8b14f15a6d6f7b4bdb536a0c09ecd5b4ce4a42"
    ["0.26.0/arm64"]="203f01e742b28fa47161cb804fc80197bc3abcb4d39c4b03dd094b1e8ffeb6e0ab86b36a62f7eaa2ce12507aa879a6ea587860758e91207b2d57db29cd67b1d2"
    ["0.25.7/amd64"]="6e341724cc3954e7d266f3f7095c61ac987f0023e0b25f92a5db6c1856ed5c0b63bb96f413bbb99a55c07b2d032a4fd0f92f14afb9f30e829ad4194cebf5c2a6"
    ["0.25.7/arm64"]="194688a47ff4513701c40e50028a6d9412451b352b47dc78e239d447fb664fc4201723a24336dd39a9dd26e22528e0ffda9daa7289dbc25014c0dab6063b693e"
    ["0.25.6/amd64"]="60f65b666984615a39bb2abc7b1a940697dbb4197bbcc19d179c5a87e38395b63c7205315c0d3050bd5e90bc260e5e98869b3a124fb010744b7f8e5524d7d426"
    ["0.25.6/arm64"]="4303a8dbe6630b5ececc7a1be418d3627b91c37a1bd62fe15c65fc9ecca87428e192f7fd0dc5e5862c673abbc39ccd934c06e27ac195401037b766ccdc833b5a"
    ["0.25.5/amd64"]="3f479f571577625e5e72a6164010e88bfa49b70d56d3edc07e5c09ab5a54344e5c88b5b422dd9deb03521ec13dde3b4b7972026e3cc2b94487772aacf9e6a847"
    ["0.25.5/arm64"]="03d62ac6e57d5326364fb82c08065a8636d74bd687a5cb313a7b9ca128ef0b37c7b223e85c17d2293bfc4e006c233adfa122af4e4423514be2d7e54e36290413"
    ["0.25.4/amd64"]="1a1bce732f0465eb77189e280b3c0bc724e4595ea1e65ad94d747194fec2c893affa02792f8037c812a75b1435fef3d902de927caaae1187f2aa6b221d168392"
    ["0.25.4/arm64"]="15d6c4e17b25c620a6bf5ffcba3aa5a2ae5e96d9f847471a182dae76550b0589e08229093c8d04d3c7389d38b4c2a1ce267a44183c96ffcbed5df8456bc6c28a"
    ["0.25.3/amd64"]="ddeae4b07311dbc06d3b980f3ec290303a062a8ad7a122c2b8a0a20c12358cbe43d21d24ca6095821acad694c0af1fc34322e27822eca519e31cf2ec413dbb0d"
    ["0.25.3/arm64"]="1aecd09436d25333a07f30291a4cbd94efad7adb87d5d0774be934d4234eb5ba63d7b892318d4674b9c0df0121c04850000233400ce0f32c78b3f286e5e6f9dd"
    ["0.25.2/amd64"]="1dab905786c1f3d366f60609caf4a7a5aece7fa80c642905c921f2feb9b0e2469ac3deb3222936c09772b3b6c13433a82a5b6e650e40a8d1d578f5f18807bd07"
    ["0.25.2/arm64"]="68d1f48bf32b7f8764932d6d30d8679dc9f295bc98025981ae729b7930fb94c7c5bf7ca937d238d5f97c69c81f8d5627cfa3fdd838139bc23f8bbab2db32f992"
    ["0.25.1/amd64"]="4f54dc9861e8eceecd8d8ce26cc27767ce462d178dbe945775bcdf94bbad9e3e68c43147acaf663b4a2706df68631b5372aa7f6b6ed31b5f6e71f3435ae07737"
    ["0.25.1/arm64"]="4961cc14efde5079d1a76c7e3ccca7889d3c889de0e88ad5aa8efc4d13f7fcb184b934db5da6afb172392e27714baac591b35bdd829562b294a05cf4018a0575"
    ["0.25.0/amd64"]="7bfe469f893dfa634e365cf8e13af4a09c03b8af3e24ea78f5c6fa042f46a8d71e906ed389030bb81c2b5fc2c0a9e9644c4dd515c9c369d0ce31d311d7241962"
    ["0.25.0/arm64"]="331a6e89ba0a0e4d7262e589bc982ad5dc2573347bb01f8adb5d3644251e8fad620110a9089c5e702fe242c50b455b36ac4e8c720c5d54b3233d0574bfb0e5db"
    ["0.24.0/amd64"]="fee5412339f85d6565d7423510dfea673eba696487ebcf86c6ffc592367e8439728a70213a552cab8217024c9c62c7173587d56d708235fcfa0b09d4a32fa701"
    ["0.24.0/arm64"]="d6cea154072d72320f9545505a66ed6a4eb24509bef74743ac875ca1322fec05faaac4385c3996195926c2d291e406fda5824b69679173ecd281dc5b699e5d98"
    ["0.23.0/amd64"]="e8abf2109c015f2077cb6e23207c005c0b19d74bbfd78b113ed9645dc573fed16f94f7be31c6bb58f27cd21d61a76d40363b443d46ef9982f98498fa4f6a3e57"
    ["0.23.0/arm64"]="45eb567a0031158d22dda21951d34ce1b27d365930034047a75280020f5f305e4bb9a7ca102f74ba44157793cc979126e83bc8a9605b706d5287380d62d6da6c"
    ["0.22.7/amd64"]="ddfa71081f635b762b129557ddead5f19f9af9f68a872facc86eab6d4a4f7a0cbb275e082362795f8f9c0d0b630a8f65276e53fab2f8f4a52fd2405394d1cbcb"
    ["0.22.7/arm64"]="7ce03df2f94840052e80a17279c9f23ea4c653b571aa4da1904bb29f306c9846a63e7936833588a614dbfb6fec6694499642a42f8f63315c5a1dc9b621e5808e"
    ["0.22.6/amd64"]="a8c997fe504d64470cc21896c4a57273212bea5d6885641863f1030b44b2878029bec8dafcdce873e540771be60f471be25f1324a658e5e7759e7b8ab2764940"
    ["0.22.6/arm64"]="83885350e8c4e2e56d16690e90fb55ee891f90f5d4a7a1b98b32950e93b49f8b1a420a74272d81512c5cbd3d18b726ad8e058e55249dfd12b6cfa64e39aaf366"
    ["0.22.5/amd64"]="e4368e7db1a35b6e05eed409283543464d51460e6b99923938f880277c4d9dce6cd3f7c004134f013e4286916c5da61769a6e9e597eb691f70269aefb48c2432"
    ["0.22.5/arm64"]="baf7576c3fac55dff8d928ff12a61c1471a5b8d57eb6a6ad139e93320cb476ea093a0d5bc004ffece0b8eb71c7f7c03e79bf34eca4db2e7f5bab97da03ca5473"
    ["0.22.4/amd64"]="4c225685ead65c6bca1e7b3077da8e5d345f8283848b8a2f32f00903f10249fb7a62263b75bbbd3b016440d43dc0da3a5785b48ff3b0ededa520beb1496f03d9"
    ["0.22.4/arm64"]="4a4face185c1e353f018a4df6854ed2bd0b07a4e0d0f83f6bb005da624c954cbe0df5e912b37c3987047cc789ec07c320cf84672353e98233eaa3424368197a5"
    ["0.22.3/amd64"]="419ab92a8f5ce7fef79392192cdf2930f691d02a24248d44d4d8677abb107da03935a54db2883b514e09c3baa1690cb2437f5cf4d25c5db35ab0226de7670df6"
    ["0.22.3/arm64"]="8c2599db1d8d9fef1956779487c922e799be31d567a156be6c2ab3e76d209b58534b9fe72f36798a05a97e6ef2741ca924fec517bf6f619aa6cada3b00b18fee"
    ["0.22.2/amd64"]="eb3b010cedde1f8c65cda947e7daed5a8f55ed6f0c113a8a153e578420e43d2b47065b99edde0815dcaf4b27426ba8d2e01a19aa564a045278a45f5dea045d3b"
    ["0.22.2/arm64"]="32b85a5b9a75e1622f6959c30aa11af094d9dee829a55f4690ed07c23906bcedcff52f060fd7b39943a643c5da0a8aada6f4a748d38c5fe7c9da5158bf3dbbf7"
    ["0.22.1/amd64"]="ec1f2459bfa1d6f2ba306541fc2f18fc0b391d44532008193ce11e02e15094c6cf5b41be0b70d2e5919e6c5f5cd1b3c962817e9fc4f698016d8a8431c5da1b46"
    ["0.22.1/arm64"]="b51d835b69bb218321858af17eda896778bd3d3c477ad3cb8e2ed1416131379d65ecd81a26558a1dc55e85a19df4c53fc1e3d977d690651142d098fb7904e7bf"
    ["0.22.0/amd64"]="8c8210f6f69ef28f8bdb4fb16d4fa819ba1316473fdf3ea1bc487ef24faae3d068837482b632364bd65b5698ab82e685acf7a2e737774bc166724b724642bd26"
    ["0.22.0/arm64"]="f3e58a2cb3ce8c1ced7737ff5733c0d04e69ba5008f9c71a2a8b5c94a108311332c8f7ca6fa8cd2dc3dc70fdecc0633014507eaa145ea85f872958bb88904bd8"
    ["0.21.0/amd64"]="81b6057b5e0b52d560683c3db32de02b1b280ac7b415f5bec5995d8b283f108402b5af721813c9379664bed718e1a6e599c010f6c2c5f85e9a25fcfa604f49a4"
    ["0.21.0/arm64"]="5fc868f10acfbea34e3da10c0e063ac719f208700001be65f82fff29b283ad0917bb328515ca018fa19fc866bc151afc8d5d6eac902acf3289ac4d5d72991059"
    ["0.20.2/amd64"]="c3611f156cb6c4817977fc6e0762f0a70da8e7cae4b50563beae5a2e527cc4533427480810af12fe90a8277f946e0386610c220ca9b831c02949863931563667"
    ["0.20.2/arm64"]="e0bb8a6a106bb8c735f8e40cad4a39b003f98f4c03a172119e39689a9aca970be68a23c252b38297115ff57f2bb7c24e569b206a09d2ada37b02f823830048f2"
    ["0.20.1/amd64"]="61a964bb8049ec9b683575ea9c44cc273353bc618d0809a12e5f0d4aaa422c5bc1e97b1206b80417d74da0d32c6e86f1ade69c9bdebf86b2b56b950658df95c8"
    ["0.20.1/arm64"]="f25dc38b371dce3318766a896962e76ccd3a8f3fd4890540979e341d84fe90eb4a2ef49225222ab9c3bd8ca7f4cae1b50d2a4631b2d2b29ecb6995a9b3683f80"
    ["0.20.0/amd64"]="de10a45c8a8fc64ec4c7844d75744c832ceb99831260648b4d2a10e76cf8129caec1f6350a3400e87cdf70df8dfc39d39b348978f7d5e09aacd7fd5f731fe069"
    ["0.20.0/arm64"]="b9b6acfb5289b0c3cd4c3484102ca72a36cd21d0c7a890983980409f0fb58c6e6f67553a0cc96aaf3f98d45051f81e7888927858676df0cb5fa011048949f587"
    ["0.19.9/amd64"]="4c0939551c22bf61095d57585c4fc967b3abac597f05842c506c5a34ad90220a35177c3c93b407a5b2dc48d08011c209b7da0ae4af0d9b703aa0604611d1372f"
    ["0.19.9/arm64"]="90eb0a48fac7eab04928ff4179608964c859e3c3512c8f22f24a8c49b7a7eba74b6cefce450fc0dca178120e5c2e08c5a87d441e959213e12b1e3ab01e7d9f0e"
    ["0.19.8/amd64"]="e56a13b52a5cf91b355a23e73847d77fa1cc74d3d0d472320e3f4fb330c97b5f160b4ed478a4713c871d2fb0855cc05b5e5ed26c6add15b10bd896422aec4e17"
    ["0.19.8/arm64"]="d5440e3d70b27dfa5a873d89867b6246e4b43c108ed06e6395082ce59d071ae791b7af4801772aa0e34792916f2477ac03440026812eb42e796c0815957b8c61"
    ["0.19.7/amd64"]="d50484a217e4545048446237bf6ef87072fd3bd5d7567e85e1e64ef6ca989ef745812c9b1c46ff092f03fea806b1d761a6c56ba177f91cc78747411443ee045c"
    ["0.19.7/arm64"]="2d812e4616801cfdd519793164fd7f8aa4d400311fa64266693a6da1018974a3a2ee055a0df3bc44c60574c1507c6b9dacc1abf70ab076196ce9cb37a4716bd7"
    ["0.19.6/amd64"]="0d9cbc600b57edfab484fe20d4dc95a2781837df540f542d12497e67bc265a4ee9ace1004500b7c3f018f9e395198acede2fcdb3b4be1f9b0739b183ac5367e1"
    ["0.19.6/arm64"]="d2bd0d39aad2c30a161bf901f5db2a2a2a960c54551775ad8b2c9207fb1c54705c689acfb2a5f1eb5cf6b4fefcbe6ac23d29b16024b2ea5743a84d86d8f1b6a1"
    ["0.19.5/amd64"]="52ac3901bc72b311914c19c341b08021e0353e76e8ab1fc1d883b9e524d9095f4b644c5dc302081c695467763db01b32984b7156e4146917c2a901377ebebe63"
    ["0.19.5/arm64"]="ea7d11c2d591fd654dbcf8bae06ba45b84ff2d75520f4c5af5eb0d6141a80bd2893dc275fd860b8b3b1890f0870bf21c3f51815182c98add6fdb2be5cc422d24"
    ["0.19.4/amd64"]="3615de3e5aec73a8c49eb4df7d832a378ab922d6052c1c9c185da4a7838f42720a4270a3da3bbfa520fc61c4da8ca9a43128e864acb30452b4852556a31589bb"
    ["0.19.4/arm64"]="ec7c3834d61821345f534ad317c01115804c44897a3ab3f5df90da01c5cce5607febdddfbee139866fced3891713234eaa972b38044358250b368a14779a882e"
    ["0.19.3/amd64"]="8d0f5e44531f6b0e9b55c1d4fc945262633f2ef87db214aae9dd14aef73efd1fb46e2b3746a0d67436a03fc53f48c871719ae02fbb0960bfc3a8153c0dcfe1f4"
    ["0.19.3/arm64"]="420195fabd9e5d3d8417857cc35e1daaf4407ece4f27d6cc87a99cbf17fb7c838fce98b0543b7ae31e07b69243ae22a733d1a9a91fbda8b360e72ed67e4b0106"
    ["0.19.2/amd64"]="fc8cc21a3bc2d7b086d62d944c263d8991e35917b6c4837b8d8bffe7170d346da54a923d515dc835ace2a1b9efbe714c97113b245d14a4f68737b607d0b29dce"
    ["0.19.2/arm64"]="04f8c41894bcace7637fe16731071a4b14de3d71fc4157417c7dea91ac523aab27a18e915d9a64d477b69bb0e90db16e44329ac979d1524fa9a4bde054263f0e"
    ["0.19.1/amd64"]="bf8768adbd8c8baf0c5767334cc7c3f59da089e79615a029546f34504aff3325f242d47f15f46babcc7b56e0326473019b4e263e5ef782940022d60c9149789b"
    ["0.19.1/arm64"]="81351a44f79260d2407f82398431646c47845c435af2227d82dfbf3f2db447274d1dd3a8c1542dbb4713863e1b6a4b8fefb07d940bfddaf9a9b034e3b77a71db"
    ["0.19.0/amd64"]="321d851b52c0ad6089412a517e594e29fb39780122ef27f6e53c8d4edaf1339df109f03ee33e1ad6949b975ca157b8f879bf1b93ba3a694819be994c82eb03af"
    ["0.19.0/arm64"]="87a3e0e4307247582d7c455c8ddb16a16d92c4f66c04069bb0d5add3ef21e65cd2b6f4dc0f54851cd558d6c0ee82182887b82069d74a544dfbe9ab95db1fb7e5"
    ["0.18.1/amd64"]="d2efd3fc265a421f77702985c634d3eb9d8a7cc1dd9265c101238ac1db5893688235335a2e5c9e3fd92c2eebac66c772a50117b756351c216827887d500618b4"
    ["0.18.1/arm64"]="6bee09c2e0ae1e1746a40e238dc29dd3bdfcc4e137203337f17af155bc72abbf065f331125840808f371623267a4dacc03286e5b47a0e884039418dee146dd4c"
    ["0.18.0/amd64"]="84d724ad401bab3a9fca0982ba03a2a8a581d7dd1ad75149ed1698f646da75490d638e43c9c26215ed953f99aa02a91dd7d1c9a562f822e644f5e52147f7d009"
    ["0.18.0/arm64"]="a1a544d4804a9060ae99a5b4551c784dcf4ff3c0dc66371501aeb0c840256840ec1dd674b51526fa367943d98f44de2086b1b3086c9515b0c8ba5e0a3fb27a53"
    ["0.17.0/amd64"]="049122bd578156c4c7fa2b883896e74e5f4fe2616c959ca8611bb44434740759fa8bffb60d31cabbdce67e3c3655d2c121c1a21ba8647ed0f888bfa7dbc08dc4"
    ["0.17.0/arm64"]="1f6956f81813d069f574d23cf54f09facf317831679224e4355c45a3ee72a5ecba1baaab63963af874859245d2bb8c94843d63dd83bf25d00b6a592fb0ddd443"
    ["0.16.0/amd64"]="a1a375b72dd605ed7afe231eb6469ae66c16ab5a96469bb5c9e18769b8a299b876236f32f6f5dd66fefe3b1b54eb72c98d357a599fad25a8739440b41996c859"
    ["0.16.0/arm64"]="a7d068c7cbad5ff2950a42dcc52f63475711b270c2abdab07f5226f0f954503773b60f74367d326a9be8f5afe501833ffab67685ce86d20da459cb86677097c1"
    ["0.15.0/amd64"]="14e6905b2077e3e606beb1c0d660fb4447e89999bff974648939a5f0619e9b74a9206ffb08958037937c87ae81829d72df73468bb02e8dddb4238d83825b3795"
    ["0.15.0/arm64"]="4c97085f84ea46dfcb8e70cd07595dd475e5a41f0526ba6605dc32f290ba929096824a9fe8aaa4ff711b8765cd65530a1c54da2bbfa4dcc580e1b101710a8fff"
    ["0.14.9/amd64"]="7c3ea4ad65401a92194b359be7aa2ebbc93d7d0a9c5c1a1e3cec0a92608f9782775a678dd2f6c8a6c56538ca2cd9c38688cbcd8a0f1d9e2cad8c739f4f56babf"
    ["0.14.9/arm64"]="f8cfdc1cb80361e61c65c0d8b00829c8e02bf51cd78fb9ee93e43d1bd0af1063d3c6c55e2e0dc5704135fd188fe8747d3798fe3a26bbb598c7bec679767bd5b0"
    ["0.14.8/amd64"]="b0fa52194e327bf8026707ffd1daa3d387d968f36aa642d73ce27083ac04daf9cd7d53c3b72316fba5d5e9b2b9d66244514fbbc655fd47c96bdcefd824a6d0fc"
    ["0.14.8/arm64"]="e21b9cab07126a559ab182fc55e4ffc4bc337d3037ceef458ee6aafa57f30adae5f4a2e1950e30c588660a06bee6da6e3fe01a9332762ab5aa45c825c5796009"
    ["0.14.7/amd64"]="576aae40265978594896b3e2c438e9c76ce08e96e793217df105581be2a4da55d5b94ec27af20d2aa04f165f10a6c35d4cd070fb94b35aaf80c72e5f924937b6"
    ["0.14.7/arm64"]="6462f6d869fbe5a4fdbe9086ee7626f2a8937fe6c926cfc93899c85ee5d5f6d504ec18032e16921dd9635870a6a7bbbf592c3673bbc5dfadd9abf18b9314ce7e"
    ["0.14.6/amd64"]="12706241294c9a85d207d0fb92de295f9ae4791593bf596cb2ccf8d578f3c5926bed3107383f2315c9184b2aa9e9d820f08cfb186113b5f47d63e11029fab411"
    ["0.14.6/arm64"]="b01e97e82e049a6a6339e257c2da822eec79d657d3e4e1f378cec64a3babb77d9aa429107a91e7b15c292c7e04485ab7220097523cf896cfa3f2836fd5bd15e4"
    ["0.14.5/amd64"]="3fefc73c48132cb3cac454837d04ba3bcec7cda1beb3e449cc018aad2a1ce41630cdbd0418e585e7c7b103e87d2ff4386039021bf48cf7e73fb8a35cd167eef8"
    ["0.14.5/arm64"]="1936802603361e402fa72af188c73544c843fc8082052026ee8bfc89f91ae7f821e694ee667f2fb3348568d70933f879e86e9dc078b8d19b3adc063dd147f396"
    ["0.14.4/amd64"]="7a95d2293d6f60901071997441e3e4ff179fbdbc5d815be93570536a8a13f167802b9e721ae6f87f03bab28ad97e3cdd08926864e8b86feb833541bd88aa28dd"
    ["0.14.4/arm64"]="f033ebfa52230c34179f823a39072281d14d1036f6c9301cdebad756e6b322393379cdec9c300d0d6db0b0f35159f8664fc4c4c345e57747b4d923d46f70c970"
    ["0.14.3/amd64"]="42558b0372ee2d86749c3e31527064b75b84f66c807063be33aeef616840b25485a312a5d510325337a258b06d73dd307feadb0dca031f22c8950c91e9ae2f33"
    ["0.14.3/arm64"]="332135bd33fbdd3979dadf08aaa540df54037bae1aa1481aa7afebbd57580bd77ba78d4c738e7f9b985ff08537bf431a431b446a41df45ba5039eb391c8c4920"
    ["0.14.2/amd64"]="f9ffcd8586c64e935ab680fd3f6e5ff9c266c21d57f6692f84b0b9ee8c7d72a0c3e8c689cfe1f6ba381eba806f9ac47feb73b186f9267dfbcdfc4e900faa7798"
    ["0.14.2/arm64"]="55f24a36bb82282a6f936f84ff0f63a8dbea0aa6afc3ad1308379f957592b0e03db5c70bc7538fa3eab9cf660aac7bd2ef0626c02d7b57a0c584fe92243ac49a"
    ["0.14.1/amd64"]="17d87ba7527809140ae037214862aa9e7926775c9a0cd687ebe19eb653712d28f8e27e1733888f787af183ce1e30cda828c60bc90ceb785c9c2b8b4ee2b50f33"
    ["0.14.1/arm64"]="d47f68bc06c3281f665ff74b81d990beea2a522c6cd6eacabc9362b08cb9e03d0cdd03b1b5992d8d37726b11ae59da460b83e0ea45a6a830a10fd7dc3f391811"
    ["0.14.0/amd64"]="ad0efcc1b643186efe31781eaaf308120727bae507354e4b4b43738be3ef16fd12ee202eec07e559441761ed64cb4e4b26e615dc49095c7771dea6fb8ea6fe4c"
    ["0.14.0/arm64"]="72e33e549a21fe8e1b19797c0a5999df83758a303115bba07f5ed08b77dab4840b8c3a8d8aa180c6209c8140996cb4bdbc40584ba9cacac00a8466d70cdef688"
    ["0.13.3/amd64"]="c29aad55166a88d8060a46418bf7001466e8d4068122821433d048be59ab6afb005da8f9c8a59775e56526f296c7c7ef5cd994170f834da4e1c766f6f45a9b59"
    ["0.13.3/arm64"]="721e3a23da38038c75d7f9a0660f7eb3da6f295ac1f611ae029f3735062bad82b2360e01fb7bc1010106f7be43f0d1a897a4e200427eb21b778e1576f307c107"
    ["0.13.2/amd64"]="a3a39f4e013936e7952a791447f4fee4d09921f32dc56303c4e64b1d315285152db7e7c4917b14cdf878c3c1e713836a3c4ccd3ae638863ddf3603baad89c5e1"
    ["0.13.2/arm64"]="269e8dce12e3358e595b43b0a9d202d6b3885c86f57d54736adf511d08994a0f4fe0f546be520430a8f7ecf557a5bdb97d4624ed44028af4ace5370f72509058"
    ["0.13.1/amd64"]="e192d3993829e1f4fcf2adcc846bf103d7824536fca3e05b6953e150910828551c6ade5a3391cb823f38c4eff0b384527f4e2f87e8a0b45f5ae4c0ca3b4b54c4"
    ["0.13.1/arm64"]="5b79e4f1e763d1ee5ac4f5fce30a0b3e4c3879b4f15f49d31fa06fc2532ffb3c1be471db8a2e03872df0ac08b2e9128bd90d454c4e222397c5ea21958807c3ee"
    ["0.13.0/amd64"]="0be138cb76c0d79cf1734add89d83a7eb4843645cad1428392dca8ca25730231df3904a7675aa63c86fe938c7479d607baad941972de06b5dacd74ba4d548ccd"
    ["0.13.0/arm64"]="062b7926ea36ea59947650b355c99266007b6a7e264fba1e4747ccadc6d85b14ca31cfd9df23d323de79e5cac9d150d34c4409b6f05d1a556c16fc889e841756"
    ["0.12.0/amd64"]="73cf247ea780690a5c391f818f3cd3eebc2fabdce081f9d9fe753659b342a3a4cf02e3c27815d9ebf88b1792aa5ec6143b3b9dc40df65ce0b6b9d1ec3c611366"
    ["0.12.0/arm64"]="d799d2be312ec21a7353ad1b520d3254284d13c78e871f09b9714aa8a66fcc301c80f7bb3249cc063d040b0c05ef764cf58fd2ae386a9bff16c976cafd0395f5"
    ["0.11.3/amd64"]="643382d5bdbb5bb9ecb09291965d5eb393b1f912fd50718449e36cd5cd6a4d8b6d1391f18fbb1e74c478562772e1d9bfbdf31d166ca1d3dfa8975ff9ecd66cd9"
    ["0.11.3/arm64"]="e5fa7903dcadcaa82ca1ed8cf783812a0b631657e5585dfddcababfdd3fece3d5cfb9ef2a9ca7e5038b63b4b1be25b10b3b3856c1115c6e97ec36d36510d6d97"
    ["0.11.2/amd64"]="4302e77b554d09eacdd4e7d29f9aac273c2d1d0c1e5f985a6bac9fa4746f8a9088af9a57af37c87a0d47efcf08e3d907e53b5e746a6aee30f34d339f916b8e3d"
    ["0.11.2/arm64"]="d252f18a3a987f6c36376e443671c1eba53ed049957f83473606bc77259018551f7e45ea8e59866773def468e962f6c5b16b5f6becc7faede47b3c88b364fed7"
    ["0.11.1/amd64"]="c34da8239d78d18746fd0920769efd47064e74abeed243d876bf39f039c37bf3d36830f55dbf2aa74736c4f55589b9c5aa2cdf1af0885459c31891545c0b39b7"
    ["0.11.1/arm64"]="37863c41f476998034f1d652d297d0aaaf731e817339517b113ded288248bee60ba14bc9cd105839ee13c4e17f24a2d3219dfb4bcb218cb38db3673bddf30375"
    ["0.11.0/amd64"]="d65021f4a1391976bedf69405b3003a7b50c6121bfd205298c04ccfb4a24e2da9682a23da28396be6bb2e8d06e8c62476a0fff1a78e81796fbe24cdf30a2de48"
    ["0.11.0/arm64"]="699bf1168e2fb5191f6722c480114c794c7279a17f2b47371b0ead8be779ec8af83f787f80ab44db710809bc699511239bb5c1d7f02d8a040f47295bd6d7a390"
    ["0.10.0/amd64"]="d6496856752fc15cfc6201ce3c7ec3a04ab2d8aa28a2f979c4009085291d22164ae949b216ef86cc17b914fe37dfb35e8acb016c609f29cd76d1e08c7931c5e2"
    ["0.10.0/arm64"]="afe04d7389a1741e69438bf072311fda662a4ddd1e6fae3da263588cb41f4edf63d2bd1e3148d36547ee344e247767f50e1140179d91dbc81613642a4fc004d8"
    ["0.9.0/amd64"]="7eb8b05f55d4cf4d407742723b6eb1f0e58f00895bdf925d23f633eee760a258412abccaf24c023e9a9b32c47ed748943b2a8d36bed8b19da42c2d599cfb12f0"
    ["0.9.0/arm64"]="afb7cfc15d4cf442f8906584a1c0450da9cb54b07290ff9663af0e6bdad656ac3ceb1433dbf4d479cf81d4f4f52123f26086d22238c1bdf26ede01b8222c98a3"
    ["0.8.0/amd64"]="4904c8ac6721d09ff57e7e2454183369e368184b598829c56cf4dcea3272899102e941cc0ab796b6c72f929f7d61d7d4239a6488d4a89d4b6259274b0723cdfa"
    ["0.8.0/arm64"]="52fa4fe4f06d9feb013e8a5518f4837b4d09b568cad091e0af57036a893c5e3804ea8166c84fa63b3f35108f8475988558bde5a4f5c557fccdcedaa8a662e4c5"
    ["0.7.3/amd64"]="ca5a3285bb8eb67f1468b919f9afd25d48909e140fdc4ff534d96595f75945762261d065db48278ae2024fdd5f70ec96e3bfaa6239b7b0eb2447dcf8d24003ab"
    ["0.7.3/arm64"]="dc8d83928a39ea60f2925960d06936e10c8272f93546b116ed5eac69fa3490b15ec8940babd71c06b391b76d15116a6ca7ed256f82219dc3d4a17f282bf94c5c"
    ["0.7.2/amd64"]="9a2afdae861833e022bdb38e4b1fdae7936dd512c1b612ee251e5ea1342cf0d5bcfbb8d1238f31776d0606c13fc13c96185ad215f8c1d55e5e51a0811311f3e4"
    ["0.7.2/arm64"]="24074e4d1188f4bae81b4b478751a0d49d6e8dbc0a9242bf77c2205cc6b441a550218b34437555c432e372150061c7cc3b46683a96ecad592033ab5cceed628c"
    ["0.7.1/amd64"]="2ac861e82e021215b842534861459a20398b5b5a1c6e55be2d846c899d047bd2a666338b6ddb9253bea4ca6597a022a833f86aebfe827612324e2ea19b1c516c"
    ["0.7.1/arm64"]="5872f54df526d0b9d96733cd260925529d6dfd8d008e5d105f6e68861cc9d91c702e2515f238b35e11e0dafec085ebeb76d9b50792f6ca3d8e3f125743e6fae1"
    ["0.7.0/amd64"]="6e1f28b54212d8fcb4678ed12a9e092630d16f280eec02f1eb71302a8b652901ceaf87ea6b6fb024c456f23f8507dd43c59e9818360c04db23ab1def7e7b7e34"
    ["0.7.0/arm64"]="071610dc80cdc79a83a21e07cd8d145ed219eceecd4015e02c99a57e7e5072b122ae0f04f9b97a79dcfbdebaf1022d69cc3c9c55aee9fcccd4ba93d75f97aeb1"
    ["0.6.1/amd64"]="453d4c03721d0245e6643f57975fff68141caf12ddd99e53bb0af553e8153970e245d08cb2c9fe7a6a5f14326ea33b0bf17d65e143d53f4e8ac197cd439ee7ab"
    ["0.6.1/arm64"]="182017f6946119621e519d59add8f19f990c7539626824a057c365591ad4e47a3418283b1e56fdd7de9ceaeb90658ff26df334827218ced6186a31b604ca49aa"
    ["0.6.0/amd64"]="7d85948e1d03682fc3572230319d9935db568f688a27aae4cb415268207239d9695e215f8b7b6444a82f4c5ab4a233dd44403051f71d03fdb35a54456ef04380"
    ["0.6.0/arm64"]="0ed3cb88d374ccf6bc1c6e4054706b856d4a13b5b8f79ac1ace84ba375bf6337bbb52d4c1030d8c45123a385fe6ef440a6e179d30d4249089c7c4e8d457b3bb2"
    ["0.5.0/amd64"]="15f14553291437597afed430ff0116fe40bd4ca853b1e9ac4b492ce29fec20573339d44e2adfb465cddd978a8a65d8b583e8534a15d4644927b90db588647356"
    ["0.5.0/arm64"]="e8b81a8f545ae041e0c6ed8fe3aa41c84bce13cfd274beec79aa777df0d346e2519e6d82656fb3b5fd923a0564c63f61fc5ae057dcbd5b79ae75d4fb93e07be1"
    ["0.4.0/amd64"]="bf375af26d209db018b811f2540ffef315bf71495ccf084d5f4cf00a874d46ba02a06c2bb9d8a49aad766beea1002c1fa42fc5101e3cbef350522b4350907946"
    ["0.4.0/arm64"]="16668f69b3bd13db5b2b3c1e00e7f10fb70cbdb618906cf98ab285c9bdd054cb570dbbe74c3f79cec0befc1dce900ceaceacb6cf30a63215c6d5b0af47c14c25"
    ["0.3.3/amd64"]="3286661f73a01396c671c9dfb8882318ab35503628e8075437749478d179ee38d18c7a04676ec59374c05723bbf8ce6057ad92873e98e500220a29d0befb9076"
    ["0.3.3/arm64"]="0756d9ff69ab8a073c7d64af4fd89b4f4d8beab6d16dbd94bcc60cf9e2b98397310c6eae6bac992da0929d6619666ae4ce2134b591e33394e22fdc3c0fdf77b5"
    ["0.3.2/amd64"]="52c0176df8715bdcd8cb26324a11599726cce25195defc37fb4520c123d86b636f059ff15019bccd809b432b77b9b50b6e6b11a112c7e8c3d54af8cc17ccd3fa"
    ["0.3.2/arm64"]="eec39e03f57dd8f10a0ec8b9dc956af6238378608c6fc582609bfa70323bb9848e2fd6f29738478f55b8211f0258709f303906142d63e65e6c5bbfd14f8cd19a"
    ["0.3.1/amd64"]="b9a991345044e1620cf149a51ab70c742e18e6bc1a159b09a915a6149d5c54b3279a65e177384032d049fd87799222dbe2757d9aff5dd73771fb272f515051ef"
    ["0.3.1/arm64"]="cdc89d5513ebd324a9ef81bb53442136625790f60262d04600c92cbd777d69471d14ec309c1dedfc332e502e01e48129aa222e80ece5ca661410deb1e7e4a150"
    ["0.3.0/amd64"]="4362d6511a4e78e4b49113b7ac6c5853bc35e17a0ed04c69859f460add45141e9cb7be536d09968d9cde289ace63cb7ea75afcee2fe520a9b87ffaeebab6872b"
    ["0.3.0/arm64"]="653307ff53cddfa26f842846ed836faf9e97aa4d8a1808ce7558f65b0c7b983ad7485a4ca5cc8c4ec419e38168c2b81d0eaa8a29ef89c0555de387ff6ea0466a"
    ["0.2.2/amd64"]="81b31307e381c4b33fc304bcefca478b3a55b7bf201fc4019f7eaf2665ec470f0bb629242e9cf7a35af5bf3db554a023b733508c872577c12f13e1389ff13731"
    ["0.2.2/arm64"]="b24d11c8b74734298d4f2d1e1924e8f0a5fd3916122cc32fa39b77cccbb55de018d51825a9f0739059705e24447c962955854ba499d1832e274ea34281a9cd77"
    ["0.2.1/amd64"]="324d8db2bb5f6124fce1535d1ec84a7cd08e76965ae4a9a8d440df10cffb09b682135c4e19b591b99679d79251ff4b38764d6895449882f7a3f7225ce91caa3b"
    ["0.2.1/arm64"]="459bce44e4d3dc71a8d1c1ab6bc7ac465145496c21c2e6b28ee146621ddfb59c9747639650476ab325038bd95c14ac6b77be558db94d2f323428343928946ea1"
    ["0.2.0/amd64"]="245d5e632840e410a8119d0affa0db4a0a248aff0522e7a610d03d9e187074f0811406b785754e403c04c96cec325e717ec0711107e2c159d618b52e8fc332b0"
    ["0.2.0/arm64"]="b2a602163a206540db08646a3ee333ad354d7af360a850cc4b115dfc58870e0afe602268ebcf603e163edc17ee622b56ea36b760f15314c5bf4fcc17e13156e8"
    ["0.1.2/amd64"]="2af4fef466c537277bbdba24119eae91e53fb3f886021d0a0c70aea400bf35bbe783f269b8035889ae51ba2781b57e5bcdd1178ca3a524bb34e5f030271ff313"
    ["0.1.2/arm64"]="07953f19f93cc89702430444ac695894e2e1a425925f19783654fa521289a9f7be55b426f0e9ced662cbf9aa5ae0dac51cd930359edc9b631c511242d1cd55b7"
    ["0.1.1/amd64"]="fcc7c70832ceba5d21c35f6088f7f06f0a0426ca0c5878c24cd778828e30f7cfe7b43ec8b2c4a4b4b999d7aa370cc2420cecef2efde8c263379c58e69af0cf55"
    ["0.1.1/arm64"]="e806c948f4e8fd998e8c343ab900166de7af97c84c073b9f8db9429c3add08881710b1f18ece64446ac04162912b62b1391bba968bd21d4fa0b1be399be3924a"
    ["0.1/amd64"]="8cdc9427cb397d00a5dc031cdecb6d8e68f06ce701a29c766a361d00b420995a1e83f8dbe17d8fc9960a7e6545693d8a85d3140b5e4cfc5b8c21decbc7e9b29b"
    ["0.1/arm64"]="d9de01e62d4b2fe1cbaaba7156c59d62459393ed331ab32f17601472a1de2f9fad0fdb745452e702d4101bc8b953e096029382d1770a8fe4bb43120d9911f08f"
)
# <<< checksum table <<<

orb_install_main
