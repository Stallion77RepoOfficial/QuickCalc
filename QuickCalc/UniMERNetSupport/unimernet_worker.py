#!/usr/bin/env python3

import argparse
import contextlib
import json
import os
import sys
import traceback
import warnings
from pathlib import Path

os.environ.setdefault("NO_ALBUMENTATIONS_UPDATE", "1")


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class UniMERNetWorker:
    def __init__(self, model_dir: Path, device_name: str, log_file: Path):
        self.model_dir = model_dir
        self.device_name = device_name
        self.log_file = log_file
        self.model = None
        self.processor = None

    @contextlib.contextmanager
    def redirected_logs(self):
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        with self.log_file.open("a", encoding="utf-8") as log_handle:
            log_handle.write("\n=== worker event ===\n")
            log_handle.flush()
            with contextlib.redirect_stdout(log_handle), contextlib.redirect_stderr(log_handle), warnings.catch_warnings():
                warnings.simplefilter("ignore")
                yield

    def load(self) -> None:
        if self.model is not None:
            return

        with self.redirected_logs():
            import torch
            from omegaconf import OmegaConf
            from unimernet.models.unimernet.unimernet import UniMERModel
            from unimernet.processors.formula_processor import FormulaImageEvalProcessor

            checkpoint = next(self.model_dir.glob("*.pth"))
            cfg = OmegaConf.create(
                {
                    "model_name": str(self.model_dir),
                    "model_config": {
                        "model_name": str(self.model_dir),
                        "max_seq_len": 1536,
                    },
                    "tokenizer_name": str(self.model_dir),
                    "tokenizer_config": {"path": str(self.model_dir)},
                    "load_pretrained": True,
                    "pretrained": str(checkpoint),
                }
            )

            self.model = UniMERModel.from_config(cfg).to(self.device_name)
            self.model.eval()
            self.processor = FormulaImageEvalProcessor(image_size=[192, 672])

    def recognize(self, image_path: Path) -> str:
        self.load()

        with self.redirected_logs():
            import torch
            from PIL import Image

            image = Image.open(image_path).convert("RGB")
            tensor = self.processor(image).unsqueeze(0).to(self.device_name)

            with torch.inference_mode():
                output = self.model.generate({"image": tensor}, do_sample=False)

            return output["pred_str"][0]


def serve(model_dir: Path, device_name: str, log_file: Path) -> int:
    worker = UniMERNetWorker(model_dir=model_dir, device_name=device_name, log_file=log_file)

    try:
        worker.load()
        emit(
            {
                "type": "ready",
                "ok": True,
            }
        )
    except Exception:
        with log_file.open("a", encoding="utf-8") as log_handle:
            log_handle.write(traceback.format_exc())
        emit(
            {
                "type": "ready",
                "ok": False,
                "error_code": "startup_failed",
            }
        )
        return 1

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
            request_id = request["id"]
            image_path = Path(request["image_path"]).expanduser().resolve()
            latex = worker.recognize(image_path)
            emit(
                {
                    "type": "result",
                    "id": request_id,
                    "ok": True,
                    "latex": latex,
                }
            )
        except Exception:
            with log_file.open("a", encoding="utf-8") as log_handle:
                log_handle.write(traceback.format_exc())
            emit(
                {
                    "type": "result",
                    "id": request.get("id") if "request" in locals() else None,
                    "ok": False,
                    "error_code": "inference_failed",
                }
            )

    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", required=True, choices=["mps", "cpu"])
    parser.add_argument("--log-file", required=True)
    args = parser.parse_args()

    model_dir = Path(args.model_dir).expanduser().resolve()
    log_file = Path(args.log_file).expanduser().resolve()

    if not model_dir.exists():
        emit({"type": "ready", "ok": False, "error_code": "model_missing"})
        return 2

    return serve(model_dir=model_dir, device_name=args.device, log_file=log_file)


if __name__ == "__main__":
    raise SystemExit(main())
