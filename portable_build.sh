#!/usr/bin/env bash

set -e

curl -L https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-$(uname -m) > ./nix-portable
chmod +x ./nix-portable

./nix-portable nix build
./nix-portable nix-shell -p bash --run "cp -rL result public"
