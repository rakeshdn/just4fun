#!/bin/bash
#
# tts.sh - Streaming text-to-speech with Piper and RAM-based buffering
#
# Reads a text file, splits it into sentence chunks, generates audio with
# Piper TTS into RAM, and plays them sequentially. Works on macOS and Linux.
# WAV files are created and deleted on-the-fly to minimize memory usage.
#
# Usage:
#   ./tts.sh [model.onnx] <text_file> [sentences_per_chunk] [speed]
#
# Arguments:
#   model.onnx          - Piper voice model (optional, defaults to danny)
#   text_file           - Plain text file to read aloud
#   sentences_per_chunk - Number of sentences per audio chunk (default: 3)
#   speed               - Length scale: 1.0=normal, <1=faster, >1=slower
#
# Environment:
#   RAMDISK - Path to RAM-backed directory (default: auto-detected)
#   PLAYER  - Audio player command (default: auto-detected)
#
# Dependencies:
#   piper    - https://github.com/OHF-Voice/piper1-gpl
#   python3  - For text splitting and timestamps
#   player   - afplay (macOS) or paplay/aplay/play/ffplay (Linux)
#
# Example:
#   ./tts.sh voices/en_US-danny-low.onnx book.txt 5 0.8
#

# ── OS detection ──────────────────────────────────────────────────────────
case "$OSTYPE" in
    darwin*) OS=macos ;;
    linux*)  OS=linux ;;
    *)       echo "Unsupported OS: $OSTYPE"; exit 1 ;;
esac

# ── Dependency check ──────────────────────────────────────────────────────
for cmd in piper python3; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done
PIPER=$(command -v piper)

# ── Resolve script directory (for relative voice model paths) ──────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_MODEL="$SCRIPT_DIR/voices/en_US-danny-low.onnx"

# ── Argument parsing ──────────────────────────────────────────────────────
# If first arg is an .onnx file, treat it as the model; otherwise use default
if [[ "$1" == *.onnx ]]; then
    MODEL="$1"
    INPUT="${2:?Provide a text file}"
    CHUNK_SIZE="${3:-3}"
    SPEED="${4:-1.0}"
else
    MODEL="$DEFAULT_MODEL"
    INPUT="${1:?Provide a text file}"
    CHUNK_SIZE="${2:-3}"
    SPEED="${3:-1.0}"
fi

# ── Audio player auto-detection ───────────────────────────────────────────
detect_player() {
    case "$OS" in
        macos)
            command -v afplay && return
            ;;
        linux)
            for p in paplay aplay play ffplay; do
                command -v "$p" >/dev/null && echo "$p" && return
            done
            echo "No audio player found. Install sox, alsa-utils, or ffmpeg." >&2
            exit 1
            ;;
    esac
}
PLAYER="${PLAYER:-$(detect_player)}"
echo "[INFO] Using player: $PLAYER ($OS)"

# ── RAM disk configuration ────────────────────────────────────────────────
# WAV files go to RAM to avoid SSD wear.
setup_ramdisk() {
    case "$OS" in
        macos)
            RAMDISK="${RAMDISK:-/Volumes/RamDiskTTS}"
            if [ ! -d "$RAMDISK" ]; then
                local sectors=$((32 * 1024 * 1024 / 512))  # 32MB
                local dev=$(hdiutil attach -nobrowse -nomount ram://$sectors | tr -d '[:space:]')
                diskutil erasevolume HFS+ 'RamDiskTTS' "$dev" >/dev/null 2>&1
                for i in 1 2 3 4 5; do
                    df -k "$RAMDISK" >/dev/null 2>&1 && break
                    sleep 0.2
                done
                echo "[INFO] Created 32MB RAM disk at $RAMDISK"
            fi
            ;;
        linux)
            if [ -n "$RAMDISK" ]; then
                mkdir -p "$RAMDISK"
            else
                RAMDISK=$(mktemp -d /dev/shm/tts-XXXXXX)
            fi
            ;;
    esac
}
setup_ramdisk

