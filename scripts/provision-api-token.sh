#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKEN_FILE="$PROJECT_DIR/secrets/api-access-token.txt"

mkdir -p "$PROJECT_DIR/secrets"
if [[ ! -s "$TOKEN_FILE" ]]; then
  umask 077
  openssl rand -hex 32 > "$TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"
echo "API access token is provisioned at $TOKEN_FILE"
