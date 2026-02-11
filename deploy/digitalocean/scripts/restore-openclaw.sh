#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <backup-file.tar.gz> [target-dir]" >&2
  exit 1
fi

ARCHIVE="$1"
TARGET_DIR="${2:-/opt/openclaw}"

if [ ! -f "${ARCHIVE}" ]; then
  echo "Backup archive not found: ${ARCHIVE}" >&2
  exit 1
fi

mkdir -p "${TARGET_DIR}"

if [ -f "${ARCHIVE}.sha256" ]; then
  (cd "$(dirname "${ARCHIVE}")" && sha256sum -c "$(basename "${ARCHIVE}").sha256")
fi

tar -C "${TARGET_DIR}" -xzf "${ARCHIVE}"
echo "Restore complete to ${TARGET_DIR}"
