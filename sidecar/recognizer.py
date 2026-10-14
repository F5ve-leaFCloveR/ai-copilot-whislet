from collections import deque
from dataclasses import dataclass, field
from uuid import uuid4

import numpy as np

from .protocol import SOURCES
from .vad import SpeechGate


@dataclass
class SourceState:
    vad: object
    asr: object
    gate: SpeechGate = field(default_factory=SpeechGate)
    pcm: np.ndarray = field(default_factory=lambda: np.zeros(0, np.float32))
    pcm_at: float = 0.0
    preroll: deque = field(default_factory=lambda: deque(maxlen=10))
    pending: list = field(default_factory=list)
    utterance_id: str | None = None
    text: str = ""
    voice_end: float = 0.0
    sequence: int | None = None


class StreamingRecognizer:
    def __init__(self, session, vad_factory, language="Russian"):
        self.session = session
        self.vad_factory = vad_factory
        self.options = dict(language=language, chunk_size_sec=0.5,
                            sample_rate=16000, max_context_sec=30.0)
        self.states = {}
        self.feed_calls = 0
        self.finalize_calls = 0
        self.reset()

    def reset(self, source=None):
        for name in SOURCES if source is None else (source,):
            self.states[name] = SourceState(self.vad_factory(), self.session.init_streaming(**self.options))

    def process(self, packet):
        if packet.kind == "reset":
            self.reset(packet.source)
            return []
        state = self.states[packet.source]
        if state.sequence is not None and packet.sequence != state.sequence + 1:
            self.reset(packet.source)
            return [self._error(packet.source, "sequence_gap", "Пропущен фрагмент звука; реплика сброшена")]
        if state.sequence is not None and abs(packet.captured_at - (state.pcm_at + len(state.pcm) / 16000)) > 0.15:
            self.reset(packet.source)
            return [self._error(packet.source, "audio_gap", "Изменилось время звука; реплика сброшена")]
        state.sequence = packet.sequence
        if not len(state.pcm):
            state.pcm_at = packet.captured_at
        state.pcm = np.concatenate((state.pcm, packet.pcm))
        events = []
        while len(state.pcm) >= 512:
            frame, timestamp = state.pcm[:512].copy(), state.pcm_at
            state.pcm = state.pcm[512:].copy()
            state.pcm_at += 512 / 16000
            begin = state.gate.position
            probability = state.vad.probability(frame)
            state.preroll.append((begin, frame, timestamp))
            was_active = state.gate.active
            changes = state.gate.feed(probability, 512)
            if was_active:
                state.pending.append(frame)
                if probability >= 0.35:
                    state.voice_end = timestamp + 512 / 16000
            for event in changes:
                if event.kind == "start":
                    state.utterance_id = str(uuid4())
                    state.pending = [pcm for start, pcm, _ in state.preroll if start >= event.start]
                    state.voice_end = timestamp + 512 / 16000
                elif event.kind == "end":
                    self._feed(state)
                    state.asr = self.session.finish_streaming(state.asr)
                    self.finalize_calls += 1
                    text = state.asr.text.strip()
                    if text:
                        events.append(self._transcript(state, packet.source, text, True))
                    self._clear_utterance(state)
                elif event.kind == "too_long":
                    events.append(self._error(packet.source, "long_utterance", "Длинная реплика; используйте ручную подсказку"))
                    self._clear_utterance(state)
                    state.preroll.clear()
        if state.gate.active and state.pending:
            self._feed(state)
            text = state.asr.text.strip()
            if text and text != state.text:
                state.text = text
                events.append(self._transcript(state, packet.source, text, False))
        return events

    def _feed(self, state):
        if state.pending:
            pcm = np.concatenate(state.pending)
            state.pending.clear()
            state.asr = self.session.feed_audio(pcm, state.asr)
            self.feed_calls += 1

    def _clear_utterance(self, state):
        state.asr = self.session.init_streaming(**self.options)
        state.pending.clear()
        state.utterance_id = None
        state.text = ""

    @staticmethod
    def _transcript(state, source, text, final):
        return dict(kind="transcript", id=state.utterance_id, source=source,
                    text=text, endedAt=state.voice_end, isFinal=final)

    @staticmethod
    def _error(source, code, message):
        return dict(kind="error", source=source, code=code, message=message)
