#!/usr/bin/env bash
# install.sh — bootstrap resolver on macOS
#
# Usage:
#   curl -fsSL https://johnolushola.github.io/cursor-resolver-dist/install.sh | bash
#   curl -fsSL <url> | bash -s -- --no-ollama
#
# Idempotent: re-running skips already-done steps.

set -euo pipefail

# --- config ---
DIST_REPO="${RESOLVER_DIST_REPO:-JohnOlushola/cursor-resolver-dist}"
WHEEL_URL="${RESOLVER_WHEEL_URL:-https://github.com/${DIST_REPO}/releases/latest/download/resolver-latest-py3-none-any.whl}"
RESOLVER_HOME="${HOME}/.resolver"
VENV="${RESOLVER_HOME}/venv"
LOG_FILE="${RESOLVER_HOME}/install.log"

# --- flags ---
NO_OLLAMA=0
for arg in "$@"; do
    case "$arg" in
        --no-ollama) NO_OLLAMA=1 ;;
        --help|-h)
            cat <<EOF
resolver installer

Usage: install.sh [--no-ollama]

  --no-ollama   Skip Ollama and model downloads (lighter install,
                file-content extraction degrades to spaCy-only).

After install:
  resolver start
  resolver mcp install
  resolver doctor
EOF
            exit 0
            ;;
    esac
done

# --- dry-run / test support ---
DRY_RUN="${RESOLVER_DRY_RUN:-0}"
FAKE_OS="${RESOLVER_FAKE_OS:-}"

# --- helpers ---
step() { printf "▸ %-50s" "$1"; }
ok() { echo "[✓]"; }
skip() { echo "[skip — already done]"; }
die() {
    echo "[✗]"
    echo
    echo "ERROR: $*" >&2
    if [[ -f "$LOG_FILE" ]]; then
        echo "Last 20 lines of $LOG_FILE:" >&2
        tail -n 20 "$LOG_FILE" >&2 || true
    fi
    exit 1
}

# --- start ---
mkdir -p "$RESOLVER_HOME"

# In dry-run, redirect logs to /dev/null to avoid touching ~/.resolver
if [[ "$DRY_RUN" == "1" ]]; then
    exec 3>/dev/null
else
    exec 3>>"$LOG_FILE"
fi

echo "▸ resolver installer"

# Step 1: platform check
step "Detecting platform"
OS="${FAKE_OS:-$(uname -s)}"
if [[ "$OS" != "Darwin" ]]; then
    die "macOS required (detected: $OS)"
fi
ok

# Step 2: install uv
step "Installing uv"
if command -v uv >/dev/null 2>&1; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    curl -LsSf https://astral.sh/uv/install.sh | sh >&3 2>&1 \
        || die "uv install failed"
    # uv installs to ~/.local/bin or ~/.cargo/bin; add to PATH for this shell
    export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
    ok
fi

# Step 3: create resolver home
step "Setting up ~/.resolver/"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    mkdir -p "${RESOLVER_HOME}/logs" "${RESOLVER_HOME}/snapshots"
    ok
fi

# Step 4: venv + install
step "Installing Python 3.12 + resolver"
if [[ -d "$VENV" && -f "${VENV}/bin/resolver" ]]; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    uv venv "$VENV" --python 3.12 >&3 2>&1 \
        || die "uv venv failed (need Python 3.12 — uv will fetch it)"
    uv pip install --python "${VENV}/bin/python" "${WHEEL_URL}" >&3 2>&1 \
        || die "uv pip install failed (wheel may not exist yet — see ${WHEEL_URL})"
    ok
fi

# Step 5: spaCy model
step "Downloading spaCy en_core_web_sm"
if [[ -d "${VENV}/lib/python3.12/site-packages/en_core_web_sm" ]]; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    "${VENV}/bin/python" -m spacy download en_core_web_sm >&3 2>&1 \
        || die "spaCy download failed"
    ok
fi

# Step 6: Ollama
step "Checking Ollama"
if [[ "$NO_OLLAMA" == "1" ]]; then
    echo "[Skipping Ollama — --no-ollama]"
elif command -v ollama >/dev/null 2>&1; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    curl -fsSL https://ollama.com/install.sh | sh >&3 2>&1 \
        || die "Ollama install failed"
    ok
fi

if [[ "$NO_OLLAMA" == "0" ]]; then
    step "Pulling qwen2.5:3b"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run]"
    elif ollama list 2>/dev/null | grep -q "qwen2.5:3b"; then
        skip
    else
        ollama pull qwen2.5:3b >&3 2>&1 || die "ollama pull failed"
        ok
    fi
fi

# Step 7: link CLI to /usr/local/bin (or fall back to ~/.local/bin)
step "Linking resolver to PATH"
if [[ -L "/usr/local/bin/resolver" && -L "/usr/local/bin/resolver-mcp" ]]; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    if [[ -w "/usr/local/bin" ]]; then
        ln -sf "${VENV}/bin/resolver" /usr/local/bin/resolver
        ln -sf "${VENV}/bin/resolver-mcp" /usr/local/bin/resolver-mcp
        ok
    elif command -v sudo >/dev/null 2>&1; then
        sudo ln -sf "${VENV}/bin/resolver" /usr/local/bin/resolver \
            && sudo ln -sf "${VENV}/bin/resolver-mcp" /usr/local/bin/resolver-mcp
        ok
    else
        # Fall back to ~/.local/bin
        mkdir -p "${HOME}/.local/bin"
        ln -sf "${VENV}/bin/resolver" "${HOME}/.local/bin/resolver"
        ln -sf "${VENV}/bin/resolver-mcp" "${HOME}/.local/bin/resolver-mcp"
        ok
        echo "  (Linked to ~/.local/bin; ensure that's on your PATH.)"
    fi
fi

echo
echo "✓ Done."
echo
echo "Next:"
echo "   resolver start              # start the engine (auto-starts at login)"
echo "   resolver mcp install        # register with Claude Desktop"
echo "   resolver doctor             # verify everything healthy"
