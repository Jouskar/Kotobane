# Third-party notices

Kotobane is distributed under the MIT License. The optional local
transcription stack is made from independently licensed third-party projects.
This file identifies the versions pinned by `helper/requirements.lock`; it does
not replace the license text distributed by each project.

## Models and ML backend

| Component | Version or revision | License | Upstream license reference |
| --- | --- | --- | --- |
| Qwen3-ASR 0.6B | `5eb144179a02acc5e5ba31e748d22b0cf3e303b0` | Apache-2.0 | [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B/blob/main/LICENSE) |
| Qwen3-ASR 1.7B | `7278e1e70fe206f11671096ffdd38061171dd6e5` | Apache-2.0 | [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B/blob/main/LICENSE) |
| MLX | 0.32.0 | MIT | [ml-explore/mlx](https://github.com/ml-explore/mlx/blob/main/LICENSE) |
| MLX Metal | 0.32.0 | MIT | [ml-explore/mlx](https://github.com/ml-explore/mlx/blob/main/LICENSE) |
| mlx-qwen3-asr | 0.3.5, source `d1a035514e1d6ac31da7658b273482656eacba61` | Apache-2.0 | [Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio/blob/main/LICENSE) |

Model weights are not distributed in this repository or in `Kotobane.app`.
They are downloaded only after an explicit user action.

## Pinned Python helper dependencies

| Package | Version | License | Upstream license reference |
| --- | --- | --- | --- |
| anyio | 4.14.2 | MIT | [agronholm/anyio](https://github.com/agronholm/anyio/blob/master/LICENSE) |
| certifi | 2026.7.22 | MPL-2.0 | [certifi/python-certifi](https://github.com/certifi/python-certifi/blob/master/LICENSE) |
| click | 8.4.2 | BSD-3-Clause | [pallets/click](https://github.com/pallets/click/blob/main/LICENSE.txt) |
| filelock | 3.32.0 | Unlicense | [tox-dev/filelock](https://github.com/tox-dev/filelock/blob/main/LICENSE) |
| fsspec | 2026.6.0 | BSD-3-Clause | [fsspec/filesystem_spec](https://github.com/fsspec/filesystem_spec/blob/master/LICENSE) |
| h11 | 0.16.0 | MIT | [python-hyper/h11](https://github.com/python-hyper/h11/blob/master/LICENSE.txt) |
| hf-xet | 1.5.2 | Apache-2.0 | [huggingface/xet-core](https://github.com/huggingface/xet-core/blob/main/LICENSE) |
| httpcore | 1.0.9 | BSD-3-Clause | [encode/httpcore](https://github.com/encode/httpcore/blob/master/LICENSE.md) |
| httpx | 0.28.1 | BSD-3-Clause | [encode/httpx](https://github.com/encode/httpx/blob/master/LICENSE.md) |
| huggingface-hub | 1.24.0 | Apache-2.0 | [huggingface/huggingface_hub](https://github.com/huggingface/huggingface_hub/blob/main/LICENSE) |
| idna | 3.18 | BSD-3-Clause | [kjd/idna](https://github.com/kjd/idna/blob/master/LICENSE.md) |
| numpy | 2.5.1 | BSD-3-Clause | [numpy/numpy](https://github.com/numpy/numpy/blob/main/LICENSE.txt) |
| packaging | 26.2 | Apache-2.0 OR BSD-2-Clause | [pypa/packaging](https://github.com/pypa/packaging/blob/main/LICENSE) |
| PyYAML | 6.0.3 | MIT | [yaml/pyyaml](https://github.com/yaml/pyyaml/blob/main/LICENSE) |
| regex | 2026.7.19 | Apache-2.0 | [mrabarnett/mrab-regex](https://github.com/mrabarnett/mrab-regex/blob/hg/LICENSE.txt) |
| tqdm | 4.69.1 | MPL-2.0 AND MIT | [tqdm/tqdm](https://github.com/tqdm/tqdm/blob/master/LICENCE) |
| typing-extensions | 4.16.0 | PSF-2.0 | [python/typing_extensions](https://github.com/python/typing_extensions/blob/main/LICENSE) |

`mlx`, `mlx-metal`, and `mlx-qwen3-asr` are listed in both sections where
appropriate so the full pinned helper environment and its major ML components
are unambiguous.

The pinned CPython 3.12 runtime is provided by
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
and contains CPython and other components under their respective upstream
licenses. See the license files included in the downloaded runtime.
