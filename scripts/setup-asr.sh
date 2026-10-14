#!/bin/bash
set -euo pipefail
umask 077
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_python="${WHISLET_PYTHON:-python3}"
task_venv="$task_root/sidecar/.venv"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    printf '%s\n' "Локальное ASR требует macOS на Apple Silicon" >&2
    exit 1
fi
"$task_python" -c 'import sys; assert sys.version_info >= (3, 11), "Требуется Python 3.11 или новее"'
if [ ! -x "$task_venv/bin/python" ]; then "$task_python" -m venv "$task_venv"; fi
"$task_venv/bin/python" -m pip install -r "$task_root/sidecar/requirements.txt"
"$task_venv/bin/python" - "$task_root/sidecar" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from urllib.request import urlopen

from huggingface_hub import snapshot_download
from huggingface_hub.errors import LocalEntryNotFoundError

sidecar = Path(sys.argv[1])
manifest = json.loads((sidecar / "model-manifest.json").read_text())


def verify(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected["sha256"] or path.stat().st_size != expected["bytes"]:
        raise RuntimeError("Проверка модели не пройдена: " + path.name)


asr = manifest["asr"]
try:
    snapshot = snapshot_download(asr["model_id"], revision=asr["revision"], local_files_only=True)
except LocalEntryNotFoundError:
    snapshot = snapshot_download(asr["model_id"], revision=asr["revision"])
for name, expected in asr["files"].items():
    verify(Path(snapshot) / name, expected)

vad = manifest["vad"]
target = sidecar / vad["path"]
if target.exists():
    verify(target, vad)
else:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
            temporary = Path(output.name)
            with urlopen(vad["source"], timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
        verify(temporary, vad)
        temporary.replace(target)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
print("Локальное ASR готово; версии и контрольные суммы проверены")
PY
