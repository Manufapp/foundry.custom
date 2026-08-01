#!/usr/bin/env bash
# Single-command bootstrap for a fresh on-prem/customer server - downloads foundry.custom
# (no git needed, works against a public repo with a plain unauthenticated curl) and
# extracts it into ./foundry.custom.
#
# Usage (once the repo is public):
#   curl -fsSL https://raw.githubusercontent.com/Manufapp/foundry.custom/dev/install.sh | bash
#
# Override the branch/tag or the target directory:
#   REF=v1.2.0 DEST=/opt/foundry.custom \
#     curl -fsSL https://raw.githubusercontent.com/Manufapp/foundry.custom/dev/install.sh | bash

set -euo pipefail

REPO="Manufapp/foundry.custom"
# dev is this repo's actual default/active branch (not main) - see README.
REF="${REF:-dev}"
DEST="${DEST:-foundry.custom}"

if [ -e "$DEST" ]; then
  echo "'$DEST' already exists - remove it or set DEST=<other-dir> first." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  echo "curl and tar are both required." >&2
  exit 1
fi

echo "Downloading ${REPO}@${REF} into ./${DEST} ..."
mkdir -p "$DEST"
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz" \
  | tar xz -C "$DEST" --strip-components=1

echo
echo "Done. Next:"
echo "  cd $DEST"
echo "  cp .env.server.example .env.server   # fill in real values"
echo "  ./manufapp.sh setup"
echo "  IMAGE_TAG_FE=<fe_tag> IMAGE_TAG_BE=<be_tag> ./manufapp.sh start"
