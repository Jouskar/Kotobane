#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys
import time


if len(sys.argv) >= 4 and sys.argv[1] == "-p":
    profile = sys.argv[2]
    assert profile == "(version 1)\n(allow default)\n(deny network*)\n"
    if os.environ.get("KOTOBANE_FAKE_SANDBOX_MODE") == "reject":
        print("fixture sandbox rejected profile", file=sys.stderr, flush=True)
        raise SystemExit(78)
    os.execv(sys.argv[3], sys.argv[3:])


def completed(request):
    return {
        "id": request["id"],
        "status": "completed",
        "text": "Merhaba",
        "detectedLanguage": "tr",
        "durationSeconds": 1.25,
    }


forced_mode = sys.argv[1] if len(sys.argv) > 1 else None
forced_marker = Path(sys.argv[2]) if len(sys.argv) > 2 else None

if forced_mode == "exit-before-read-once" and forced_marker is not None:
    if not forced_marker.exists():
        with forced_marker.open("a", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")
        raise SystemExit(17)
elif forced_mode == "non-reading" and forced_marker is not None:
    with forced_marker.open("a", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)

line = sys.stdin.readline()
request = json.loads(line)
audio_path = Path(request["audioPath"])
mode = forced_mode or audio_path.stem

if mode in {
    "cancel-hostile",
    "delayed-second-record",
    "hostile-timeout",
    "hostile-descendant-timeout",
    "oversized-stdout",
    "oversized-stderr",
}:
    marker = Path(str(audio_path) + ".pids")
    with marker.open("a", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")

if mode == "timeout":
    marker = Path(str(audio_path) + ".terminated")

    def terminate(_signal, _frame):
        with marker.open("a", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, terminate)
    while True:
        time.sleep(1)
elif mode in {"cancel-hostile", "hostile-timeout"}:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
elif mode == "hostile-descendant-timeout":
    child = os.fork()
    if child == 0:
        with marker.open("a", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            time.sleep(1)
    while True:
        time.sleep(1)
elif mode == "delayed-second-record":
    response = json.dumps(completed(request), sort_keys=True)
    print(response, flush=True)
    time.sleep(0.2)
    print(response, flush=True)
elif mode == "oversized-stdout":
    print("x" * 2048, flush=True)
elif mode == "oversized-stderr":
    print("x" * 2048, file=sys.stderr, flush=True)
    print(json.dumps(completed(request), sort_keys=True), flush=True)
elif mode == "descendant-held-pipe":
    child = os.fork()
    if child == 0:
        marker = Path(str(audio_path) + ".descendant-pid")
        with marker.open("w", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")
        time.sleep(1.5)
        os._exit(0)
    print(json.dumps(completed(request), sort_keys=True), flush=True)
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
