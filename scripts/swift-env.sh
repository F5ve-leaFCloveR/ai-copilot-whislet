#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_binary="$(xcrun --find swift)"
toolchain_libs="$(dirname "$(dirname "$swift_binary")")/lib/swift/pm"
local_libs="$task_root/.build/swiftpm-libs"

python3 - "$toolchain_libs" "$local_libs" <<'PY'
from pathlib import Path
import shutil
import sys

source, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
shutil.copytree(source / "ManifestAPI", destination / "ManifestAPI", dirs_exist_ok=True,
                ignore=shutil.ignore_patterns("*.private.swiftinterface"))
for item in source.iterdir():
    if item.name != "ManifestAPI":
        target = destination / item.name
        if not target.exists():
            target.symlink_to(item, target_is_directory=item.is_dir())
PY

export SWIFTPM_CUSTOM_LIBS_DIR="$local_libs"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.build/swift-module-cache"
exec "$@"
