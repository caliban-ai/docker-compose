# secrets

Operator credential files go here. Contents are **gitignored** — only this
README and `.gitkeep` are tracked.

Used by `overlays/secrets.yaml`. One secret per file, no trailing newline:

    printf %s 'sk-ant-...' > anthropic_api_key
    chmod 600 anthropic_api_key

Each file is mounted at `/run/secrets/<name>` and exported as its UPPERCASED
name (`anthropic_api_key` → `ANTHROPIC_API_KEY`).
