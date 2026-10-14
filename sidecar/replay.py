import argparse
import json
import os
from pathlib import Path
import queue
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from uuid import uuid4
import wave

import numpy as np


def read_wav(path):
    with wave.open(str(path)) as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
            raise ValueError("Replay требует mono PCM16 WAV 16kHz")
        return np.frombuffer(source.readframes(source.getnframes()), "<i2").astype(np.float32) / 32768


def send(sock, session_id, source, sequence, pcm, captured_at):
    header = json.dumps(dict(kind="audio", sessionID=session_id, source=source, sequence=sequence,
                             samples=len(pcm), payloadBytes=pcm.nbytes, sampleRate=16000,
                             capturedAt=captured_at)).encode()
    sock.sendall(struct.pack(">I", len(header)) + header + pcm.astype("<f4").tobytes())


def run(seconds, fixture_dir, output):
    session_id = str(uuid4())
    silence = np.zeros(16000, np.float32)
    system = np.concatenate([silence, read_wav(fixture_dir / "meeting_remote_00m.wav"), silence,
                             read_wav(fixture_dir / "meeting_remote_10m.wav"), silence])
    mic = np.concatenate([silence, read_wav(fixture_dir / "meeting_mic_10m.wav"), silence,
                          read_wav(fixture_dir / "meeting_mic_01m.wav"), silence])
    frames = int(seconds * 2)
    audio = {name: np.resize(pcm, frames * 8000) for name, pcm in (("system", system), ("microphone", mic))}
    for pcm in audio.values():
        pcm[-16000:] = 0
    with tempfile.TemporaryDirectory(prefix="copilot-asr-", dir="/private/tmp") as directory:
        os.chmod(directory, 0o700)
        path = Path(directory) / "asr.sock"
        environment = {key: value for key, value in os.environ.items() if key in
                       ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL")}
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("server.py")),
                                    "--socket", str(path), "--session-id", session_id],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        started = time.monotonic()
        events = []
        incoming = queue.Queue()
        try:
            while not path.exists():
                if process.poll() is not None or time.monotonic() - started > 60:
                    raise RuntimeError("Sidecar не создал socket")
                time.sleep(0.05)
            connection.connect(str(path))
            if path.stat().st_mode & 0o777 != 0o600:
                raise RuntimeError("Неверные права socket")

            def read_events():
                with connection.makefile("rb") as stream:
                    for line in stream:
                        event = json.loads(line)
                        if event.get("sessionID") != session_id:
                            incoming.put(RuntimeError("Stale session event"))
                            return
                        events.append(event)
                        incoming.put(event)

            reader = threading.Thread(target=read_events, daemon=True)
            reader.start()
            while True:
                event = incoming.get(timeout=60)
                if isinstance(event, Exception):
                    raise event
                if event["kind"] == "error":
                    raise RuntimeError(event["code"])
                if event["kind"] == "ready":
                    break
            warm = time.monotonic() - started
            silent_start = time.monotonic() - 0.5
            for i in range(4):
                deadline = silent_start + (i + 1) * 0.5
                time.sleep(max(0, deadline - time.monotonic()))
                for name in audio:
                    send(connection, session_id, name, i, np.zeros(8000, np.float32), silent_start + i * 0.5)
            time.sleep(0.5)
            silence_events = [x for x in events if x.get("processingSeconds") is not None]
            silence_calls = max((x["asrFeedCalls"] for x in silence_events), default=-1)
            base = silent_start + 2
            for i in range(frames):
                deadline = base + (i + 1) * 0.5
                time.sleep(max(0, deadline - time.monotonic()))
                for name, pcm in audio.items():
                    send(connection, session_id, name, i + 4, pcm[i * 8000:(i + 1) * 8000], base + i * 0.5)
            time.sleep(1)
            header = json.dumps(dict(kind="stop", sessionID=session_id, samples=0, payloadBytes=0)).encode()
            connection.sendall(struct.pack(">I", len(header)) + header)
            process.wait(timeout=5)
            reader.join(timeout=2)
            errors = [x.get("code") for x in events if x["kind"] == "error"]
            metrics = [x for x in events if "processingSeconds" in x]
            durations = [x["processingSeconds"] for x in metrics]
            lag = [x["queueLagSeconds"] for x in metrics]
            finals = [x for x in events if x.get("isFinal")]
            result = dict(seconds=seconds, audioChunks=frames * 2, warmupSeconds=warm,
                          silenceFeedCalls=silence_calls, errors=errors,
                          finalCounts={name: sum(x["source"] == name for x in finals) for name in audio},
                          processingP50=float(np.percentile(durations, 50)),
                          processingP95=float(np.percentile(durations, 95)),
                          queueLagP95=float(np.percentile(lag, 95)),
                          queueLagMax=max(lag), maxRSSBytes=max(x["maxRSSBytes"] for x in metrics),
                          stdoutBytes=len(process.stdout.read()), exitCode=process.returncode)
            output.write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result))
            return result
        finally:
            connection.close()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--fixture-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "replay-results.json")
    args = parser.parse_args()
    run(args.seconds, args.fixture_dir, args.output)
