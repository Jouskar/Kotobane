#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys
import time


def completed(request):
    return {
        "id": request["id"],
        "status": "completed",
        "text": "Merhaba",
        "detectedLanguage": "tr",
        "durationSeconds": 1.25,
    }


line = sys.stdin.readline()
request = json.loads(line)
audio_path = Path(request["audioPath"])
mode = audio_path.stem

if mode == "timeout":
    marker = Path(str(audio_path) + ".terminated")

    def terminate(_signal, _frame):
        with marker.open("a", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, terminate)
    while True:
        time.sleep(1)
elif mode == "crash":
    print("fixture crash", file=sys.stderr, flush=True)
    raise SystemExit(17)
elif mode == "eof":
    raise SystemExit(0)
elif mode == "malformed":
    print("{", flush=True)
elif mode == "unknown":
    print(json.dumps({"id": request["id"], "status": "progress"}), flush=True)
elif mode == "mismatch":
    response = completed(request)
    response["id"] = "00000000-0000-0000-0000-000000000002"
    print(json.dumps(response, sort_keys=True), flush=True)
elif mode == "failed-model":
    print(
        json.dumps(
            {
                "id": request["id"],
                "status": "failed",
                "code": "model_unavailable",
                "message": "Install the selected model",
            },
            sort_keys=True,
        ),
        flush=True,
    )
else:
    if mode == "stderr-success":
        print("diagnostic only", file=sys.stderr, flush=True)
    assert os.environ["HF_HUB_OFFLINE"] == "1"
    assert os.environ["TRANSFORMERS_OFFLINE"] == "1"
    assert os.environ["NO_PROXY"] == "*"
    print(json.dumps(completed(request), sort_keys=True), flush=True)
