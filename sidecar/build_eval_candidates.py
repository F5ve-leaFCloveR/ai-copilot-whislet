import argparse
from collections import Counter
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "sidecar"

from .server import safe_environment


def build(regions, output):
    environment = safe_environment(os.environ)
    os.environ.clear()
    os.environ.update(environment)
    import numpy as np
    from huggingface_hub import snapshot_download
    from mlx_qwen3_asr import Session
    from .protocol import Packet
    from .recognizer import StreamingRecognizer
    from .vad import SileroVAD, silero_session

    manifest = json.loads((Path(__file__).parent / "model-manifest.json").read_text())
    model = manifest["asr"]
    local_model = snapshot_download(model["model_id"], revision=model["revision"], local_files_only=True)
    candidates = []
    errors = Counter()
    with open(os.devnull, "w") as muted, contextlib.redirect_stdout(muted):
        session = Session(local_model)
        vad = silero_session()
        for region in regions:
            raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(region["start_s"]),
                                  "-i", region["recording"], "-t", str(region["duration_s"]),
                                  "-map", f"0:a:{region['track']}", "-ac", "1", "-ar", "16000",
                                  "-f", "s16le", "pipe:1"], check=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE).stdout
            audio = np.frombuffer(raw, "<i2").astype(np.float32) / 32768
            actual_samples = len(audio)
            audio = np.concatenate((audio, np.zeros(16000, np.float32)))
            engine = StreamingRecognizer(session, lambda: SileroVAD(vad))
            segments = []
            engine.states["system"].gate.on_utterance = segments.append
            for index, offset in enumerate(range(0, len(audio), 8000)):
                events = engine.process(Packet("audio", "offline-candidates", "system", index,
                                               audio[offset:offset + 8000], region["start_s"] + offset / 16000))
                for event in events:
                    if event["kind"] == "error":
                        errors[event["code"]] += 1
                        continue
                    if not event["isFinal"]:
                        continue
                    end = round((event["endedAt"] - region["start_s"]) * 16000)
                    matches = [segment for segment in segments if abs(segment.end - end) <= 1]
                    if not matches:
                        raise RuntimeError("Нет VAD boundaries для final ASR")
                    segment = matches[-1]
                    if segment.start >= actual_samples:
                        continue
                    candidates.append(dict(id=f"{region['id']}-{len(candidates) + 1:04d}",
                                           recording=region["recording"], track=region["track"],
                                           source=region["source"],
                                           region_start_s=region["start_s"], region_duration_s=region["duration_s"],
                                           start_s=round(region["start_s"] + segment.start / 16000, 3),
                                           end_s=round(event["endedAt"], 3), text=event["text"],
                                           status="ASR_candidate_unverified", language="Russian",
                                           asr_model=model["model_id"], asr_revision=model["revision"],
                                           vad_release=manifest["vad"]["release"]))
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    os.chmod(output, 0o600)
    with os.fdopen(descriptor, "w") as destination:
        for candidate in candidates:
            destination.write(json.dumps(candidate, ensure_ascii=False) + "\n")
    return dict(candidates=len(candidates), sources=dict(Counter(row["source"] for row in candidates)),
                errors=dict(errors), output=str(output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--regions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(build(json.loads(args.regions.read_text()), args.output)))
