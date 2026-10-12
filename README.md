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
  - `github.com`: For download and installation of the Apko tool.

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
