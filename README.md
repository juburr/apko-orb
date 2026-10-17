<div align="center">

<img src="assets/logos/apko-orb-512px.png" width="260" alt="apko orb logo: a purple octopus wrapped around a rack of servers under the sea">

<h1>apko orb for CircleCI</h1>

<p><b>Build minimal, distroless, multi-arch container images in CircleCI.<br>No Dockerfile. No Docker daemon. No emulation.</b></p>

[![CircleCI Build Status](https://circleci.com/gh/juburr/apko-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/apko-orb)
[![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/apko-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/apko-orb)
[![Platforms](https://img.shields.io/badge/executors-linux%2Famd64%20%7C%20linux%2Farm64-0a7bbb.svg)](#-commands)
[![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)
[![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

<p>
  <a href="#-quick-start"><b>Quick Start</b></a> ·
  <a href="#-commands"><b>Commands</b></a> ·
  <a href="#-secure-by-design"><b>Security</b></a> ·
  <a href="#-multi-architecture-images"><b>Multi-Arch</b></a> ·
  <a href="#-installing-packages-from-a-local-signed-repository"><b>Local APKs</b></a>
</p>

</div>

---

[apko](https://github.com/chainguard-dev/apko) assembles OCI images straight from APK packages described in a YAML file, so your image holds the packages you list and what they depend on, and nothing else. This unofficial orb drops a verified apko binary into your CircleCI job and builds your images with a single command. Contributions are welcome!

<table>
  <tr>
    <td width="33%" valign="top">
      <h3>🔐 Verified installs</h3>
      In the default <code>strict</code> mode, every apko download is checked against a pinned SHA-512 checksum, and versions without one fail closed.
    </td>
    <td width="33%" valign="top">
      <h3>🦾 amd64 and arm64</h3>
      Runs on Linux x86 and Arm executors, including CircleCI's Arm resource classes. The matching apko release is picked automatically.
    </td>
    <td width="33%" valign="top">
      <h3>🐙 Multi-arch, no emulation</h3>
      Build <code>amd64</code> and <code>arm64</code> images from one executor. No QEMU, no buildx.
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h3>📦 Bring your own APKs</h3>
      Install your melange-built packages from a local repository signed with an ephemeral key.
    </td>
    <td width="33%" valign="top">
      <h3>⚡ Cached</h3>
      The apko release is cached per version and architecture, so repeat runs skip the download.
    </td>
    <td width="33%" valign="top">
      <h3>🙈 No sudo, no telemetry</h3>
      Installs to a user-owned directory and never sends usage data anywhere.
    </td>
  </tr>
</table>

## 🚀 Quick Start

**1. Describe your image** in `apko.yaml`:

```yaml
contents:
  keyring:
    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
  repositories:
    - https://packages.wolfi.dev/os
  packages:
    - ca-certificates-bundle
    - busybox

accounts:
  groups:
    - groupname: nonroot
      gid: 65532
  users:
    - username: nonroot
      uid: 65532
  run-as: nonroot

archs:
  - amd64
  - arm64
```

**2. Add the orb** to `.circleci/config.yml`:

```yaml
version: 2.1

orbs:
  apko: juburr/apko-orb@0.4.0

jobs:
  build-image:
    docker:
      - image: cimg/base:current-22.04
    steps:
      - checkout
      - apko/install
      - apko/build:
          config_path: apko.yaml
          image_uri: ghcr.io/my-org/my-app:latest
          output_path: build/my-app.tar
      - setup_remote_docker
      - run:
          name: Smoke Test Image
          command: |
            docker load --input build/my-app.tar
            docker run --rm ghcr.io/my-org/my-app:latest-amd64 busybox echo "hello from apko"

workflows:
  build:
    jobs:
      - build-image
```

**3. Push.** The job writes `build/my-app.tar`, an OCI image tarball with one image per architecture, then loads it into Docker and runs the `amd64` image. From there, scan it, publish it, or keep it with `store_artifacts`.

> [!TIP]
> String parameters are passed through `circleci env subst`, so they can use environment variables. For example, `image_uri: ghcr.io/my-org/my-app:${CIRCLE_SHA1}` tags each image with its commit.

## 🧰 Commands

### `install`

Installs the apko binary. Run it before any other command.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `version` | string | pinned per orb release | apko version to install, without a leading `v` (e.g. `1.4.6`). |
| `install_path` | string | `/home/circleci/bin` | An existing directory on the `PATH` that doesn't need root access, with no trailing slash. |
| `verify_checksums` | enum | `strict` | `strict` fails when the version has no checksum in the orb's lookup table. `known_versions` verifies listed versions and installs unlisted ones unverified, with a warning. `false` disables verification and is not recommended. |
| `caching` | boolean | `true` | Caches the downloaded apko release, keyed by version and architecture. |

### `build`

Builds an image with `apko build`.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `config_path` | string | *required* | Path to the apko YAML configuration file. |
| `image_uri` | string | *required* | Image and tag of the output image, e.g. `ghcr.io/my-org/my-app:latest`. |
| `output_path` | string | *required* | Where to write the image tarball. Missing parent directories are created. |
| `arch` | string | `""` | Comma-separated architectures passed to `--arch`, e.g. `amd64,arm64` or `host`. Overrides `archs` in the configuration file. |
| `log_level` | enum | `debug` | One of `debug`, `info`, `warn`, `error`, `fatal`, `panic`. |

## 🔐 Secure By Design

- **Least Privilege**: Installs to a user-owned directory by default, with no `sudo` usage anywhere in this orb.
- **Integrity**: Checksum validation of all downloaded binaries using SHA-512. Installation fails closed if the requested version has no checksum in the orb's lookup table; set `verify_checksums` to `known_versions` to opt out.
- **Provenance**: Installs directly from Apko's official [releases page](https://github.com/chainguard-dev/apko/releases/) on GitHub. No third-party websites, domains, or proxies are used.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/).
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer.

<details>
<summary><b>🛂 Info for security teams: network egress for locked-down, self-hosted pipelines</b></summary>
<br>

Allow these hosts if you run a locked-down, self-hosted CircleCI pipeline on-prem:

| Command | Host | Why |
| --- | --- | --- |
| `install` | `github.com` | Download and installation of the apko tool. |
| `install` | `release-assets.githubusercontent.com` | GitHub redirects release downloads from `github.com` to this host. |
| `install` | `objects.githubusercontent.com` | Older redirect target for GitHub release downloads; allow it alongside `release-assets.githubusercontent.com`. |
| `build` | `packages.wolfi.dev` | For Wolfi-based configurations. apko fetches the signing key, the `APKINDEX.tar.gz` index, and the packages, and requests `/os/apk-configuration` for key discovery. |
| `build` | Any other repository or keyring URL in your configuration | Depends on your apko configuration. Local repository and key paths need no network access. |

</details>

## 🐙 Multi-Architecture Images

apko assembles images without running code for the target architecture, so a single executor can build `amd64` and `arm64` images without emulation. List the architectures under `archs` in the apko configuration, or override that list with the `build` command's `arch` parameter (for example `arch: amd64,arm64`, or `arch: host` to build only for the executor's architecture).

- The output tarball contains an OCI image index. `docker load` loads one image per architecture, tagged with an architecture suffix such as `my-image:latest-amd64` and `my-image:latest-arm64`. Single-architecture builds are suffixed too.
- Running an `arm64` image, for example in a smoke test, still requires an `arm64` executor or emulation.

## 📦 Installing Packages From A Local Signed Repository

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

See the [`local_signed_repository`](src/examples/local_signed_repository.yml) usage example for a complete job.

## 🤝 Contributing

Issues and pull requests are welcome. When apko ships a new release, `src/scripts/install_hash.sh -v <version>` prints the SHA-512 checksums to add to the lookup tables in [`install.sh`](src/scripts/install.sh).

Need the logo for a blog post, slide, or your own docs? Transparent PNGs at 64, 128, 256, 512, and 1024 px live in [`assets/logos`](assets/logos).

## 📜 License

Released under the [MIT License](LICENSE).

<div align="center">
  <br>
  <img src="assets/logos/apko-orb-128px.png" width="64" alt="apko orb">
</div>
