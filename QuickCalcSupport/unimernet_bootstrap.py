#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

BOOTSTRAP_VERSION = 2
MODEL_REPO_ID = "wanderkid/unimernet_base"
MODEL_FILE_NAME = "pytorch_model.pth"


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> None:
    subprocess.run(
        cmd,
        check=True,
        env=env,
        stdout=sys.stderr,
        stderr=sys.stderr,
    )


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def state_is_current(state_path: Path, python_path: Path, model_dir: Path) -> bool:
    if not state_path.exists():
        return False

    if not python_path.exists():
        return False

    if not (model_dir / MODEL_FILE_NAME).exists():
        return False

    try:
        state = json.loads(state_path.read_text())
    except Exception:
        return False

    return (
        state.get("bootstrap_version") == BOOTSTRAP_VERSION
        and state.get("model_repo_id") == MODEL_REPO_ID
    )


def ensure_venv(venv_dir: Path) -> Path:
    python_path = venv_dir / "bin" / "python"
    if not python_path.exists():
        run([sys.executable, "-m", "venv", str(venv_dir)])
    return python_path


def ensure_package(python_path: Path) -> None:
    check = subprocess.run(
        [str(python_path), "-m", "pip", "show", "unimernet"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if check.returncode == 0:
        return

    run([str(python_path), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])
    run([str(python_path), "-m", "pip", "install", "-U", "unimernet[full]"])


def ensure_model(python_path: Path, model_dir: Path) -> None:
    if (model_dir / MODEL_FILE_NAME).exists():
        return

    command = f"""
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id={MODEL_REPO_ID!r},
    local_dir={str(model_dir)!r},
)
"""
    run(
        [str(python_path), "-c", command],
        env={
            **os.environ,
            "HF_HUB_DISABLE_SYMLINKS_WARNING": "1",
            "NO_ALBUMENTATIONS_UPDATE": "1",
        },
    )


def write_state(state_path: Path, python_path: Path, model_dir: Path) -> None:
    payload = {
        "bootstrap_version": BOOTSTRAP_VERSION,
        "model_repo_id": MODEL_REPO_ID,
        "python_path": str(python_path),
        "model_dir": str(model_dir),
    }
    state_path.write_text(json.dumps(payload, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-support-dir", required=True)
    args = parser.parse_args()

    app_support_dir = Path(args.app_support_dir).expanduser().resolve()
    runtime_dir = app_support_dir / "runtime"
    models_dir = app_support_dir / "models"
    logs_dir = app_support_dir / "logs"
    venv_dir = runtime_dir / "unimernet-venv"
    model_dir = models_dir / "unimernet_base"
    state_path = app_support_dir / "bootstrap-state.json"

    ensure_dir(app_support_dir)
    ensure_dir(runtime_dir)
    ensure_dir(models_dir)
    ensure_dir(logs_dir)
    ensure_dir(model_dir)

    python_path = venv_dir / "bin" / "python"
    if not state_is_current(state_path, python_path, model_dir):
        python_path = ensure_venv(venv_dir)
        ensure_package(python_path)
        ensure_model(python_path, model_dir)
        write_state(state_path, python_path, model_dir)

    sys.stdout.write(
        json.dumps(
            {
                "ok": True,
                "python_path": str(python_path),
                "model_dir": str(model_dir),
            }
        )
        + "\n"
    )
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
