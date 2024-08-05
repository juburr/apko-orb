#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Check if the apko tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f apko.tar.gz ]]; then
    tar zxvf apko.tar.gz "apko_${VERSION}_linux_amd64/apko" --strip 1
fi

# If there was no cache hit, go ahead and re-download the binary.
if [[ ! -f apko ]]; then
    wget "https://github.com/chainguard-dev/apko/releases/download/v${VERSION}/apko_${VERSION}_linux_amd64.tar.gz" -O apko.tar.gz
    tar zxvf apko.tar.gz "apko_${VERSION}_linux_amd64/apko" --strip 1
fi

# An apko binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. Move it to an appropriate bin directory and mark it
# as executable. If your pipeline throws an error here, you may want to choose an
# INSTALL_PATH that doesn't require sudo access, so this orb can avoid any root actions.
mv apko "${INSTALL_PATH}/apko"
chmod +x "${INSTALL_PATH}/apko"