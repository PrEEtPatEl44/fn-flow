"""Fn-flow local ASR server.

Serves NVIDIA Parakeet (via parakeet-mlx) on localhost. The app launches and
stops this process itself; it can also be run by hand:

    .venv/bin/python server.py --port 8765
"""

import argparse
import os
import tempfile
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from parakeet_mlx import from_pretrained

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"

app = FastAPI(title="Fn-flow Runtime")
_model = None
_model_name = os.environ.get("FN_FLOW_ASR_MODEL", DEFAULT_MODEL)


def get_model():
    global _model
    if _model is None:
        _model = from_pretrained(_model_name)
    return _model


@app.get("/health")
def health():
    return {"status": "ok", "asr_model": _model_name, "loaded": _model is not None}


# async on purpose: MLX streams are thread-local, so inference must stay on the
# event-loop thread that loaded the model (sync endpoints run in a threadpool).
@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await file.read())
        path = tmp.name
    try:
        start = time.perf_counter()
        result = get_model().transcribe(path)
        return {
            "text": result.text.strip(),
            "duration_ms": int((time.perf_counter() - start) * 1000),
        }
    except Exception as exc:  # surfaced to the app as a readable error
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        os.unlink(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    get_model()  # warm up so the first dictation is fast
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
