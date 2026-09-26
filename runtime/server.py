"""Fn-flow local ASR server.

Serves NVIDIA Parakeet (via parakeet-mlx) on localhost. The app launches and
stops this process itself; it can also be run by hand:

    .venv/bin/python server.py --port 8765
"""

import argparse
import os
import shutil
import sys
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


UNK = "<unk>"
DIAGNOSTICS = Path(__file__).resolve().parent / "diagnostics"


def tokens(result):
    return [token for sentence in result.sentences for token in sentence.tokens]


def count_unk(result):
    return sum(token.text.count(UNK) for token in tokens(result))


def payload(result):
    """Transcript, sentence timings, and word timings, with any <unk> tokens removed.

    Sentence timings let the app stream: it keeps only text that was followed by more
    speech, and re-transcribes the rest with the next audio. Word timings (sub-word tokens
    merged, punctuation attached) let it do that for run-on speech too.
    """
    sentences = []
    for sentence in result.sentences:
        kept = [t for t in sentence.tokens if UNK not in t.text]
        text = "".join(t.text for t in kept).strip()
        if text:
            sentences.append({"text": text, "start": round(kept[0].start, 3), "end": round(kept[-1].end, 3)})

    merged = []
    for token in tokens(result):
        if UNK in token.text:
            continue
        if token.text.startswith(" ") or not merged:
            merged.append({"text": token.text.strip(), "start": token.start, "end": token.end})
        else:
            merged[-1]["text"] += token.text
            merged[-1]["end"] = token.end
    words = [
        {"text": w["text"], "start": round(w["start"], 3), "end": round(w["end"], 3)}
        for w in merged
        if w["text"]
    ]
    return {"text": " ".join(s["text"] for s in sentences), "sentences": sentences, "words": words}


def save_diagnostic(path, unk):
    """Keep the audio that produced <unk> (newest 10) so the cause can be reproduced."""
    try:
        DIAGNOSTICS.mkdir(exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy(path, DIAGNOSTICS / f"unk-{stamp}-{unk}.wav")
        for old in sorted(DIAGNOSTICS.glob("unk-*.wav"))[:-10]:
            old.unlink()
    except OSError as exc:
        print(f"could not save diagnostic audio: {exc}", file=sys.stderr, flush=True)


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
        model = get_model()
        result = model.transcribe(path)
        unk = count_unk(result)
        if unk:
            # Parakeet occasionally emits a run of <unk> (a degenerate decode; the same
            # audio transcribes fine moments later). Retry once and keep the better result.
            save_diagnostic(path, unk)
            retry = model.transcribe(path)
            retry_unk = count_unk(retry)
            print(f"<unk> x{unk} in {Path(path).name}; retry gave x{retry_unk}", file=sys.stderr, flush=True)
            if retry_unk < unk:
                result, unk = retry, retry_unk
        return {
            **payload(result),
            # <unk> tokens left after the retry (already removed from the text).
            "unk_tokens": unk,
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
