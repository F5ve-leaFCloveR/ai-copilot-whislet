import json
import math
import struct
from dataclasses import dataclass

import numpy as np

SOURCES = ("system", "microphone")
MAX_HEADER = 4096
MAX_AUDIO = 32000
MAX_OUTPUT = 65536


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class Packet:
    kind: str
    session_id: str
    source: str | None = None
    sequence: int = 0
    pcm: np.ndarray | None = None
    captured_at: float = 0.0


class FrameDecoder:
    def __init__(self, session_id):
        self.session_id = session_id
        self.buffer = bytearray()
        self.header = None

    def feed(self, data):
        self.buffer.extend(data)
        result = []
        while True:
            if self.header is None:
                if len(self.buffer) < 4:
                    break
                size = struct.unpack_from(">I", self.buffer)[0]
                if not 0 < size <= MAX_HEADER:
                    raise ProtocolError("invalid_header_length")
                if len(self.buffer) < size + 4:
                    break
                try:
                    header = json.loads(bytes(self.buffer[4:4 + size]))
                except (ValueError, UnicodeError):
                    raise ProtocolError("invalid_json") from None
                self._validate(header)
                del self.buffer[:4 + size]
                self.header = header
            size = self.header["payloadBytes"]
            if len(self.buffer) < size:
                break
            pcm = np.frombuffer(bytes(self.buffer[:size]), dtype="<f4").copy()
            if not np.isfinite(pcm).all() or np.any(np.abs(pcm) > 1.0):
                raise ProtocolError("invalid_pcm")
            h = self.header
            result.append(Packet(h["kind"], h["sessionID"], h.get("source"),
                                 h.get("sequence", 0), pcm, h.get("capturedAt", 0.0)))
            del self.buffer[:size]
            self.header = None
        return result

    def _validate(self, h):
        if not isinstance(h, dict) or h.get("sessionID") != self.session_id:
            raise ProtocolError("invalid_session")
        if h.get("kind") not in ("audio", "reset", "stop"):
            raise ProtocolError("invalid_kind")
        source = h.get("source")
        if source is not None and source not in SOURCES:
            raise ProtocolError("invalid_source")
        for name in ("samples", "payloadBytes"):
            if type(h.get(name)) is not int or h[name] < 0:
                raise ProtocolError("invalid_length")
        if h["payloadBytes"] > MAX_AUDIO or h["samples"] * 4 != h["payloadBytes"]:
            raise ProtocolError("invalid_payload_length")
        if h["kind"] == "audio":
            if source not in SOURCES or h.get("sampleRate") != 16000 or not h["samples"]:
                raise ProtocolError("invalid_audio_format")
            if type(h.get("sequence")) is not int or h["sequence"] < 0:
                raise ProtocolError("invalid_sequence")
            timestamp = h.get("capturedAt")
            if type(timestamp) not in (int, float) or not math.isfinite(timestamp) or timestamp < 0:
                raise ProtocolError("invalid_timestamp")
        elif h["samples"] or h["payloadBytes"]:
            raise ProtocolError("control_has_payload")


def output_line(event):
    raw = json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode() + b"\n"
    if len(raw) > MAX_OUTPUT:
        raise ProtocolError("output_too_large")
    return raw
