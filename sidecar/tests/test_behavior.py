import json
import struct
import unittest
from types import SimpleNamespace

import numpy as np

from sidecar.protocol import FrameDecoder, Packet, ProtocolError
from sidecar.vad import SpeechGate
from sidecar.recognizer import StreamingRecognizer
from sidecar.server import InputQueue, safe_environment


def packet(samples=None, source="system", sequence=0, captured_at=10.0):
    pcm = np.zeros(8000, np.float32) if samples is None else samples
    return Packet("audio", "test-session", source, sequence, pcm, captured_at)


def wire(pcm, **fields):
    header = dict(kind="audio", source="system", sequence=0, sampleRate=16000,
                  samples=len(pcm), payloadBytes=4 * len(pcm),
                  sessionID="test-session", capturedAt=10.0)
    header.update(fields)
    raw = json.dumps(header).encode()
    return struct.pack(">I", len(raw)) + raw + pcm.astype("<f4").tobytes()


class ProtocolTests(unittest.TestCase):
    def test_split_header_and_payload_preserves_source_and_audio(self):
        decoder = FrameDecoder("test-session")
        raw = wire(np.array([0.25, -0.5], np.float32), source="microphone")
        output = []
        for byte in raw:
            output.extend(decoder.feed(bytes([byte])))
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0].source, "microphone")
        self.assertEqual(output[0].pcm.tolist(), [0.25, -0.5])

    def test_large_header_is_rejected_before_payload(self):
        with self.assertRaises(ProtocolError):
            FrameDecoder("test-session").feed(struct.pack(">I", 4097))

    def test_invalid_audio_cannot_enter_recognizer(self):
        for fields in (dict(payloadBytes=5), dict(sampleRate=48000),
                       dict(source="unknown"), dict(sessionID="old"),
                       dict(capturedAt=float("nan")), dict(sequence=-1)):
            with self.subTest(fields=fields), self.assertRaises(ProtocolError):
                FrameDecoder("test-session").feed(wire(np.zeros(2), **fields))
        with self.assertRaises(ProtocolError):
            FrameDecoder("test-session").feed(wire(np.array([np.nan])))

    def test_control_with_no_audio_resets_both_sources(self):
        header = json.dumps(dict(kind="reset", sessionID="test-session",
                                 samples=0, payloadBytes=0)).encode()
        result = FrameDecoder("test-session").feed(struct.pack(">I", len(header)) + header)
        self.assertEqual(result[0].kind, "reset")
        self.assertIsNone(result[0].source)


class GateTests(unittest.TestCase):
    def test_silence_and_short_noise_never_form_utterance(self):
        calls = []
        gate = SpeechGate(on_utterance=calls.append)
        for _ in range(100):
            gate.feed(0.0, 512)
        gate.feed(0.9, 512)
        for _ in range(20):
            gate.feed(0.0, 512)
        self.assertEqual(calls, [])

    def test_endpoint_uses_voice_end_and_includes_preroll(self):
        gate = SpeechGate()
        for _ in range(10):
            gate.feed(0.0, 512)
        starts = []
        for _ in range(5):
            starts.extend(gate.feed(0.9, 512))
        self.assertEqual(starts[0].kind, "start")
        self.assertEqual(starts[0].start, 2560)
        for _ in range(15):
            self.assertEqual(gate.feed(0.1, 512), [])
        event = gate.feed(0.1, 512)[0]
        self.assertEqual((event.kind, event.end), ("end", 7680))

    def test_long_speech_remains_blocked_until_endpoint(self):
        gate = SpeechGate(max_seconds=1)
        changes = []
        for _ in range(80):
            changes.extend(gate.feed(0.9, 512))
        self.assertEqual([x.kind for x in changes], ["start", "too_long"])
        for _ in range(16):
            self.assertEqual(gate.feed(0.0, 512), [])
        starts = []
        for _ in range(5):
            starts.extend(gate.feed(0.9, 512))
        self.assertEqual([x.kind for x in starts], ["start"])


class EnergyVAD:
    def probability(self, pcm):
        return 0.9 if np.max(np.abs(pcm)) > 0.01 else 0.0

    def reset(self):
        pass


