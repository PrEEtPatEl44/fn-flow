#!/bin/bash
# Nemotron Flow local runtime installer.
#
# Installs, fully locally and without touching the system Python:
#   - uv (into the runtime dir) and a Python 3.12 venv
#   - parakeet-mlx + a tiny FastAPI server  -> NVIDIA Parakeet ASR on Apple Silicon
#   - Ollama's nemotron-mini model          -> NVIDIA Nemotron text refinement
#
# Safe to re-run: every step is idempotent ("Install / Repair" in Settings runs this).

set -euo pipefail

RUNTIME_DIR="${NEMOTRON_FLOW_RUNTIME_DIR:-$HOME/Library/Application Support/NemotronFlow/runtime}"
ASR_MODEL="${NEMOTRON_FLOW_ASR_MODEL:-mlx-community/parakeet-tdt-0.6b-v2}"
LLM_MODEL="${NEMOTRON_FLOW_LLM_MODEL:-nemotron-mini}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$RUNTIME_DIR/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

step() { echo; echo "==> $*"; }

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: Parakeet (MLX) requires an Apple Silicon Mac." >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR/bin"

step "1/6 uv (Python package manager)"
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$RUNTIME_DIR/bin" INSTALLER_NO_MODIFY_PATH=1 sh
fi
uv --version

step "2/6 Python environment"
if [[ ! -x "$RUNTIME_DIR/.venv/bin/python" ]]; then
    uv venv --python 3.12 "$RUNTIME_DIR/.venv"
fi
cp "$SCRIPT_DIR/server.py" "$RUNTIME_DIR/server.py"

step "3/6 Parakeet ASR packages"
VIRTUAL_ENV="$RUNTIME_DIR/.venv" uv pip install --python "$RUNTIME_DIR/.venv/bin/python" \
    "parakeet-mlx>=0.5" "fastapi>=0.115" "uvicorn>=0.30" "python-multipart>=0.0.9"

step "4/6 ffmpeg (audio decoding)"
if ! command -v ffmpeg >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        brew install ffmpeg
    else
        echo "WARNING: ffmpeg not found and Homebrew unavailable; install ffmpeg manually." >&2
    fi
fi

step "5/6 Downloading Parakeet model ($ASR_MODEL)"
"$RUNTIME_DIR/.venv/bin/python" -c "
from parakeet_mlx import from_pretrained
from_pretrained('$ASR_MODEL')
print('Parakeet model ready.')
"
echo "$ASR_MODEL" > "$RUNTIME_DIR/asr_model"

step "6/6 Nemotron LLM via Ollama ($LLM_MODEL)"
if ! command -v ollama >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        brew install ollama
    else
        echo "ERROR: Ollama is required. Install it from https://ollama.com/download" >&2
        exit 1
    fi
fi
if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null; then
    echo "Starting Ollama..."
    (nohup ollama serve >/dev/null 2>&1 &)
    for _ in $(seq 1 30); do
        curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break
        sleep 1
    done
fi
ollama pull "$LLM_MODEL"

echo
echo "INSTALL_OK: Nemotron Flow runtime is ready in $RUNTIME_DIR"
