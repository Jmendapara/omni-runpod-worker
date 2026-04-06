#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Interactive setup script for debugging OmniVoice on a RunPod pod.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Jmendapara/omni-runpod-worker/main/scripts/setup-pod.sh | bash
# =============================================================================

# Use python3 explicitly (python may not exist on slim pods)
PY="$(command -v python3 || command -v python)"
PIP="$(command -v pip3 || command -v pip)"

echo "=========================================="
echo "  OmniVoice RunPod Setup Script"
echo "=========================================="

# ---------- Step 0: System info ----------
echo ""
echo "[0/7] System info..."
nvidia-smi --query-gpu=gpu_name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "  (no GPU detected)"
echo "  Python: $PY ($($PY --version 2>&1))"
$PY -c "import torch; print(f'  torch {torch.__version__}, CUDA: {torch.cuda.is_available()}')" 2>/dev/null || echo "  torch: not yet installed"

# ---------- Step 1: Install system deps ----------
echo ""
echo "[1/7] Installing system dependencies..."
apt-get update -qq && apt-get install -y -qq ffmpeg libsndfile1 git wget curl > /dev/null 2>&1
echo "  Done."

# ---------- Step 2: Install ComfyUI ----------
echo ""
echo "[2/7] Installing ComfyUI..."
if [ ! -d /workspace/ComfyUI ]; then
    cd /workspace
    git clone https://github.com/comfyanonymous/ComfyUI.git
    cd ComfyUI
    $PIP install -r requirements.txt -q
else
    echo "  ComfyUI already exists at /workspace/ComfyUI"
    cd /workspace/ComfyUI
    echo "  Ensuring ComfyUI requirements are installed..."
    $PIP install -r requirements.txt -q
fi

echo "  Verifying torch after ComfyUI install..."
$PY -c "import torch; print(f'  torch {torch.__version__}, CUDA: {torch.cuda.is_available()}')" 2>/dev/null || echo "  WARNING: torch still not available"

# ---------- Step 3: Install OmniVoice custom node ----------
echo ""
echo "[3/7] Installing ComfyUI-OmniVoice-TTS custom node..."
mkdir -p /workspace/ComfyUI/custom_nodes
cd /workspace/ComfyUI/custom_nodes
if [ ! -d ComfyUI-OmniVoice-TTS ]; then
    git clone https://github.com/Saganaki22/ComfyUI-OmniVoice-TTS.git
else
    echo "  Node already cloned."
fi

# ---------- Step 4: Install OmniVoice Python deps ----------
echo ""
echo "[4/7] Installing OmniVoice Python dependencies..."
$PIP install omnivoice --no-deps -q
$PIP install pydub soundfile scipy lazy_loader librosa sentencepiece jieba soxr accelerate -q
$PIP install "transformers>=5.3.0" -q
echo "  Done."

# ---------- Step 5: Verify packages ----------
echo ""
echo "[5/7] Verifying packages..."
$PY -c "
import sys
print(f'Python: {sys.executable} ({sys.version})')
checks = {
    'torch': lambda: __import__('torch').__version__,
    'torch.cuda': lambda: str(__import__('torch').cuda.is_available()),
    'PIL (Pillow)': lambda: __import__('PIL').__version__,
    'transformers': lambda: __import__('transformers').__version__,
    'omnivoice': lambda: getattr(__import__('omnivoice'), '__version__', 'installed'),
    'torchaudio': lambda: __import__('torchaudio').__version__,
    'librosa': lambda: __import__('librosa').__version__,
    'soxr': lambda: __import__('soxr').__version__,
    'pydub': lambda: 'installed' if __import__('pydub') else '',
    'soundfile': lambda: __import__('soundfile').__version__,
}
for name, check in checks.items():
    try:
        ver = check()
        print(f'  OK  {name} = {ver}')
    except Exception as e:
        print(f'  FAIL {name}: {e}')
"

# ---------- Step 6: Download model ----------
echo ""
echo "[6/7] Downloading OmniVoice model..."
mkdir -p /workspace/ComfyUI/models/omnivoice
mkdir -p /workspace/ComfyUI/models/audio_encoders

if [ ! -f /workspace/ComfyUI/models/omnivoice/OmniVoice/model.safetensors ]; then
    $PIP install "huggingface_hub[hf_xet]" -q
    $PY -c "
from huggingface_hub import snapshot_download
print('Downloading OmniVoice fp32...')
snapshot_download('k2-fsa/OmniVoice', local_dir='/workspace/ComfyUI/models/omnivoice/OmniVoice')
print('Done.')
print()
print('Downloading Whisper large-v3-turbo...')
snapshot_download('openai/whisper-large-v3-turbo', local_dir='/workspace/ComfyUI/models/audio_encoders/openai_whisper-large-v3-turbo')
print('Done.')
"
else
    echo "  Model already downloaded."
fi

echo ""
echo "  Models:"
ls -la /workspace/ComfyUI/models/omnivoice/ 2>/dev/null || echo "  (empty)"
ls -la /workspace/ComfyUI/models/audio_encoders/ 2>/dev/null || echo "  (empty)"

# ---------- Step 7: Start ComfyUI ----------
echo ""
echo "[7/7] Starting ComfyUI..."
echo ""
echo "=========================================="
echo "  ComfyUI will start on port 8188"
echo ""
echo "  To test the API from another terminal:"
echo "    curl http://127.0.0.1:8188/"
echo "=========================================="
echo ""

cd /workspace/ComfyUI
$PY main.py --listen --disable-auto-launch --verbose DEBUG --log-stdout
