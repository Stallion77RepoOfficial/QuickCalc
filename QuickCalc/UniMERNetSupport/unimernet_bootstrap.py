#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

BOOTSTRAP_VERSION = 3
UNIMERNET_VERSION = "0.2.3"
MODEL_FILE_NAME = "pytorch_model.pth"
MODEL_VARIANTS = {
    "base": {
        "repo_id": "wanderkid/unimernet_base",
        "directory_name": "unimernet_base",
    },
    "small": {
        "repo_id": "wanderkid/unimernet_small",
        "directory_name": "unimernet_small",
    },
    "tiny": {
        "repo_id": "wanderkid/unimernet_tiny",
        "directory_name": "unimernet_tiny",
    },
}


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


def ensure_supported_python() -> None:
    version = sys.version_info
    if version.major != 3 or version.minor < 10:
        raise RuntimeError("python_3_10_or_newer_required")


def package_is_current(python_path: Path) -> bool:
    check = subprocess.run(
        [
            str(python_path),
            "-c",
            (
                "import importlib.metadata as metadata; "
                "print(metadata.version('unimernet'))"
            ),
        ],
        capture_output=True,
        text=True,
    )
    if check.returncode != 0:
        return False

    return check.stdout.strip() == UNIMERNET_VERSION


def state_is_current(state_path: Path, python_path: Path, model_dir: Path, model_repo_id: str) -> bool:
    if not state_path.exists():
        return False

    if not python_path.exists():
        return False

    if not (model_dir / MODEL_FILE_NAME).exists():
        return False

    if not package_is_current(python_path):
        return False

    try:
        state = json.loads(state_path.read_text())
    except Exception:
        return False

    return (
        state.get("bootstrap_version") == BOOTSTRAP_VERSION
        and state.get("unimernet_version") == UNIMERNET_VERSION
        and state.get("model_repo_id") == model_repo_id
    )


def ensure_venv(venv_dir: Path) -> Path:
    python_path = venv_dir / "bin" / "python"
    if not python_path.exists():
        run([sys.executable, "-m", "venv", str(venv_dir)])
    return python_path


def ensure_package(python_path: Path) -> None:
    check = subprocess.run(
        [
            str(python_path),
            "-c",
            (
                "import importlib.metadata as metadata; "
                "print(metadata.version('unimernet'))"
            ),
        ],
        capture_output=True,
        text=True,
    )
    if check.returncode == 0 and check.stdout.strip() == UNIMERNET_VERSION:
        return

    run([str(python_path), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])
    run([str(python_path), "-m", "pip", "install", f"unimernet[full]=={UNIMERNET_VERSION}"])


def ensure_model(python_path: Path, model_dir: Path, model_repo_id: str) -> None:
    if (model_dir / MODEL_FILE_NAME).exists():
        return

    command = f"""
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id={model_repo_id!r},
    local_dir={str(model_dir)!r},
    resume_download=True,
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


def write_state(state_path: Path, python_path: Path, model_dir: Path, model_name: str, model_repo_id: str) -> None:
    payload = {
        "bootstrap_version": BOOTSTRAP_VERSION,
        "unimernet_version": UNIMERNET_VERSION,
        "model_name": model_name,
        "model_repo_id": model_repo_id,
        "python_path": str(python_path),
        "model_dir": str(model_dir),
    }
    state_path.write_text(json.dumps(payload, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-support-dir", required=True)
    parser.add_argument("--model", choices=sorted(MODEL_VARIANTS.keys()), required=True)
    args = parser.parse_args()

    ensure_supported_python()

    model_config = MODEL_VARIANTS[args.model]
    model_repo_id = model_config["repo_id"]
    model_dir_name = model_config["directory_name"]

    app_support_dir = Path(args.app_support_dir).expanduser().resolve()
    runtime_dir = app_support_dir / "runtime"
    models_dir = app_support_dir / "models"
    logs_dir = app_support_dir / "logs"
    venv_dir = runtime_dir / "unimernet-venv"
    model_dir = models_dir / model_dir_name
    state_path = app_support_dir / f"bootstrap-state-{args.model}.json"

    ensure_dir(app_support_dir)
    ensure_dir(runtime_dir)
    ensure_dir(models_dir)
    ensure_dir(logs_dir)
    ensure_dir(model_dir)

    python_path = venv_dir / "bin" / "python"
    if not state_is_current(state_path, python_path, model_dir, model_repo_id):
        python_path = ensure_venv(venv_dir)
        ensure_package(python_path)
        ensure_model(python_path, model_dir, model_repo_id)
        write_state(state_path, python_path, model_dir, args.model, model_repo_id)

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
