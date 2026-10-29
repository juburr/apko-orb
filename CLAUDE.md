# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, for apko, Chainguard's tool that assembles distroless OCI images from the APK packages listed in a YAML file, without a Dockerfile, a Docker daemon or emulation. The orb installs a checksum-verified apko and wraps the apko subcommands a pipeline needs: `build`, `publish`, `lock` and `login`.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh src/tests/*.sh

# Tests (offline)
for t in src/tests/actions_test.sh src/tests/commands_test.sh src/tests/install_test.sh src/tests/env-subst.sh src/tests/shell_conventions_test.sh; do bash "$t" || break; done

# Generate SHA-512 checksums (linux amd64 + arm64) for a new apko version
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - `install`, and one command per apko subcommand: `build`, `publish`, `lock`, `login`
- `scripts/` - Shell implementations, included with `<< include(scripts/...) >>`
- `scripts/lib/apko.sh` - Helpers shared by `build.sh`, `publish.sh`, `lock.sh` and `login.sh`. Each of those commands passes it to its step as `SCRIPT_APKO_LIB: << include(scripts/lib/apko.sh) >>`, and the script `eval`s it after checking it is set. It only defines functions and has no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `tests/` - The offline tests, the scripts CI uses to check real builds, and the apko and melange configurations they build. orb pack ignores the directory.

### Key Implementation Details

**`scripts/install.sh`**: Installs the linux amd64 or arm64 apko build (from `uname -m`) from GitHub releases with SHA-512 checksum verification. It follows the layout every juburr orb's install.sh shares: a tool definition, a shared install logic block that must stay identical across the orbs, and a checksum table keyed `"<version>/<arch>"`. Three verification modes: `false`, `known_versions`, `strict` (default, fails before downloading an unlisted version). `tests/install_test.sh` is the install contract test shared by the orbs, and `scripts/cache_key.sh` is shared too; never edit the shared parts in one orb only.

**`scripts/lib/apko.sh`**:
- `apko_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (GitHub Actions, local runs).
- `apko_list` splits a list on commas, spaces and newlines with `read`, so an item such as `*.pub` is never globbed. `apko_flags FLAG VALUE` turns it into repeated `FLAG=ITEM` arguments.
- `apko_csv`: apko's list flags are cobra string slices, which read each value as a CSV record, so an item with a comma or a double quote is passed in double quotes, its quotes doubled. Annotations (one `key:value` per line) need it most.
- `apko_arch_args`: empty `arch` leaves `--arch` out (the configuration's `archs`, or every architecture); otherwise the listed names, joined with commas. apko also takes `host` and `all`.
- `apko_image_options` turns the parameters `build` and `publish` share (`lockfile`, `build_date`, `vcs`, `sbom`, `sbom_path`, `keyring_append`, `repository_append`, `package_append`, `annotations`, `cache_dir`, `offline`) into flags, reading their `PARAM_` variables itself. A parameter at its default adds no flag, so older apko releases see the arguments they did before the parameter existed.
- `split_shell_words` and `apko_words` split `extra_args` the way container-ops-orb, oras-orb, crane-orb and melange-orb do: quotes keep spaces, and a `$(...)`, backtick or shell operator outside quotes fails the step. `apko_refuse` refuses options a command sets itself.
- `apko_run` prints the command line, quoted with `printf %q`, then runs it. `apko_export` writes `$BASH_ENV` exports.

Every apko call writes flags as `--flag=value` and ends its options with `--`, so a value that starts with `-` is never read as a flag.

**`build.sh`**: `apko build --log-level=L [options] -- CONFIG IMAGE OUTPUT_PATH`, after creating `output_path`'s directory. With `sbom_path` empty, apko writes the SBOMs (`sbom-<arch>.spdx.json`, `sbom-index.spdx.json`) to the working directory. The missing-configuration error, `ERROR: Configuration YAML does not exist at: <config>`, is documented in the README's upgrade notes, so all three commands keep it.

**`publish.sh`**: `apko publish ... --image-refs=<mktemp file> -- CONFIG TAG...`. apko pushes each architecture's image to the first tag's repository by digest, then the index under every tag, and writes the per-architecture references and then the index's to the `--image-refs` file. The script exports the last line's digest and reference (`digest_env_var`, `digest_ref_env_var`), checked against `<repository>@sha256:<64 hex>`, and copies the file to `image_refs` when set. `--image-refs` and `--local` in `extra_args` are refused. apko publish keeps SBOMs only with `--sbom-path`. Credentials come from `~/.docker/config.json` and, for `ghcr.io`, `GITHUB_TOKEN` (go-containerregistry's GitHub keychain).

**`lock.sh`**: `apko lock --output=OUTPUT -- CONFIG`, always passing `--output` (apko's own default, the configuration's path with `.lock.json` in place of its extension, when `output` is empty) so it can report the file. apko marks `lock` as hidden.

**`login.sh`**: `apko login` is crane's `auth login`, so it mirrors crane-orb's login: the credentials come from the variables `username` and `password` name, xtrace is turned off first, the password goes to `--password-stdin` with `printf`, and both must be set (crane 0.14.0 and later reject an entry without a username). apko doesn't contact the registry at login.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT` (plus `SCRIPT_APKO_LIB=<lib>` for `build`, `publish`, `lock` and `login`). Inputs never appear inside a `run:` script. `install` restores and saves `actions/cache` with the command's key ingredients. `login`'s credentials come from variables the workflow sets in the `env` of the step that uses it. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. Keep the actions in sync with the command YAML by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number: every input is a string. The action descriptions leave out "Environment variables are expanded", since there is no CircleCI CLI on GitHub's runners. `tests/actions_test.sh` checks all of this.

