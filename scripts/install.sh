#!/usr/bin/env bash
set -euo pipefail

PREFIX="/usr/local"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      if [[ $# -lt 2 ]]; then
        echo "error: --prefix requires a value" >&2
        exit 2
      fi
      PREFIX="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/install.sh [--prefix <path>] [--skip-build]

Builds screencommander in release mode and installs it to <prefix>/bin.

Defaults:
  prefix: /usr/local
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  swift build -c release
fi

BIN_PATH="$(swift build -c release --show-bin-path)/screencommander"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at '$BIN_PATH'" >&2
  exit 1
fi

BIN_DIR="$PREFIX/bin"
TARGET_PATH="$BIN_DIR/screencommander"

if mkdir -p "$BIN_DIR" 2>/dev/null && [[ -w "$BIN_DIR" ]]; then
  install -m 0755 "$BIN_PATH" "$TARGET_PATH"
else
  echo "Installing to '$TARGET_PATH' requires elevated privileges."
  sudo mkdir -p "$BIN_DIR"
  sudo install -m 0755 "$BIN_PATH" "$TARGET_PATH"
fi

echo "Installed: $TARGET_PATH"
echo "Run: screencommander --help"
