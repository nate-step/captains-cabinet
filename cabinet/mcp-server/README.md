# cabinet/mcp-server

Phase 1 CP8 prototype — Cabinet MCP stdio server. One tool: `cabinet:identify()`.

## What it returns

```json
{
  "cabinet_id": "main",
  "captain_id": "Nate",
  "available_agents": ["cos", "cto", "cpo", "cro", "coo"],
  "server": { "name": "cabinet", "version": "0.1.0" }
}
```

## Why this exists

Captain directive `cabinet-v2.md` Part 3: Phase 1 must ship a Cabinet MCP prototype to de-risk Phase 2 inter-Cabinet communication. The single tool `identify()` is the minimum sufficient surface — every Phase 2 protocol call starts with identity discovery, so getting it right now prevents Phase 2 rewrites.

Captain decision 2026-04-16 CD5: **stdio transport for Phase 1 prototype, HTTP-compatible signature**. The tool shape above is identical to what Phase 2 will expose over HTTP. Only the transport layer changes.

## Smoke test

```bash
(
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"identify"}}'
) | python3 /opt/founders-cabinet/cabinet/mcp-server/server.py
```

## Registering with Claude Code

Add to `.mcp.json`:

```json
{
  "mcpServers": {
    "cabinet": {
      "command": "python3",
      "args": ["/opt/founders-cabinet/cabinet/mcp-server/server.py"]
    }
  }
}
```

Not registered yet in Phase 1 — registration is a Phase 2 step when inter-Cabinet calls actually need to discover each other. The server is usable via direct subprocess or manual JSON-RPC piping today.

## Env vars

- `CABINET_ID` — override default `main`
- `CAPTAIN_ID` — override; falls back to `product.captain_name`
- `CABINET_ROOT` — override framework root (default `/opt/founders-cabinet`)

## Caller expectations

- `captain_id` may be `"unknown"` if both `$CAPTAIN_ID` env is unset AND `product.captain_name` is missing. Treat this as a soft signal (misconfiguration or fresh Cabinet), not an error.
- `available_agents` is the hired-agent list (scaffolds are excluded). An empty list means no agents are hired yet.
- `server.version` follows semver and will bump on any response-shape change.

## Known Phase-2 TODO

- The tiny regex-based YAML parser in `read_hired_agents` works for the current flat yaml. Swap for `yaml.safe_load()` when Phase 2 adds nested scope structures (per-Cabinet overrides) — the regex approach won't scale to that.
