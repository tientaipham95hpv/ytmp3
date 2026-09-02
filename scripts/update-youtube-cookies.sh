#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COOKIE_DEST="$PROJECT_DIR/secrets/youtube-cookies.txt"
TEST_URL="${YOUTUBE_TEST_URL:-https://youtu.be/PjZxlhMwWZk}"

usage() {
  echo "Usage: $0 /path/to/cookies.txt" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
SOURCE_FILE="$1"
[[ -f "$SOURCE_FILE" && -s "$SOURCE_FILE" ]] || {
  echo "Cookie file is missing or empty: $SOURCE_FILE" >&2
  exit 1
}

first_line="$(head -n 1 "$SOURCE_FILE" | tr -d '\r')"
[[ "$first_line" == "# Netscape HTTP Cookie File" || "$first_line" == "# HTTP Cookie File" ]] || {
  echo "Invalid cookie file: expected Netscape cookie format" >&2
  exit 1
}

awk -F '\t' '
  /^#/ { next }
  NF >= 7 && $1 ~ /(^|\.)youtube\.com$/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$SOURCE_FILE" || {
  echo "Invalid cookie file: no youtube.com cookie rows found" >&2
  exit 1
}

mkdir -p "$PROJECT_DIR/secrets"
TEMP_FILE="$(mktemp "$PROJECT_DIR/secrets/.youtube-cookies.XXXXXX")"
BACKUP_FILE=""
trap 'rm -f "$TEMP_FILE"' EXIT
install -m 600 "$SOURCE_FILE" "$TEMP_FILE"

if [[ -f "$COOKIE_DEST" ]]; then
  BACKUP_FILE="$PROJECT_DIR/secrets/youtube-cookies.backup"
  install -m 600 "$COOKIE_DEST" "$BACKUP_FILE"
fi

mv -f "$TEMP_FILE" "$COOKIE_DEST"
chmod 600 "$COOKIE_DEST"

if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" restart backend >/dev/null; then
  [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]] && mv -f "$BACKUP_FILE" "$COOKIE_DEST"
  echo "Backend restart failed; previous cookie restored" >&2
  exit 1
fi

for _ in {1..20}; do
  if curl -fsS --max-time 5 http://127.0.0.1:18080/health >/dev/null; then
    break
  fi
  sleep 1
done

response_file="$(mktemp)"
trap 'rm -f "$TEMP_FILE" "$response_file"' EXIT
http_code="$(curl -sS --max-time 120 -o "$response_file" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data "{\"url\":\"$TEST_URL\"}" \
  http://127.0.0.1:18080/api/media/info || true)"

if [[ "$http_code" != "200" ]]; then
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    mv -f "$BACKUP_FILE" "$COOKIE_DEST"
    chmod 600 "$COOKIE_DEST"
    docker compose -f "$PROJECT_DIR/docker-compose.yml" restart backend >/dev/null
  fi
  echo "New cookie failed the YouTube check (HTTP $http_code); previous cookie restored" >&2
  sed -n '1,5p' "$response_file" >&2
  exit 1
fi

rm -f "$BACKUP_FILE"
echo "YouTube cookies updated and verified successfully"
