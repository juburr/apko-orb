#!/bin/bash

set -e

if [[ -f apko.tar.gz ]]; then
    tar zxvf apko.tar.gz "apko_${PARAM_VERSION}_linux_amd64/apko" --strip 1
fi
if [[ ! -f apko ]]; then
    wget "https://github.com/chainguard-dev/apko/releases/download/v${PARAM_VERSION}/apko_${PARAM_VERSION}_linux_amd64.tar.gz" -O apko.tar.gz
    tar zxvf apko.tar.gz "apko_${PARAM_VERSION}_linux_amd64/apko" --strip 1
fi
sudo mv apko /usr/local/bin/apko
sudo chmod +x /usr/local/bin/apko