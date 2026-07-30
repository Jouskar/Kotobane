from dataclasses import replace
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import wave


HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT))

import kotobane_helper
from kotobane_helper import serve, transcribe


SMALL_MODEL = "qwen3-asr-0.6b"
REQUEST_ID = "00000000-0000-0000-0000-000000000001"


class FakeBackend:
    def __init__(self, text="merhaba", detected_language="Turkish", duration=1.25):
        self.result = SimpleNamespace(
            text=text,
            detected_language=detected_language,
            duration_seconds=duration,
        )
        self.calls = []

    def transcribe(self, model_path, audio_path, language):
        self.calls.append((model_path, audio_path, language))
        return self.result


def request_for(audio: Path, model: str = SMALL_MODEL) -> dict:
    return {
        "id": REQUEST_ID,
        "action": "transcribe",
        "audioPath": str(audio),
        "language": "Turkish",
        "model": model,
    }


def prepare_model(root: Path, model: str = SMALL_MODEL) -> Path:
    model_root = root / "models" / model
    model_root.mkdir(parents=True)
    for name in (
        "config.json",
        "preprocessor_config.json",
        "tokenizer_config.json",
        "vocab.json",
        "merges.txt",
        "generation_config.json",
        "chat_template.json",
        "model.safetensors",
    ):
        (model_root / name).write_bytes(b"{}")
    (model_root / "ready.json").write_text(
        json.dumps(
            {
                "modelId": "Qwen/Qwen3-ASR-0.6B",
                "revision": "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
            }
        ),
        encoding="utf-8",
    )
    return model_root


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        original_spec = kotobane_helper.MODEL_ALIASES[SMALL_MODEL]
        fixture_spec = replace(
            original_spec,
            weight_sha256={
                "model.safetensors": hashlib.sha256(b"{}").hexdigest()
            },
        )
        spec_patch = mock.patch.dict(
            kotobane_helper.MODEL_ALIASES,
            {SMALL_MODEL: fixture_spec},
        )
        spec_patch.start()
        self.addCleanup(spec_patch.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def test_rejects_audio_outside_app_support(self):
        request = request_for(Path("/tmp/escape.wav"))

        response = transcribe(request, self.root, FakeBackend())

        self.assertEqual(response["status"], "failed")
        self.assertEqual(response["code"], "invalid_audio_path")

    def test_completed_response_preserves_backend_text(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        prepare_model(self.root)

        response = transcribe(
            request_for(audio),
            self.root,
            FakeBackend(text=" şey, API'yi düzeltelim "),
        )

        self.assertEqual(response["text"], " şey, API'yi düzeltelim ")

    def test_backend_receives_only_canonical_local_paths_and_offline_environment(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        model = prepare_model(self.root)
        backend = FakeBackend()

        with mock.patch.dict(
            os.environ,
            {
                "HF_HUB_OFFLINE": "0",
                "TRANSFORMERS_OFFLINE": "0",
                "NO_PROXY": "",
            },
        ):
            response = transcribe(request_for(audio), self.root, backend)
            self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
            self.assertEqual(os.environ["TRANSFORMERS_OFFLINE"], "1")
            self.assertEqual(os.environ["NO_PROXY"], "*")

        self.assertEqual(response["status"], "completed")
        self.assertEqual(
            backend.calls,
            [(str(model.resolve()), str(audio.resolve()), "Turkish")],
        )

    def test_resamples_pcm_wav_for_backend_without_ffmpeg(self):
        audio = self.root / "captures" / "forty-eight-kilohertz.wav"
        audio.parent.mkdir(parents=True)
        with wave.open(str(audio), "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(48_000)
            writer.writeframes(b"\x00\x00" * 48_000)
        prepare_model(self.root)
        class InspectingBackend(FakeBackend):
            def transcribe(self, model_path, audio_path, language):
                with wave.open(audio_path, "rb") as reader:
                    self.sample_rate = reader.getframerate()
                return super().transcribe(model_path, audio_path, language)

        backend = InspectingBackend()

        response = transcribe(request_for(audio), self.root, backend)

        self.assertEqual(response["status"], "completed")
        self.assertEqual(backend.sample_rate, 16_000)

    def test_missing_model_is_reported_before_backend_use(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        backend = FakeBackend()

        response = transcribe(request_for(audio), self.root, backend)

        self.assertEqual(response["code"], "model_unavailable")
        self.assertEqual(backend.calls, [])

    def test_symlinked_readiness_metadata_is_not_trusted(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        model = prepare_model(self.root)
        external_ready = self.root.parent / f"{self.root.name}-ready.json"
        external_ready.write_text(
            json.dumps(
                {
                    "modelId": "Qwen/Qwen3-ASR-0.6B",
                    "revision": "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
                }
            ),
            encoding="utf-8",
        )
        (model / "ready.json").unlink()
        (model / "ready.json").symlink_to(external_ready)
        backend = FakeBackend()
        self.addCleanup(external_ready.unlink, missing_ok=True)

        response = transcribe(request_for(audio), self.root, backend)

        self.assertEqual(response["code"], "model_unavailable")
        self.assertEqual(backend.calls, [])

    def test_weight_corruption_after_ready_is_rejected_before_backend_use(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        model = prepare_model(self.root)
        (model / "model.safetensors").write_bytes(b"corrupted after install")
        backend = FakeBackend()

        response = transcribe(request_for(audio), self.root, backend)

        self.assertEqual(response["id"], REQUEST_ID)
        self.assertEqual(response["code"], "model_unavailable")
        self.assertEqual(backend.calls, [])

    def test_unknown_model_is_explicitly_rejected(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")

        response = transcribe(
            request_for(audio, model="not-a-model"),
            self.root,
            FakeBackend(),
        )

        self.assertEqual(response["code"], "unsupported_model")

    def test_backend_failure_is_reported_without_putting_diagnostics_on_stdout(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        prepare_model(self.root)

        class FailingBackend:
            def transcribe(self, model_path, audio_path, language):
                raise RuntimeError("decoder exploded")

        response = transcribe(request_for(audio), self.root, FailingBackend())

        self.assertEqual(response["code"], "transcription_failed")
        self.assertNotIn("decoder exploded", json.dumps(response))

    def test_invalid_backend_duration_maps_to_request_scoped_transcription_failure(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        prepare_model(self.root)

        response = transcribe(
            request_for(audio),
            self.root,
            FakeBackend(duration="not-a-duration"),
        )

        self.assertEqual(response["id"], REQUEST_ID)
        self.assertEqual(response["status"], "failed")
        self.assertEqual(response["code"], "transcription_failed")

    def test_serve_writes_exactly_one_json_response_line_per_request(self):
        audio = self.root / "captures" / "note.wav"
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"RIFF")
        prepare_model(self.root)
        stdin = io.StringIO(json.dumps(request_for(audio)) + "\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        serve(stdin, stdout, stderr, self.root, FakeBackend())

        lines = stdout.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0])["status"], "completed")
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
