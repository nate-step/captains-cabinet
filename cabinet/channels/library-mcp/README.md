# Library MCP Server

MCP server exposing The Library — Founder's Cabinet's structured-edit layer — as tool calls.

## Architecture

Delegates to `library.sh` via `child_process.exec`. All SQL injection safety, embedding logic (voyage-4-large via memory.sh), and JSON validation live in the Bash layer. The MCP server is a thin adapter.

## Registration (already in .mcp.json)

```json
"library": {
  "command": "bun",
  "args": ["run", "/opt/founders-cabinet/cabinet/channels/library-mcp/index.ts"],
  "env": { "OFFICER_NAME": "${OFFICER_NAME}" }
}
```

The server reads `NEON_CONNECTION_STRING` and `VOYAGE_API_KEY` from `cabinet/.env` at startup.

## Tools

| Tool | Description |
|------|-------------|
| `library_create_space` | Create or upsert a Space (collection) |
| `library_list_spaces` | List all Spaces |
| `library_create_record` | Create a record with embedding |
| `library_update_record` | Update record, preserves version history |
| `library_get_record` | Fetch record + full version history |
| `library_search` | Semantic search via cosine similarity |
| `library_list_records` | List active records in a Space |
| `library_delete_record` | Soft-delete (data preserved) |

## Running locally

```bash
OFFICER_NAME=cos bun run /opt/founders-cabinet/cabinet/channels/library-mcp/index.ts
```

## Testing with JSON-RPC

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | \
  OFFICER_NAME=cos bun run /opt/founders-cabinet/cabinet/channels/library-mcp/index.ts
```
