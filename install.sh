#!/usr/bin/env bash
# Links bin/notifyq into ~/.local/bin so it can be run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${NOTIFYQ_BIN_DIR:-$HOME/.local/bin}"

if ! command -v lua >/dev/null 2>&1; then
  echo "lua not found in PATH (brew install lua)" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
chmod +x "$ROOT/bin/notifyq"
ln -sfn "$ROOT/bin/notifyq" "$TARGET_DIR/notifyq"
echo "Linked $TARGET_DIR/notifyq -> $ROOT/bin/notifyq"

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "Note: $TARGET_DIR is not in your PATH" ;;
esac

echo "Run 'notifyq daemon install' to enable scheduled notifications."
