#!/usr/bin/env python3
"""Offline newline-delimited JSON transcription helper for Kotobane."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import sys
from typing import Any, TextIO

from model_install import MODEL_SPECS, ModelValidationError, validate_model_directory


MODEL_ALIASES = {
    "qwen3-asr-0.6b": MODEL_SPECS["Qwen/Qwen3-ASR-0.6B"],
    "qwen3-asr-1.7b": MODEL_SPECS["Qwen/Qwen3-ASR-1.7B"],
}
ZERO_ID = "00000000-0000-0000-0000-000000000000"


def _force_offline_environment() -> None:
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["NO_PROXY"] = "*"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"


class MLXQwenBackend:
    """Lazy adapter around the pinned mlx-qwen3-asr public API."""

    def __init__(self):
        self._sessions: dict[str, Any] = {}

    def transcribe(self, model_path: str, audio_path: str, language: str) -> Any:
        from mlx_qwen3_asr import Session

        session = self._sessions.get(model_path)
        if session is None:
            session = Session(model=model_path)
            self._sessions[model_path] = session
        return session.transcribe(audio_path, language=language)


def _failed(request_id: str, code: str, message: str) -> dict[str, Any]:
    return {
        "id": request_id,
        "status": "failed",
        "code": code,
        "message": message,
    }


def _request_id(request: Any) -> str:
    if isinstance(request, dict) and isinstance(request.get("id"), str):
        return request["id"]
    return ZERO_ID


def _validated_audio(request: dict[str, Any], app_support_root: Path) -> Path:
    supplied = request.get("audioPath")
    if not isinstance(supplied, str) or not supplied:
        raise ValueError("audioPath must be a non-empty string")
    root = app_support_root.resolve()
    audio = Path(supplied).resolve(strict=True)
    if not audio.is_relative_to(root) or not audio.is_file():
        raise ValueError("audioPath is not a regular file below Application Support")
    return audio


def _validated_model(model_name: Any, app_support_root: Path) -> Path:
    if not isinstance(model_name, str) or model_name not in MODEL_ALIASES:
        raise KeyError(model_name)
    spec = MODEL_ALIASES[model_name]
    root = app_support_root.resolve()
    candidate = app_support_root / "models" / spec.destination_name
    model = candidate.resolve(strict=True)
    if not model.is_relative_to(root):
        raise ModelValidationError("Model directory escaped Application Support")
    validate_model_directory(model, spec)
    ready_path = model / "ready.json"
    resolved_ready = ready_path.resolve(strict=True)
    if (
        ready_path.is_symlink()
        or not resolved_ready.is_relative_to(model)
        or not resolved_ready.is_file()
    ):
        raise ModelValidationError("Model readiness metadata is not a local regular file")
    ready = json.loads(ready_path.read_text(encoding="utf-8"))
    if ready.get("modelId") != spec.repository or ready.get("revision") != spec.revision:
        raise ModelValidationError("Model readiness metadata does not match pinned snapshot")
    return model


def _result_field(result: Any, *names: str, default: Any = None) -> Any:
    if isinstance(result, dict):
        for name in names:
            if name in result:
                return result[name]
    for name in names:
        if hasattr(result, name):
            return getattr(result, name)
    return default


def transcribe(
    request: dict[str, Any],
    app_support_root: Path,
    backend: Any | None = None,
) -> dict[str, Any]:
    request_id = _request_id(request)
    if not isinstance(request, dict) or request.get("action") != "transcribe":
        return _failed(request_id, "unsupported_action", "Unsupported helper action.")

    try:
        audio = _validated_audio(request, Path(app_support_root))
    except (OSError, RuntimeError, ValueError):
        return _failed(
            request_id,
            "invalid_audio_path",
            "The audio file is outside Kotobane's private storage or unavailable.",
        )

    model_name = request.get("model")
    if not isinstance(model_name, str) or model_name not in MODEL_ALIASES:
        return _failed(
            request_id,
            "unsupported_model",
            "The requested transcription model is not supported.",
        )
    try:
        model = _validated_model(model_name, Path(app_support_root))
    except (OSError, ValueError, json.JSONDecodeError, ModelValidationError):
        return _failed(
            request_id,
            "model_unavailable",
            "The selected model is not installed and ready.",
        )

    language = request.get("language")
    if not isinstance(language, str) or not language:
        language = "Turkish"

    _force_offline_environment()
    selected_backend = backend if backend is not None else MLXQwenBackend()
    try:
        result = selected_backend.transcribe(
            str(model),
            str(audio),
            language,
        )
    except (ImportError, ModuleNotFoundError) as error:
        print(
            f"runtime unavailable for request {request_id}: {type(error).__name__}",
            file=sys.stderr,
        )
        return _failed(
            request_id,
            "runtime_unavailable",
            "The local transcription runtime is unavailable.",
        )
    except Exception as error:
        print(
            f"transcription failed for request {request_id}: {type(error).__name__}",
            file=sys.stderr,
        )
        return _failed(
            request_id,
            "transcription_failed",
            "Local transcription failed.",
        )

    text = _result_field(result, "text")
    if not isinstance(text, str):
        return _failed(
            request_id,
            "transcription_failed",
            "The local transcription backend returned an invalid result.",
        )
    detected_language = _result_field(
        result,
        "detected_language",
        "language",
        default=language,
    )
    duration = _result_field(
        result,
        "duration_seconds",
        "duration",
        default=0.0,
    )
    try:
        normalized_duration = float(duration)
        if not math.isfinite(normalized_duration) or normalized_duration < 0:
            raise ValueError("duration must be finite and nonnegative")
        normalized_language = str(detected_language)
    except (TypeError, ValueError, OverflowError) as error:
        print(
            f"invalid backend result for request {request_id}: {type(error).__name__}",
            file=sys.stderr,
        )
        return _failed(
            request_id,
            "transcription_failed",
            "The local transcription backend returned an invalid result.",
        )
    return {
        "id": request_id,
        "status": "completed",
        "text": text,
        "detectedLanguage": normalized_language,
        "durationSeconds": normalized_duration,
    }


def serve(
    stdin: TextIO,
    stdout: TextIO,
    stderr: TextIO,
    app_support_root: Path,
    backend: Any | None = None,
) -> None:
    for line in stdin:
        try:
            request = json.loads(line)
            response = transcribe(request, app_support_root, backend)
        except Exception as error:
            print(f"invalid helper request: {type(error).__name__}", file=stderr)
            response = _failed(ZERO_ID, "invalid_request", "The helper request is invalid.")
        stdout.write(
            json.dumps(
                response,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        )
        stdout.flush()


def main() -> int:
    root = Path(
        os.environ.get(
            "KOTOBANE_APP_SUPPORT_ROOT",
            str(Path.home() / "Library" / "Application Support" / "Kotobane"),
        )
    )
    serve(sys.stdin, sys.stdout, sys.stderr, root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
