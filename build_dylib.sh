#!/usr/bin/env bash
# Compatibility entry point. macOS distribution now uses one XCFramework only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/build_shared_lib_macos.sh" "$@"
