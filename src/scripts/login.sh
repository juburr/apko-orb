#!/bin/bash
#
# Stores registry credentials for the login command, with apko login (crane's
# auth login, which apko includes). It writes them where Docker does
# (~/.docker/config.json), where apko publish, docker and crane read them.
# apko does not contact the registry here, so wrong credentials only fail the
# first command that uses them.

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the password.
set +o xtrace

if [[ -z "${SCRIPT_APKO_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_APKO_LIB is not set. The command passes the orb's lib/apko.sh in it." >&2
    exit 1
fi
eval "${SCRIPT_APKO_LIB}"

REGISTRY=$(apko_subst "${PARAM_REGISTRY}")
apko_env_var_name username "${PARAM_USERNAME}"
apko_env_var_name password "${PARAM_PASSWORD}"
USERNAME=${!PARAM_USERNAME:-}
PASSWORD=${!PARAM_PASSWORD:-}

# Removes the credentials from this shell when the step ends, whatever its
# outcome.
cleanup_secrets() {
    unset PASSWORD USERNAME
}
trap cleanup_secrets EXIT

if [[ -z "${REGISTRY}" ]]; then
    echo "ERROR: registry is required, such as ghcr.io or localhost:5000." >&2
    exit 1
fi
if [[ "${REGISTRY}" == *://* || "${REGISTRY}" == */* || "${REGISTRY}" == -* ]]; then
    echo "ERROR: registry must be a host with an optional port, such as ghcr.io or localhost:5000, not '${REGISTRY}'." >&2
    exit 1
fi
# Without a username, crane's login stores an entry that crane 0.14.0 and
# later, and docker, reject when they read the Docker config, which breaks
# every later command for every registry.
if [[ -z "${USERNAME}" ]]; then
    echo "ERROR: The ${PARAM_USERNAME} environment variable, which username names, is empty or unset." >&2
    echo "  Set it from a secret (a CircleCI context or project variable, or a GitHub Actions secret in the step's env)," >&2
    echo "  or pass the name of another variable as username." >&2
    exit 1
fi
if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: The ${PARAM_PASSWORD} environment variable, which password names, is empty or unset." >&2
    echo "  Set it from a secret (a CircleCI context or project variable, or a GitHub Actions secret in the step's env)," >&2
    echo "  or pass the name of another variable as password." >&2
    exit 1
fi
apko_require

echo "Storing credentials for ${REGISTRY} with apko login..."
echo "  Username: from ${PARAM_USERNAME}"
echo "  Password: from ${PARAM_PASSWORD}"

# The password goes on stdin, never on the command line. printf, not echo:
# echo would take a password of -n or -e as its own option.
printf '%s\n' "${PASSWORD}" | apko login "--username=${USERNAME}" --password-stdin -- "${REGISTRY}"