# RAM budget: max 32MB
RAMDISK_MAX=33554432  # 32MB
AVAIL=$(df -k "$RAMDISK" 2>/dev/null | awk -v max="$RAMDISK_MAX" 'NR==2 {avail = $4 * 1024; print (avail < max) ? avail : max}')
echo "[INFO] RAM disk: $RAMDISK, budget: $((AVAIL / 1024))KB"

# ── Cleanup trap ──────────────────────────────────────────────────────────
cleanup() {
    case "$OS" in
        macos) rm -rf "$RAMDISK"/* ;;
        linux)
            if [[ "$RAMDISK" == /dev/shm/tts-* ]]; then
                rm -rf "$RAMDISK"
            else
                rm -rf "$RAMDISK"/*
            fi
            ;;
    esac
}
trap cleanup EXIT

# ── Utility functions ─────────────────────────────────────────────────────

# High-resolution timestamp for trace output
ts() { python3 -c "from datetime import datetime; print(datetime.now().strftime('%H:%M:%S.%f')[:-3])"; }

# Current RAM disk usage in bytes (for backpressure)
ram_used() {
    du -sk "$RAMDISK" 2>/dev/null | awk '{print $1 * 1024}'
}

# Generate WAV by piping text directly to piper (no temp txt files)
generate_chunk() {
    local idx=$1
    local text="$2"
    local wav="$RAMDISK/chunk_${idx}.wav"
    local min_free=512000  # 500KB

    # Safety: block until enough space is available
    while true; do
        local used=$(ram_used)
        local free=$((AVAIL - used))
        [ "$free" -ge "$min_free" ] && break
        echo "[$(ts)] [TRACE] BACKPRESSURE chunk_${idx}: waiting (free=$((free / 1024))KB)"
        sleep 0.2
    done

    rm -f "$wav" "$wav.done"
    echo "$text" | $PIPER -m "$MODEL" --length-scale "$SPEED" -f "$wav"
    touch "$wav.done"
    echo "[$(ts)] [TRACE] CREATED chunk_${idx}.wav ($(du -h "$wav" 2>/dev/null | cut -f1))"
}

# ── Split input text into chunks and store in array ──────────────────────
# Uses Python to split on sentence boundaries (.!?), groups N sentences per chunk.
CHUNKS=()
while IFS= read -r line; do
    CHUNKS+=("$line")
done < <(python3 -c "
import re, sys
text = open(sys.argv[1]).read().strip()
sentences = re.split(r'(?<=[.!?])\s+', text)
n = int(sys.argv[2])
for i in range(0, len(sentences), n):
    print(' '.join(sentences[i:i+n]))
" "$INPUT" "$CHUNK_SIZE")

total=${#CHUNKS[@]}
echo "[$(ts)] [TRACE] $total chunks to process"

# ── Background generator ──────────────────────────────────────────────────
# Generates WAV files as fast as possible, pausing when RAM disk is full.
# Resumes automatically as playback frees space.
generator_pid=""
for ((j = 0; j < total; j++)); do
    if [ -f "$RAMDISK/chunk_${j}.wav.done" ]; then continue; fi
    generate_chunk "$j" "${CHUNKS[$j]}" &
done

# ── Play chunks in order ──────────────────────────────────────────────────
for ((i = 0; i < total; i++)); do
    # Wait for WAV to be fully generated (.done marker)
    while [ ! -f "$RAMDISK/chunk_${i}.wav.done" ]; do sleep 0.1; done

    echo "[$(ts)] [TRACE] PLAYING chunk_${i}.wav ($(du -h "$RAMDISK/chunk_${i}.wav" 2>/dev/null | cut -f1))"
    $PLAYER "$RAMDISK/chunk_${i}.wav"
    rm -f "$RAMDISK/chunk_${i}.wav" "$RAMDISK/chunk_${i}.wav.done"
    echo "[$(ts)] [TRACE] DELETED chunk_${i}.wav"
done

# ── Wait for any lingering background jobs ───────────────────────────────
wait
echo "[$(ts)] [TRACE] Done. RAM disk clean: $(ls "$RAMDISK" 2>/dev/null | wc -l | tr -d ' ') files"
