# cursor-resolver distribution

Public distribution channel for [cursor-resolver](https://github.com/JohnOlushola/cursor-resolver) (private).

## Install

```bash
curl -fsSL https://johnolushola.github.io/cursor-resolver-dist/install.sh | bash
```

After install:

```bash
resolver start
resolver mcp install
resolver doctor
```

Then restart Claude Desktop.

## Flags

- `--no-ollama` — skip Ollama install. File-content entity extraction degrades to spaCy-only.

## What's in this repo

- `install.sh` — bootstrap script (this is what the curl pipes into bash)
- Releases — built wheels published as release assets, fetched by `install.sh` and `resolver update`

The resolver source lives in a separate private repo. This repo only hosts the distributed artifacts.
