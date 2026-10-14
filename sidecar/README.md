# Local speech recognition

Whislet runs Qwen3-ASR and Silero VAD locally on Apple Silicon. Audio is processed separately for the microphone and system output; no cloud transcription service or API key is used.

## Setup

From the project root, with Python 3.11 or newer installed:

```sh
bash scripts/setup-asr.sh
```

The script creates `sidecar/.venv`, installs the pinned packages in `requirements.txt`, reuses an existing Hugging Face model cache, and downloads missing models. Model revisions, file sizes and SHA256 checksums are recorded in `model-manifest.json` and verified during setup. Qwen weights stay in the local Hugging Face cache; Silero stays in the ignored `sidecar/models/` directory. Neither belongs in the repository.

Set `WHISLET_PYTHON` to another Python executable before setup if needed. The app's default runtime is `sidecar/.venv/bin/python` next to the checkout's `dist/` directory; keep the app there. The running recognizer only reads cached models and does not download them.

## Running the sidecar directly

```sh
sidecar/.venv/bin/python sidecar/server.py \
  --socket /private/tmp/whislet-private/asr.sock \
  --session-id 14a6c610-1a19-4c19-a0d5-630a8a92e289 \
  --model moona3k/mlx-qwen3-asr-0.6b-8bit \
  --language English
```

`--language` accepts `Russian` or `English`; `--vad-model` selects another local ONNX file. The socket directory must belong to the current user and have mode `700`. The server creates a missing directory, creates the socket with mode `600`, accepts one client, and removes the socket on exit. Existing socket paths are rejected. Credentials are removed from the process environment.

The socket opens before warmup. Audio capture should start only after the `ready` event. MLX and ONNX inference run on one persistent thread. Each audio source has its own streaming state, VAD state and context, while sharing the model weights.

## IPC

Input packets contain a four-byte big-endian JSON-header length, the UTF-8 JSON header, and optional raw audio. Headers are limited to 4096 bytes and audio to 32000 bytes. Audio is mono float32 little-endian PCM at 16000 Hz, normally 8000 samples per packet. Samples must be finite and within `[-1, 1]`.

```json
{"kind":"audio","sessionID":"14a6c610-1a19-4c19-a0d5-630a8a92e289","source":"system","sequence":0,"sampleRate":16000,"samples":8000,"payloadBytes":32000,"capturedAt":5829.123}
```

`source` is `system` or `microphone`. `sequence` increases independently for each source. `capturedAt` is the monotonic time of the first sample, using the same time base as `ProcessInfo.systemUptime`. Missing sequences or timestamp gaps over 150 ms reset the affected utterance and emit an error without a final transcript.

Control packets do not contain audio:

```json
{"kind":"reset","sessionID":"14a6c610-1a19-4c19-a0d5-630a8a92e289","samples":0,"payloadBytes":0}
{"kind":"reset","sessionID":"14a6c610-1a19-4c19-a0d5-630a8a92e289","source":"system","samples":0,"payloadBytes":0}
{"kind":"stop","sessionID":"14a6c610-1a19-4c19-a0d5-630a8a92e289","samples":0,"payloadBytes":0}
```

Reset clears both sources or the specified source. Stop, disconnect and SIGTERM stop inference without finalizing unfinished utterances. A new session requires a new process and session ID. Invalid headers, sources, session IDs, PCM or packet sizes close the connection with `protocol_error`.

Output is NDJSON, with a maximum line size of 65536 bytes. Every event includes `sessionID`. `ready` includes model information, language, VAD information and `protocolVersion=1`. Heartbeats report liveness and, after processing, timing, queue lag, inference counts and memory usage. Errors include a code and message, and a source when applicable.

```json
{"kind":"transcript","sessionID":"14a6c610-1a19-4c19-a0d5-630a8a92e289","id":"67d7bc24-b7df-4d5a-8383-bb4a40b6d771","source":"system","text":"How does retrieval work?","endedAt":5832.43,"isFinal":true}
```

Partial and final transcripts share an utterance ID. `endedAt` refers to the last speech sample, excluding endpoint silence. Transcripts are sent through the socket, not stdout. The sidecar does not save audio or transcripts to disk.

## Segmentation

Silero runs on CPU with 512-sample frames. Speech starts after at least 160 ms at probability ≥0.5 and ends after 500 ms below 0.35. A 160 ms pre-roll is preserved. Qwen receives 0.5-second chunks with a rolling context of 30 seconds.

Continuous utterances are limited to 90 seconds. Exceeding the limit emits `long_utterance` and pauses recognition until the next silence; the existing partial remains available for manual use. Each source queues at most four packets. Overflow resets that source and emits `queue_overflow`, preserving the other source.

## Checks and private recordings

```sh
sidecar/.venv/bin/python -m unittest discover -s sidecar/tests
sidecar/.venv/bin/python -m py_compile sidecar/*.py
sidecar/.venv/bin/python sidecar/replay.py \
  --fixture-dir /path/to/private-wav-fixtures \
  --seconds 60 --output /path/to/private-results.json
```

Replay requires four mono PCM16 WAV files at 16 kHz: `meeting_remote_00m.wav`, `meeting_remote_10m.wav`, `meeting_mic_10m.wav`, and `meeting_mic_01m.wav`. It repeats the supplied clips with silence for a paced stress test and writes timing, counts, errors and memory metrics without transcript text. These recordings are user-provided and should stay outside the repository.

`build_eval_candidates.py --regions regions.json --output candidates.jsonl` creates offline ASR candidates from recording regions using ffmpeg in memory. Region entries contain `id`, `recording`, zero-based `track`, `source`, `start_s`, and `duration_s`. The output has mode `600` and marks every transcript as `ASR_candidate_unverified`; these candidates require manual review and are not ground truth.
