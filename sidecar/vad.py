from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class SpeechEvent:
    kind: str
    start: int
    end: int


class SpeechGate:
    def __init__(self, on_utterance=None, max_seconds=90):
        self.on_utterance = on_utterance
        self.max_samples = int(max_seconds * 16000)
        self.reset()

    def reset(self):
        self.position = 0
        self.active = False
        self.candidate = None
        self.start = 0
        self.last_voice = 0
        self.blocked = False
        self.quiet_samples = 0

    def feed(self, probability, samples):
        begin = self.position
        self.position += samples
        if self.blocked:
            self.quiet_samples = self.quiet_samples + samples if probability < 0.35 else 0
            if self.quiet_samples >= 8000:
                self.blocked = False
                self.quiet_samples = 0
            return []
        if not self.active:
            if probability >= 0.5:
                if self.candidate is None:
                    self.candidate = begin
                if self.position - self.candidate >= 2560:
                    self.active = True
                    self.start = max(0, self.candidate - 2560)
                    self.last_voice = self.position
                    return [SpeechEvent("start", self.start, self.position)]
            else:
                self.candidate = None
            return []
        if probability >= 0.35:
            self.last_voice = self.position
        if self.position - self.start >= self.max_samples:
            event = SpeechEvent("too_long", self.start, self.last_voice)
            self.active = False
            self.candidate = None
            self.blocked = True
            return [event]
        if self.position - self.last_voice >= 8000:
            event = SpeechEvent("end", self.start, self.last_voice)
            self.active = False
            self.candidate = None
            if self.on_utterance is not None:
                self.on_utterance(event)
            return [event]
        return []


class SileroVAD:
    def __init__(self, session):
        self.session = session
        self.reset()

    def reset(self):
        self.state = np.zeros((2, 1, 128), np.float32)
        self.context = np.zeros((1, 64), np.float32)

    def probability(self, pcm):
        if len(pcm) != 512:
            raise ValueError("VAD принимает 512 samples")
        data = np.concatenate((self.context, pcm.reshape(1, -1)), axis=1)
        output, self.state = self.session.run(None, {"input": data,
            "state": self.state, "sr": np.array(16000, dtype=np.int64)})
        self.context = data[:, -64:].copy()
        return float(output[0, 0])


def silero_session(path=None):
    import onnxruntime as ort
    if path is None:
        path = Path(__file__).parent / "models/silero_vad.onnx"
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    return ort.InferenceSession(str(path), sess_options=options,
                               providers=["CPUExecutionProvider"])