### Tests

- `tests/commands_test.sh` runs `build.sh`, `publish.sh`, `lock.sh` and `login.sh` against a stand-in apko that records its arguments and stdin, writes the `--image-refs` and `--output` files, and exits as told. It checks every argument list, defaults that add no flag, list splitting without globbing, annotation quoting, `extra_args` and the refused options, publish's exports and failures, lock's default path, the password on stdin and never in the log (xtrace on included), and each input check failing before apko runs. It runs with a circleci stand-in (value on stdin, `$ORB_TEST_VAR` expanded) and, for a few cases, with no circleci on the PATH. It passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `tests/verify_build_options.sh` checks the lock, cache and offline builds (annotations of the index and every image, creation time, SBOM locations, the locked versions against the SBOM), and `tests/verify_publish.sh` what publish pushed to a local registry. Both CI configurations run them.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install`, `test-actions`, `test-commands`, orb-tools lint, pack and review (`orb_name: apko`), shellcheck.
- `.circleci/test-deploy.yml` - `command-test` (build, load and run a gdal image), `multi-arch-test`, `build-options-test` (lock, a build from the lock file into a cache, then an offline build with annotations, a build date, `vcs: false` and `sbom_path`), `publish-test` (login and publish a two-architecture image to a `registry:2` with htpasswd auth on a machine executor), `local-repository-test` (melange-orb's `keygen` and `build` commands make a signed package in a local repository, which apko installs), `command-test-arm64`, `env-subst-test`, `shell-conventions-test`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The same with the actions on GitHub's runners: `offline-tests`, `install`, `install-from-cache`, `build`, `multi-arch`, `build-options`, `publish`, `local-repository`.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `apko_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env-subst.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `login.sh` runs `set +o xtrace` with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_APKO_LIB}"`). Secrets never go on a command line: the registry password reaches apko on stdin.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script.

## Naming

Command names are apko's own subcommands (`build`, `publish`, `lock`, `login`). Parameters that map onto one apko flag take its long name in snake_case (`lockfile`, `build_date`, `vcs`, `sbom`, `sbom_path`, `keyring_append`, `repository_append`, `package_append`, `annotations`, `cache_dir`, `offline`, `image_refs`, `output`); positional arguments take apko's names for them (`config`, `tags`), except `build`'s `<tag>`, which has always been `image`. Plumbing matches the other juburr orbs: credentials are `env_var_name` parameters named `username` and `password` (defaults `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`), variables a command writes are `<thing>_env_var`, pass-through arguments are `extra_args`, and lists take commas, spaces or newlines.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh src/tests/*.sh` and `yamllint .`
- Run every offline test, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`
- For changes to `build`, `publish` or `lock`, run them with the real apko, as `build-options-test` and `publish-test` do
