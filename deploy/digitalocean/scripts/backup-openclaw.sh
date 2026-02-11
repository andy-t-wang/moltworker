#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${OPENCLAW_DATA_ROOT:-/opt/openclaw}"
BACKUP_ROOT="${OPENCLAW_BACKUP_ROOT:-/opt/openclaw-backups}"
KEEP_LOCAL="${OPENCLAW_BACKUP_KEEP_LOCAL:-14}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${BACKUP_ROOT}/openclaw-${TS}.tar.gz"

mkdir -p "${BACKUP_ROOT}"

if [ ! -d "${DATA_ROOT}" ]; then
  echo "Data root not found: ${DATA_ROOT}" >&2
  exit 1
fi

tar -C "${DATA_ROOT}" -czf "${ARCHIVE}" .
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"

echo "Created backup: ${ARCHIVE}"

# Optional off-site upload to DigitalOcean Spaces using AWS CLI.
# Required env:
#   DO_SPACES_REGION (e.g. nyc3)
#   DO_SPACES_BUCKET
# Optional env:
#   DO_SPACES_PREFIX (default: openclaw)
if [ -n "${DO_SPACES_REGION:-}" ] && [ -n "${DO_SPACES_BUCKET:-}" ]; then
  PREFIX="${DO_SPACES_PREFIX:-openclaw}"
  ENDPOINT="https://${DO_SPACES_REGION}.digitaloceanspaces.com"
  KEY="${PREFIX}/$(basename "${ARCHIVE}")"
  SUM_KEY="${KEY}.sha256"

  if command -v aws >/dev/null 2>&1; then
    aws --endpoint-url "${ENDPOINT}" s3 cp "${ARCHIVE}" "s3://${DO_SPACES_BUCKET}/${KEY}"
    aws --endpoint-url "${ENDPOINT}" s3 cp "${ARCHIVE}.sha256" "s3://${DO_SPACES_BUCKET}/${SUM_KEY}"
    echo "Uploaded to spaces: s3://${DO_SPACES_BUCKET}/${KEY}"
  else
    echo "aws CLI not installed, skipping Spaces upload" >&2
  fi
fi

find "${BACKUP_ROOT}" -type f -name 'openclaw-*.tar.gz' -mtime +"${KEEP_LOCAL}" -delete
find "${BACKUP_ROOT}" -type f -name 'openclaw-*.tar.gz.sha256' -mtime +"${KEEP_LOCAL}" -delete
