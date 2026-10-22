#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' 'Missing XcodeGen. On macOS, install it with: brew install xcodegen' >&2
  exit 1
fi
cd "$PROJECT_ROOT"
xcodegen generate --spec "$PROJECT_ROOT/project.yml"
