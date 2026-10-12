<div align="center">
  <img align="center" width="320" src="assets/logos/apko-orb-logo.png" alt="Apko Orb">
  <h1>CircleCI Apko Orb</h1>
  <i>An orb for simplifying Apko installation and use within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/apko-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/apko-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/apko-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/apko-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/apko-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an unofficial Apko orb used for installing Apko in your CircleCI pipeline to build distroless container images. Contributions are welcome!

The `install` command supports Linux `amd64` and `arm64` executors, including CircleCI's Arm resource classes. The matching Apko release is selected automatically.

## Features
### **Secure By Design**
- **Least Privilege**: Installs to a user-owned directory by default, with no `sudo` usage anywhere in this orb.
- **Integrity**: Checksum validation of all downloaded binaries using SHA-512. Installation fails closed if the requested version has no checksum in the orb's lookup table; set `verify_checksums` to `known_versions` to opt out.
- **Provenance**: Installs directly from Apko's official [releases page](https://github.com/chainguard-dev/apko/releases/) on GitHub. No third-party websites, domains, or proxies are used.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/).
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer.

Info for security teams:
- Required external access to allow, if running a locked down, self-hosted CircleCI pipeline on-prem:
  - `install` command:
    - `github.com`: For download and installation of the Apko tool.
    - `release-assets.githubusercontent.com`: GitHub redirects release downloads from `github.com` to this host.
    - `objects.githubusercontent.com`: Older redirect target for GitHub release downloads; allow it alongside `release-assets.githubusercontent.com`.
  - `build` command, depending on the repositories and keyrings in your apko configuration:
    - `packages.wolfi.dev`: For Wolfi-based configurations. Apko fetches the signing key, the `APKINDEX.tar.gz` index, and the packages, and requests `/os/apk-configuration` for key discovery.
    - Any other repository or keyring URL in your configuration. Local repository and key paths need no network access.

## Installing Packages From A Local Signed Repository
The `build` command can install your own melange-built APKs from a build-local repository signed with an ephemeral key (`melange keygen`). List the repository and public key in the apko configuration as paths relative to the job's working directory, and pin local packages with a repository tag:

```yaml
contents:
  keyring:
    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
    - ./melange.rsa.pub
  repositories:
    - https://packages.wolfi.dev/os
    - '@local ./packages'
  packages:
    - my-app@local
```

- apko refuses a repository index that is not signed by a key in the keyring, so the ephemeral public key must be listed.
- Without the `@local` pin, apko installs the highest version available in any repository, so a same-named public package could replace yours.
- Every architecture in `archs` needs a matching directory in the local repository (for example `packages/x86_64` and `packages/aarch64`).

See the `local_signed_repository` usage example for a complete job.

## Multi-Architecture Images
apko assembles images without running code for the target architecture, so a single executor can build `amd64` and `arm64` images without emulation. List the architectures under `archs` in the apko configuration, or override that list with the `build` command's `arch` parameter (for example `arch: amd64,arm64`, or `arch: host` to build only for the executor's architecture).

- The output tarball contains an OCI image index. `docker load` loads one image per architecture, tagged with an architecture suffix such as `my-image:latest-amd64` and `my-image:latest-arm64`. Single-architecture builds are suffixed too.
- Running an `arm64` image, for example in a smoke test, still requires an `arm64` executor or emulation.
