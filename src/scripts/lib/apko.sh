#!/bin/bash

# Shared helpers for the apko-orb commands that run apko. Each command passes
# this file to its step as SCRIPT_APKO_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions.

# apko_subst VALUE: prints VALUE with environment variables expanded. The
# value is piped in on stdin: passed as an argument, a value starting with "-"
# would be parsed as a flag. Without the CircleCI CLI (GitHub Actions, local
# runs), the value is used as is.
apko_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# apko_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, where a range
# such as [a-z] matches only ASCII letters.
apko_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# apko_bool NAME VALUE: prints true or false. CircleCI passes boolean
# parameters as 1 or 0; actions and local callers use true or false.
apko_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# apko_require: stops the step unless apko is on the PATH.
apko_require() {
    if ! command -v apko > /dev/null 2>&1; then
        echo "ERROR: apko is not on the PATH. Run the install command in an earlier step." >&2
        exit 1
    fi
}

# apko_log_level VALUE: stops the step unless VALUE is one of apko's log
# levels. CircleCI checks the commands' log_level enum before the step runs;
# the GitHub Actions pass any string.
apko_log_level() {
    case "$1" in
        debug | info | warn | error | fatal | panic) ;;
        *)
            echo "ERROR: log_level must be debug, info, warn, error, fatal or panic, not '${1}'." >&2
            exit 1
            ;;
    esac
}

