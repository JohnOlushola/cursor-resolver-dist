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
RESOLVER_HOME="${HOME}/.resolver"
VENV="${RESOLVER_HOME}/venv"
LOG_FILE="${RESOLVER_HOME}/install.log"

# Resolve the wheel URL from the latest release. Wheel filenames must follow
# PEP 427 ({name}-{version}-...), so we can't host a "resolver-latest" alias —
# we look up the real versioned wheel via the GitHub API.
resolve_wheel_url() {
    if [[ -n "${RESOLVER_WHEEL_URL:-}" ]]; then
        echo "$RESOLVER_WHEEL_URL"
        return
    fi
    curl -fsSL "https://api.github.com/repos/${DIST_REPO}/releases/latest" 2>/dev/null \
        | grep -oE '"browser_download_url": *"[^"]*resolver-[0-9][^"]*\.whl"' \
        | head -1 \
        | sed 's/.*"\(http[^"]*\)"/\1/'
}

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
    WHEEL_URL=$(resolve_wheel_url)
    if [[ -z "$WHEEL_URL" ]]; then
        die "Could not find a wheel in the latest release of ${DIST_REPO}. Check that a release with a 'resolver-X.Y.Z-py3-none-any.whl' asset exists."
    fi
    echo "[wheel: $(basename "$WHEEL_URL")]" >&3
    uv venv "$VENV" --python 3.12 >&3 2>&1 \
        || die "uv venv failed (need Python 3.12 — uv will fetch it)"
    uv pip install --python "${VENV}/bin/python" "${WHEEL_URL}" >&3 2>&1 \
        || die "uv pip install failed (URL: ${WHEEL_URL})"
    ok
fi

# Step 4b: Embedder backend
# The wheel doesn't include sentence-transformers / mlx-embeddings (they're
# optional extras to keep the wheel small). Pick the right one for the host.
step "Installing embedder backend"
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    EMBEDDER_PKG="mlx-embeddings"
    EMBEDDER_PROBE="mlx_embeddings"
else
    EMBEDDER_PKG="sentence-transformers"
    EMBEDDER_PROBE="sentence_transformers"
fi
if "${VENV}/bin/python" -c "import ${EMBEDDER_PROBE}" 2>/dev/null; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] would install ${EMBEDDER_PKG}"
else
    echo "[${EMBEDDER_PKG}]" >&3
    uv pip install --python "${VENV}/bin/python" "${EMBEDDER_PKG}" >&3 2>&1 \
        || die "${EMBEDDER_PKG} install failed"
    ok
fi

# Step 5: spaCy model
# spaCy's `python -m spacy download` shells out to pip, which doesn't
# exist in a uv-created venv. Install the model wheel directly via uv.
step "Downloading spaCy en_core_web_sm"
if [[ -d "${VENV}/lib/python3.12/site-packages/en_core_web_sm" ]]; then
    skip
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]"
else
    SPACY_VER=$("${VENV}/bin/python" -c "import spacy; print(spacy.__version__)" 2>/dev/null)
    if [[ -z "$SPACY_VER" ]]; then
        die "spaCy not importable in venv (install step 4 may have silently failed)"
    fi
    # Map spaCy 3.X.Y to model 3.X.0 — spaCy guarantees minor-version compat for models.
    MODEL_VER="${SPACY_VER%.*}.0"
    MODEL_URL="https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-${MODEL_VER}/en_core_web_sm-${MODEL_VER}-py3-none-any.whl"
    uv pip install --python "${VENV}/bin/python" "${MODEL_URL}" >&3 2>&1 \
        || die "spaCy model install failed (URL: ${MODEL_URL})"
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
    elif sudo -n true 2>/dev/null; then
        # Passwordless sudo available — use it for /usr/local/bin
        sudo ln -sf "${VENV}/bin/resolver" /usr/local/bin/resolver \
            || die "sudo ln failed"
        sudo ln -sf "${VENV}/bin/resolver-mcp" /usr/local/bin/resolver-mcp \
            || die "sudo ln failed"
        ok
    else
        # No write access to /usr/local/bin and sudo would prompt for a
        # password (which curl|bash can't supply) — fall back to ~/.local/bin.
        mkdir -p "${HOME}/.local/bin"
        ln -sf "${VENV}/bin/resolver" "${HOME}/.local/bin/resolver"
        ln -sf "${VENV}/bin/resolver-mcp" "${HOME}/.local/bin/resolver-mcp"
        ok
        # Tell the user how to get this on PATH if it isn't.
        case ":${PATH}:" in
            *":${HOME}/.local/bin:"*) ;;
            *)
                echo "  ℹ Linked to ~/.local/bin (sudo would have prompted)."
                echo "    Add to PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
                echo "    Or symlink manually: sudo ln -sf ${VENV}/bin/resolver /usr/local/bin/"
                ;;
        esac
    fi
fi

echo
echo "✓ Done."
echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Required: grant Full Disk Access"
echo "──────────────────────────────────────────────────────────────────"
echo "  The engine runs under launchd, which doesn't inherit your"
echo "  Terminal's privacy permissions. Without FDA, reads of iMessage,"
echo "  Mail, Notes, Safari, etc. will silently fail."
echo
echo "  1. Open: System Settings → Privacy & Security → Full Disk Access"
echo "  2. Click '+' (you may need to authenticate)"
echo "  3. In the file picker, press Cmd+Shift+G and paste:"
echo
echo "     ${VENV}/bin/python3.12"
echo
echo "  4. Toggle the new entry ON"
echo "──────────────────────────────────────────────────────────────────"
echo
echo "Next:"
echo "   resolver start              # start the engine (auto-starts at login)"
echo "   resolver mcp install        # register with Claude Desktop"
echo "   resolver doctor             # verify everything healthy"
