from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT))

import model_install
from model_install import (
    InsufficientCapacityError,
    MODEL_SPECS,
    ModelValidationError,
    UnsupportedModelError,
    install_model,
)


SMALL_REPOSITORY = "Qwen/Qwen3-ASR-0.6B"


def write_complete_model(directory: Path, repository: str = SMALL_REPOSITORY):
    directory.mkdir(parents=True, exist_ok=True)
    for name in MODEL_SPECS[repository].required_files:
        (directory / name).write_bytes(b"{}")


class ModelInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.destination = self.root / "models" / "qwen3-asr-0.6b"
        self.spec = replace(
            MODEL_SPECS[SMALL_REPOSITORY],
            weight_sha256={
                "model.safetensors": hashlib.sha256(b"{}").hexdigest()
            },
        )
        spec_patch = mock.patch.dict(
            MODEL_SPECS,
            {SMALL_REPOSITORY: self.spec},
        )
        spec_patch.start()
        self.addCleanup(spec_patch.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def test_insufficient_capacity_fails_before_backend_download(self):
        downloader = mock.Mock()
        required = self.spec.expected_bytes + max(
            1024**3, self.spec.expected_bytes // 10
        )

        with self.assertRaises(InsufficientCapacityError):
            install_model(
                SMALL_REPOSITORY,
                self.destination,
                self.spec.expected_bytes,
                required - 1,
                downloader=downloader,
            )

        downloader.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_invalid_staging_is_never_marked_ready(self):
        def incomplete_download(repository, revision, local_dir):
            local_dir.mkdir(parents=True)
            (local_dir / "config.json").write_text("{}", encoding="utf-8")

        with self.assertRaises(ModelValidationError):
            install_model(
                SMALL_REPOSITORY,
                self.destination,
                self.spec.expected_bytes,
                self.spec.expected_bytes + 2 * 1024**3,
                downloader=incomplete_download,
            )

        staging = list((self.destination.parent / ".staging").iterdir())
        self.assertEqual(len(staging), 1)
        self.assertFalse((staging[0] / "ready.json").exists())
        self.assertFalse(self.destination.exists())

    def test_corrupted_weight_is_rejected_before_activation(self):
        def corrupt_download(repository, revision, local_dir):
            write_complete_model(local_dir)
            (local_dir / "model.safetensors").write_bytes(b"corrupted")

        with self.assertRaises(ModelValidationError):
            install_model(
                SMALL_REPOSITORY,
                self.destination,
                self.spec.expected_bytes,
                self.spec.expected_bytes + 2 * 1024**3,
                downloader=corrupt_download,
            )

        staging = list((self.destination.parent / ".staging").iterdir())
        self.assertEqual(len(staging), 1)
        self.assertFalse((staging[0] / "ready.json").exists())
        self.assertFalse(self.destination.exists())

    def test_successful_validation_is_atomically_activated_with_pinned_revision(self):
        calls = []

        def download(repository, revision, local_dir):
            calls.append((repository, revision, local_dir))
            write_complete_model(local_dir)

        real_replace = os.replace
        replacements = []

        def recording_replace(source, destination):
            replacements.append((Path(source), Path(destination)))
            return real_replace(source, destination)

        with mock.patch.object(model_install.os, "replace", recording_replace):
            installed = install_model(
                SMALL_REPOSITORY,
                self.destination,
                self.spec.expected_bytes,
                self.spec.expected_bytes + 2 * 1024**3,
                downloader=download,
            )

        self.assertEqual(installed, self.destination)
        self.assertEqual(calls[0][0], SMALL_REPOSITORY)
        self.assertEqual(calls[0][1], self.spec.revision)
        self.assertEqual(replacements[-1][1], self.destination)
        ready = json.loads((self.destination / "ready.json").read_text())
        self.assertEqual(ready["modelId"], SMALL_REPOSITORY)
        self.assertEqual(ready["revision"], self.spec.revision)
        self.assertEqual(ready["expectedBytes"], self.spec.expected_bytes)

    def test_interrupted_download_leaves_only_removable_staging_data(self):
        def interrupted_download(repository, revision, local_dir):
            local_dir.mkdir(parents=True)
            (local_dir / "partial.tmp").write_bytes(b"partial")
            raise ConnectionError("connection lost")

        with self.assertRaises(ConnectionError):
            install_model(
                SMALL_REPOSITORY,
                self.destination,
                self.spec.expected_bytes,
                self.spec.expected_bytes + 2 * 1024**3,
                downloader=interrupted_download,
            )

        self.assertFalse(self.destination.exists())
        staging = list((self.destination.parent / ".staging").iterdir())
        self.assertEqual(len(staging), 1)
        self.assertEqual(
            [path.name for path in staging[0].iterdir()],
            ["partial.tmp"],
        )

    def test_rejects_unconfigured_repository_before_download(self):
        downloader = mock.Mock()

        with self.assertRaises(UnsupportedModelError):
            install_model(
                "other/model",
                self.destination,
                1,
                3 * 1024**3,
                downloader=downloader,
            )

        downloader.assert_not_called()


if __name__ == "__main__":
    unittest.main()