# apko_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
apko_env_var_name() {
    if ! apko_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# apko_list VALUE: sets APKO_LIST to the items of VALUE, separated by commas,
# spaces or newlines. Empty items are dropped, and nothing is expanded: an
# item such as *.pub stays as it is.
apko_list() {
    local item
    local -a items=()
    APKO_LIST=()
    IFS=$', \t\n' read -r -d '' -a items <<< "$1" || true
    for item in ${items[@]+"${items[@]}"}; do
        if [[ -n "${item}" ]]; then
            APKO_LIST+=("${item}")
        fi
    done
}

# apko_csv VALUE: prints VALUE as one item of a flag apko splits on commas
# (cobra's string slices, which read each value as a CSV record): as it is,
# or, when it has a comma or a double quote, in double quotes with its
# double quotes doubled.
apko_csv() {
    local value=$1
    if [[ "${value}" == *[,\"]* ]]; then
        value=${value//\"/\"\"}
        printf '"%s"\n' "${value}"
    else
        printf '%s\n' "${value}"
    fi
}

# apko_flags FLAG VALUE: sets APKO_FLAGS to FLAG=ITEM for each item of the
# list VALUE (see apko_list), so an empty list adds nothing.
apko_flags() {
    local item
    apko_list "$2"
    APKO_FLAGS=()
    for item in ${APKO_LIST[@]+"${APKO_LIST[@]}"}; do
        APKO_FLAGS+=("${1}=$(apko_csv "${item}")")
    done
}

# apko_arch_args VALUE: sets APKO_ARCH_ARGS to apko's --arch flag for the arch
# parameter: nothing when it is empty, so the configuration file's archs
# apply (or every architecture, without them), else the architectures it
# lists, separated by commas, spaces or newlines, such as amd64,arm64 or
# host.
apko_arch_args() {
    local item joined=""
    APKO_ARCH_ARGS=()
    apko_list "$1"
    for item in ${APKO_LIST[@]+"${APKO_LIST[@]}"}; do
        if ! apko_match "${item}" '^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?$'; then
            echo "ERROR: arch must list architectures separated by commas, such as amd64,arm64, or host; '${item}' is not one." >&2
            exit 1
        fi
        joined+=${joined:+,}${item}
    done
    if [[ -n "${joined}" ]]; then
        # shellcheck disable=SC2034 # read by the script that evals this file
        APKO_ARCH_ARGS=("--arch=${joined}")
    fi
}

# apko_image_options: sets APKO_IMAGE_OPTIONS to the flags that build and
# publish share, from the PARAM_ variables both commands set: lockfile,
# build_date, vcs, sbom, sbom_path, keyring_append, repository_append,
# package_append, annotations, cache_dir and offline. A parameter left at
# its default adds no flag, so apko's own default applies, and releases that
# predate a flag still work. sbom_path is created when it is missing.
apko_image_options() {
    local lockfile build_date vcs sbom sbom_path keyring repositories packages annotations cache_dir offline line
    lockfile=$(apko_subst "${PARAM_LOCKFILE}")
    build_date=$(apko_subst "${PARAM_BUILD_DATE}")
    vcs=$(apko_bool vcs "${PARAM_VCS}")
    sbom=$(apko_bool sbom "${PARAM_SBOM}")
    sbom_path=$(apko_subst "${PARAM_SBOM_PATH}")
    keyring=$(apko_subst "${PARAM_KEYRING_APPEND}")
    repositories=$(apko_subst "${PARAM_REPOSITORY_APPEND}")
    packages=$(apko_subst "${PARAM_PACKAGE_APPEND}")
    annotations=$(apko_subst "${PARAM_ANNOTATIONS}")
    cache_dir=$(apko_subst "${PARAM_CACHE_DIR}")
    offline=$(apko_bool offline "${PARAM_OFFLINE}")
    APKO_IMAGE_OPTIONS=()

    if [[ -n "${lockfile}" ]]; then
        if [[ ! -f "${lockfile}" ]]; then
            echo "ERROR: The lock file ${lockfile}, which lockfile names, does not exist. The lock command writes one." >&2
            exit 1
        fi
        APKO_IMAGE_OPTIONS+=("--lockfile=${lockfile}")
    fi
    if [[ -n "${build_date}" ]]; then
        if ! apko_match "${build_date}" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'; then
            echo "ERROR: build_date must be an RFC 3339 date and time, such as 2025-01-31T12:00:00Z, not '${build_date}'." >&2
            exit 1
        fi
        APKO_IMAGE_OPTIONS+=("--build-date=${build_date}")
    fi
    if [[ "${vcs}" == false ]]; then
        APKO_IMAGE_OPTIONS+=(--vcs=false)
    fi
    if [[ "${sbom}" == false ]]; then
        APKO_IMAGE_OPTIONS+=(--sbom=false)
    elif [[ -n "${sbom_path}" ]]; then
        mkdir -p -- "${sbom_path}"
        APKO_IMAGE_OPTIONS+=("--sbom-path=${sbom_path}")
    fi

    apko_flags --keyring-append "${keyring}"
    APKO_IMAGE_OPTIONS+=(${APKO_FLAGS[@]+"${APKO_FLAGS[@]}"})
    apko_flags --repository-append "${repositories}"
    APKO_IMAGE_OPTIONS+=(${APKO_FLAGS[@]+"${APKO_FLAGS[@]}"})
    apko_flags --package-append "${packages}"
    APKO_IMAGE_OPTIONS+=(${APKO_FLAGS[@]+"${APKO_FLAGS[@]}"})

    # One key:value per line, since values can hold commas and spaces.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%$'\r'}
        if [[ -z "${line//[[:space:]]/}" ]]; then
            continue
        fi
        if ! apko_match "${line}" '^[a-z0-9.-]+:.'; then
            echo "ERROR: Each line of annotations must be key:value, with a key of lowercase letters, digits, dots and dashes, such as org.opencontainers.image.source:https://github.com/myorg/myapp; '${line}' is not." >&2
            exit 1
        fi
        APKO_IMAGE_OPTIONS+=("--annotations=$(apko_csv "${line}")")
    done <<< "${annotations}"

    if [[ -n "${cache_dir}" ]]; then
        APKO_IMAGE_OPTIONS+=("--cache-dir=${cache_dir}")
    fi
    if [[ "${offline}" == true ]]; then
        APKO_IMAGE_OPTIONS+=(--offline)
    fi
}

# apko_refuse PARAMETER OPTION...: stops the step if APKO_WORDS, the words of
# PARAMETER, hold one of the long OPTIONs, alone or as OPTION=VALUE: the
# command sets it itself, or reads what it would change.
apko_refuse() {
    local parameter=$1 word option
    shift
    for word in ${APKO_WORDS[@]+"${APKO_WORDS[@]}"}; do
        for option in "$@"; do
            if [[ "${word}" == "${option}" || "${word}" == "${option}="* ]]; then
                echo "ERROR: ${parameter} must not hold ${option}: the command sets it itself." >&2
                exit 1
            fi
        done
    done
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# apko_words PARAMETER VALUE: sets APKO_WORDS to VALUE split like shell
# words (see split_shell_words), naming PARAMETER in any error. Nothing in it
# is expanded or executed: a $(...) or backtick that reached a parameter
# through an environment variable (a branch name, a commit message) reaches
# apko as text inside quotes, and fails the step outside them.
apko_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to apko as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to apko as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    APKO_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# apko_export NAME VALUE: exports NAME=VALUE to later steps through
# $BASH_ENV, quoted so that no value can break or inject into them.
apko_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# apko_run ARG...: prints the apko command line, shell-quoted, then runs it.
apko_run() {
    local quoted
    quoted=$(printf ' %q' "$@")
    echo "Running:${quoted}"
    "$@"
}
