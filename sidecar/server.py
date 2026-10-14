import argparse
from collections import deque
import contextlib
import json
import os
from pathlib import Path
import queue
import resource
import signal
import socket
import sys
import threading
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "sidecar"

from .protocol import FrameDecoder, Packet, ProtocolError, SOURCES, output_line


def safe_environment(environment):
    allowed = {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"}
    return {**{key: value for key, value in environment.items() if key in allowed},
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_XET": "1"}


class InputQueue:
    def __init__(self):
        self.condition = threading.Condition()
        self.audio = {source: deque() for source in SOURCES}
        self.controls = deque()
        self.epochs = {source: 0 for source in SOURCES}
        self.closed = False
        self.cursor = 0

    def generation(self, source):
        with self.condition:
            return self.epochs[source]

    def submit(self, packet):
        with self.condition:
            if self.closed:
                return False
            if packet.kind != "audio":
                for source in SOURCES if packet.source is None else (packet.source,):
                    self.audio[source].clear()
                    self.epochs[source] += 1
                if packet.source is None:
                    self.controls.clear()
                else:
                    self.controls = deque(x for x in self.controls if x.source != packet.source)
                self.controls.append(packet)
            elif len(self.audio[packet.source]) >= 4:
                self.audio[packet.source].clear()
                self.epochs[packet.source] += 1
                if not any(x.source in (None, packet.source) for x in self.controls):
                    self.controls.append(Packet("reset", packet.session_id, packet.source))
                self.condition.notify()
                return False
            else:
                self.audio[packet.source].append(packet)
            self.condition.notify()
            return True

    def get(self):
        with self.condition:
            self.condition.wait_for(lambda: self.closed or self.controls or any(self.audio.values()))
            if self.closed:
                return None, 0
            if self.controls:
                return self.controls.popleft(), 0
            for step in range(2):
                index = (self.cursor + step) % 2
                source = SOURCES[index]
                if self.audio[source]:
                    self.cursor = (index + 1) % 2
                    return self.audio[source].popleft(), self.epochs[source]

    def close(self):
        with self.condition:
            self.closed = True
            self.controls.clear()
            for source, pending in self.audio.items():
                pending.clear()
                self.epochs[source] += 1
            self.condition.notify_all()


def serve(path, session_id, model, language, vad_path=None):
    path = Path(path)
    if len(os.fsencode(path)) > 100:
        raise ValueError("Unix socket path слишком длинный")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.stat().st_uid != os.getuid() or path.parent.stat().st_mode & 0o077:
        raise ValueError("Socket directory должна принадлежать пользователю и иметь mode700")
    if path.exists():
        raise ValueError("Socket path уже существует")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    os.chmod(path, 0o600)
    listener.listen(1)
    listener.settimeout(1)
    stop = threading.Event()
    inputs = InputQueue()
    outputs = queue.Queue(maxsize=64)
    conn = None

    def emit(event):
        try:
            outputs.put_nowait(output_line(dict(event, sessionID=session_id)))
        except (queue.Full, ProtocolError):
            stop.set()

    def worker():
        try:
            with open(os.devnull, "w") as muted, contextlib.redirect_stdout(muted):
                os.environ["HF_HUB_OFFLINE"] = "1"
                os.environ["HF_HUB_DISABLE_XET"] = "1"
                from mlx_qwen3_asr import Session
                import numpy as np
                from .recognizer import StreamingRecognizer
                from .vad import SileroVAD, silero_session
                manifest = json.loads((Path(__file__).parent / "model-manifest.json").read_text())
                resolved_model = model
                if model == manifest["asr"]["model_id"]:
                    from huggingface_hub import snapshot_download
                    resolved_model = snapshot_download(model, revision=manifest["asr"]["revision"], local_files_only=True)
                backend = Session(resolved_model)
                warm = backend.init_streaming(language=language, chunk_size_sec=0.5, max_context_sec=30)
                warm = backend.feed_audio(np.zeros(8000, np.float32), warm)
                backend.finish_streaming(warm)
                vad_backend = silero_session(vad_path)
                engine = StreamingRecognizer(backend, lambda: SileroVAD(vad_backend), language)
                if stop.is_set():
                    return
                info = dict(backend.model_info)
                info.pop("resolved_model_path", None)
                info["model_id"] = model
                if model == manifest["asr"]["model_id"]:
                    info["revision"] = manifest["asr"]["revision"]
                emit(dict(kind="ready", model=info, language=language,
                          vad=manifest["vad"], protocolVersion=1))
                while not stop.is_set():
                    packet, epoch = inputs.get()
                    if packet is None or packet.kind == "stop":
                        break
                    start = time.monotonic()
                    events = engine.process(packet)
                    if packet.kind != "audio":
                        continue
                    if not stop.is_set() and epoch == inputs.generation(packet.source):
                        for event in events:
                            emit(event)
                    lag = max(0.0, start - packet.captured_at - len(packet.pcm) / 16000)
                    emit(dict(kind="heartbeat", source=packet.source,
                              processingSeconds=time.monotonic() - start, queueLagSeconds=lag,
                              asrFeedCalls=engine.feed_calls, asrFinalizeCalls=engine.finalize_calls,
                              maxRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss))
        except Exception as error:
            emit(dict(kind="error", code="worker_failed", message="Не удалось запустить или продолжить локальное ASR",
                      exceptionType=type(error).__name__))
        finally:
            stop.set()

    def write_events():
        last_heartbeat = time.monotonic()
        while not stop.is_set() or not outputs.empty():
            try:
                line = outputs.get(timeout=0.2)
            except queue.Empty:
                if time.monotonic() - last_heartbeat > 2:
                    line = output_line(dict(kind="heartbeat", sessionID=session_id))
                else:
                    continue
            try:
                conn.sendall(line)
                last_heartbeat = time.monotonic()
            except (OSError, socket.timeout):
                stop.set()
                break

    def terminate(*_):
        stop.set()
        inputs.close()

    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, terminate)
        signal.signal(signal.SIGINT, terminate)
    thread = threading.Thread(target=worker, name="local-asr", daemon=True)
    thread.start()
    writer = None
    try:
        while not stop.is_set():
            try:
                conn, _ = listener.accept()
                break
            except socket.timeout:
                continue
        if conn is None:
            return
        conn.settimeout(1)
        writer = threading.Thread(target=write_events, name="asr-output", daemon=True)
        writer.start()
        decoder = FrameDecoder(session_id)
        while not stop.is_set():
            try:
                data = conn.recv(32768)
            except socket.timeout:
                continue
            if not data:
                break
            try:
                packets = decoder.feed(data)
            except ProtocolError as error:
                emit(dict(kind="error", code="protocol_error", message=str(error)))
                break
            for packet in packets:
                if packet.kind == "stop":
                    terminate()
                    break
                if not inputs.submit(packet):
                    emit(dict(kind="error", source=packet.source, code="queue_overflow",
                              message="ASR не успевает за звуком; реплика сброшена"))
    finally:
        terminate()
        if writer:
            writer.join(timeout=2)
        if conn:
            conn.close()
        listener.close()
        thread.join(timeout=2)
        path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--model", default="moona3k/mlx-qwen3-asr-0.6b-8bit")
    parser.add_argument("--language", choices=("Russian", "English"), default="Russian")
    parser.add_argument("--vad-model", type=Path)
    args = parser.parse_args()
    environment = safe_environment(os.environ)
    os.environ.clear()
    os.environ.update(environment)
    serve(args.socket, args.session_id, args.model, args.language, args.vad_model)


if __name__ == "__main__":
    main()
