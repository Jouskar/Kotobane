"""Explicit, network-enabled installer for Kotobane's pinned Qwen models."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import json
import os
from pathlib import Path
from typing import Callable
import uuid


GIB = 1024**3


@dataclass(frozen=True)
class ModelSpec:
    repository: str
    revision: str
    expected_bytes: int
    destination_name: str
    required_files: tuple[str, ...]
    weight_sha256: dict[str, str]


_COMMON_FILES = (
    "config.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "generation_config.json",
    "chat_template.json",
)

MODEL_SPECS = {
    "Qwen/Qwen3-ASR-0.6B": ModelSpec(
        repository="Qwen/Qwen3-ASR-0.6B",
        revision="5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
        expected_bytes=1_880_619_678,
        destination_name="qwen3-asr-0.6b",
        required_files=_COMMON_FILES + ("model.safetensors",),
        weight_sha256={
            "model.safetensors": (
                "79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea"
            )
        },
    ),
    "Qwen/Qwen3-ASR-1.7B": ModelSpec(
        repository="Qwen/Qwen3-ASR-1.7B",
        revision="7278e1e70fe206f11671096ffdd38061171dd6e5",
        expected_bytes=4_703_114_308,
        destination_name="qwen3-asr-1.7b",
        required_files=_COMMON_FILES
        + (
            "model.safetensors.index.json",
            "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
        ),
        weight_sha256={
            "model-00001-of-00002.safetensors": (
                "a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6"
            ),
            "model-00002-of-00002.safetensors": (
                "6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc"
            ),
        },
    ),
}


class ModelInstallError(RuntimeError):
    """Base class for setup errors that are safe to present to the app."""


class UnsupportedModelError(ModelInstallError):
    pass


class InsufficientCapacityError(ModelInstallError):
    def __init__(self, required_bytes: int, free_bytes: int):
        self.required_bytes = required_bytes
        self.free_bytes = free_bytes
        super().__init__(
            f"Model setup requires {required_bytes} bytes; {free_bytes} bytes are free"
        )


class ModelValidationError(ModelInstallError):
    pass


class ExpectedSizeMismatchError(ModelInstallError):
    pass


DownloadFunction = Callable[[str, str, Path], None]


def _download_snapshot(repository: str, revision: str, local_dir: Path) -> None:
    """Network boundary. Called only by the explicit setup workflow."""
    from huggingface_hub import snapshot_download

    os.environ["HF_HUB_OFFLINE"] = "0"
    snapshot_download(
        repo_id=repository,
        revision=revision,
        local_dir=str(local_dir),
    )


def validate_model_directory(directory: Path, spec: ModelSpec) -> None:
    """Validate the pinned Qwen file layout and every model weight digest."""
    resolved_root = directory.resolve(strict=True)
    missing: list[str] = []
    for relative_name in spec.required_files:
        candidate = directory / relative_name
        try:
            resolved = candidate.resolve(strict=True)
        except (FileNotFoundError, OSError):
            missing.append(relative_name)
            continue
        if (
            not resolved.is_relative_to(resolved_root)
            or not resolved.is_file()
            or candidate.is_symlink()
            or resolved.stat().st_size == 0
        ):
            missing.append(relative_name)
    if missing:
        raise ModelValidationError(
            "Model snapshot is missing required regular files: "
            + ", ".join(sorted(missing))
        )

    mismatched: list[str] = []
    for relative_name, expected_sha256 in spec.weight_sha256.items():
        digest = hashlib.sha256()
        with (directory / relative_name).open("rb") as weight_file:
            while chunk := weight_file.read(8 * 1024 * 1024):
                digest.update(chunk)
        if not hmac.compare_digest(digest.hexdigest(), expected_sha256):
            mismatched.append(relative_name)
    if mismatched:
        raise ModelValidationError(
            "Model snapshot has invalid SHA-256 weights: "
            + ", ".join(sorted(mismatched))
        )


def install_model(
    model_id: str,
    destination: Path,
    expected_bytes: int,
    free_bytes: int,
    *,
    downloader: DownloadFunction = _download_snapshot,
) -> Path:
    """Download, validate, and atomically activate one immutable Qwen snapshot."""
    try:
        spec = MODEL_SPECS[model_id]
    except KeyError as error:
        raise UnsupportedModelError(f"Unsupported model repository: {model_id}") from error

    if expected_bytes != spec.expected_bytes:
        raise ExpectedSizeMismatchError(
            f"Expected size must match pinned metadata ({spec.expected_bytes} bytes)"
        )
    required_bytes = expected_bytes + max(GIB, expected_bytes // 10)
    if free_bytes < required_bytes:
        raise InsufficientCapacityError(required_bytes, free_bytes)

    destination = Path(destination)
    if destination.exists():
        raise ModelInstallError(f"Destination already exists: {destination}")

    staging_root = destination.parent / ".staging"
    staging_root.mkdir(parents=True, exist_ok=True)
    staging = staging_root / str(uuid.uuid4())

    downloader(spec.repository, spec.revision, staging)
    validate_model_directory(staging, spec)

    ready = {
        "modelId": spec.repository,
        "revision": spec.revision,
        "expectedBytes": spec.expected_bytes,
        "weightSHA256": spec.weight_sha256,
    }
    (staging / "ready.json").write_text(
        json.dumps(ready, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    os.replace(staging, destination)
    return destination
