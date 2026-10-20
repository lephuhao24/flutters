#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
scratch="$(mktemp -d /private/tmp/fvm-gui-smoke-XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
cd "$repo_dir"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -module-cache-path "$scratch/module-cache" \
  fvm_gui/Core/CLI/CLIExecutor.swift fvm_gui/Core/CLI/CLIResult.swift \
  fvm_gui/Core/CLI/ExecutableLocator.swift fvm_gui/Core/Models/*.swift \
  fvm_gui/Core/Errors/*.swift fvm_gui/Core/FileSystem/*.swift fvm_gui/Services/FVMParser.swift \
  fvm_gui/Services/FVMCLIService.swift \
  scripts/SmokeTest.swift -o "$scratch/smoke"
case "${1:---read-only}" in
  --read-only) "$scratch/smoke" ;;
  --isolated) FVM_CACHE_PATH="$scratch/cache" FVM_GUI_ISOLATED_SMOKE=1 "$scratch/smoke" ;;
  *) echo "Usage: $0 [--read-only|--isolated]" >&2; exit 2 ;;
esac
