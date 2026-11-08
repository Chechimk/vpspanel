#!/bin/bash
# Update an installed VPSPanel from its git repository. Accounts and settings
# in /etc/vpspanel are kept.
set -uo pipefail

ETC=/etc/vpspanel
[[ $(id -u) -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

url=$(cat "$ETC/source" 2>/dev/null || echo https://github.com/Chechimk/vpspanel.git)
[[ $url =~ ^https://[A-Za-z0-9./_-]+$ ]] || { echo "Refusing to update from an unexpected URL: $url" >&2; exit 1; }
command -v git > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q git > /dev/null \
    || { echo "git is required to update." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading the latest VPSPanel from $url ..."
git clone -q --depth 1 "$url" "$tmp/vpspanel" || { echo "Download failed." >&2; exit 1; }
old=$(awk -F'"' '/^VPSP_VERSION=/ {print $2}' /opt/vpspanel/lib/common.sh 2>/dev/null)
new=$(awk -F'"' '/^VPSP_VERSION=/ {print $2}' "$tmp/vpspanel/lib/common.sh")
echo "Installed: ${old:-unknown}   Available: ${new:-unknown}"
bash "$tmp/vpspanel/install.sh" --update