class ToySession:
    def __init__(self):
        self.calls = 0

    def init_streaming(self, **kwargs):
        return SimpleNamespace(text="")

    def feed_audio(self, pcm, state):
        self.calls += 1
        nonzero = pcm[np.abs(pcm) > 0.01]
        if len(nonzero):
            state.text = "system phrase" if float(nonzero.mean()) > 0 else "microphone phrase"
        return state

    def finish_streaming(self, state):
        return state


class RecognizerTests(unittest.TestCase):
    def test_silence_does_not_reach_model(self):
        session = ToySession()
        engine = StreamingRecognizer(session, EnergyVAD)
        for i in range(20):
            self.assertEqual(engine.process(packet(sequence=i, captured_at=10 + i * 0.5)), [])
        self.assertEqual(session.calls, 0)

    def test_two_sources_keep_text_and_voice_end_separate(self):
        engine = StreamingRecognizer(ToySession(), EnergyVAD)
        output = []
        for source, sign in (("system", 1), ("microphone", -1)):
            output.extend(engine.process(packet(np.full(8000, 0.1 * sign, np.float32), source)))
            output.extend(engine.process(packet(source=source, sequence=1, captured_at=10.5)))
            output.extend(engine.process(packet(source=source, sequence=2, captured_at=11.0)))
        finals = [x for x in output if x["isFinal"]]
        self.assertEqual([(x["source"], x["text"]) for x in finals],
                         [("system", "system phrase"), ("microphone", "microphone phrase")])
        self.assertLess(finals[0]["endedAt"], 10.6)
        self.assertGreater(finals[0]["endedAt"], 10.4)

    def test_reset_discards_partial_without_final(self):
        engine = StreamingRecognizer(ToySession(), EnergyVAD)
        engine.process(packet(np.full(8000, 0.1, np.float32)))
        engine.reset("system")
        self.assertEqual(engine.process(packet(sequence=1)), [])
        output = engine.process(packet(np.full(8000, -0.1, np.float32), sequence=2))
        self.assertTrue(all(x.get("text") != "system phrase" for x in output))

    def test_sequence_gap_reports_error_and_suppresses_stale_final(self):
        engine = StreamingRecognizer(ToySession(), EnergyVAD)
        engine.process(packet(np.full(8000, 0.1, np.float32)))
        events = engine.process(packet(sequence=2))
        self.assertEqual(events[0]["code"], "sequence_gap")
        self.assertFalse(any(x.get("isFinal") for x in events))


class QueueTests(unittest.TestCase):
    def test_worker_environment_excludes_credentials_and_proxy(self):
        filtered = safe_environment({"HOME": "/home/example", "PATH": "/usr/bin",
                                     "AITUNNEL_KEY": "private-test-value", "HF_TOKEN": "private-test-value",
                                     "HTTPS_PROXY": "http://example.invalid"})
        self.assertEqual(set(filtered), {"HOME", "PATH", "HF_HUB_OFFLINE", "HF_HUB_DISABLE_XET"})

    def test_overflow_drops_only_overloaded_source_and_invalidates_inflight(self):
        queue = InputQueue()
        self.assertTrue(queue.submit(packet(source="microphone")))
        for i in range(4):
            self.assertTrue(queue.submit(packet(sequence=i)))
        self.assertFalse(queue.submit(packet(sequence=4)))
        self.assertEqual(queue.generation("system"), 1)
        self.assertEqual(queue.generation("microphone"), 0)
        first, _ = queue.get()
        self.assertEqual((first.kind, first.source), ("reset", "system"))
        second, _ = queue.get()
        self.assertEqual(second.source, "microphone")

    def test_close_invalidates_already_running_inference(self):
        queue = InputQueue()
        queue.submit(packet())
        running, epoch = queue.get()
        queue.close()
        self.assertNotEqual(epoch, queue.generation(running.source))

    def test_repeated_overflow_does_not_accumulate_reset_commands(self):
        queue = InputQueue()
        queue.submit(packet(source="microphone"))
        for i in range(100):
            queue.submit(packet(sequence=i))
        first, _ = queue.get()
        second, _ = queue.get()
        self.assertEqual(first.kind, "reset")
        self.assertEqual(second.source, "microphone")


if __name__ == "__main__":
    unittest.main()
