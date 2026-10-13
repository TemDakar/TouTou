#!/usr/bin/env python3
"""Cursor event adapter. Observational hooks never change permissions."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import uuid


def data_directory():
    override = os.environ.get("TOUTOU_DATA_DIR") or os.environ.get("TOUTU_DATA_DIR")
    return Path(override) if override else Path.home() / "Library/Application Support/TouTou/events"


def normalize(payload, event):
    roots = payload.get("workspace_roots") or []
    project = payload.get("cwd") or (roots[0] if roots else "Cursor")
    session = str(payload.get("conversation_id") or payload.get("session_id") or project)
    details = {
        "sessionStart": "Сессия началась",
        "sessionEnd": "Сессия закрыта",
        "beforeSubmitPrompt": "Агент получил задачу",
        "afterShellExecution": "Команда выполнена",
        "afterFileEdit": "Файл обновлён",
        "afterAgentResponse": "Ответ готов",
        "stop": "Задача завершена",
        "postToolUseFailure": "Инструмент сообщил об ошибке",
    }
    detail = details.get(event, "Агент работает")
    # Do not retain prompts, thought traces, command output or file content.
    if event == "afterFileEdit" and payload.get("file_path"):
        detail += ": " + str(payload["file_path"])[-300:]
    state = "done" if event in {"stop", "afterAgentResponse", "sessionEnd"} else "working"
    if event == "postToolUseFailure" or (event == "stop" and payload.get("status") in {"error", "aborted"}):
        state = "error"
    return {
        "id": str(uuid.uuid4()), "session": session[:512], "agent": "Cursor",
        "project": str(project)[-512:], "state": state, "detail": detail,
        "timestamp": time.time(),
    }


def write_event(event, directory=None):
    directory = Path(directory) if directory is not None else data_directory()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    # One atomic snapshot per session: bounded disk use, no growing transcript.
    import hashlib
    target = directory / (hashlib.sha256(event["session"].encode()).hexdigest() + ".json")
    fd, temp = tempfile.mkstemp(prefix=".event-", dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(event, handle, ensure_ascii=False)
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    for path in directory.glob("*.json"):
        try:
            if time.time() - path.stat().st_mtime > 86400:
                path.unlink()
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("event")
    args = parser.parse_args()
    try:
        raw = sys.stdin.read(262145)
        if len(raw) > 262144:
            raise ValueError("Hook payload too large")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("Expected JSON object")
        write_event(normalize(payload, args.event))
    except (OSError, ValueError, TypeError, IndexError) as exc:
        print("TouTou: " + str(exc), file=sys.stderr)
    print("{}")


if __name__ == "__main__":
    main()
