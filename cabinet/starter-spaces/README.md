# Starter Spaces

Pre-defined Space templates for The Library. Install with:

```bash
bash cabinet/scripts/install-starter-space.sh <template>
```

## Template format

Each starter is a single JSON file at `cabinet/starter-spaces/<name>.json`:

```json
{
  "name": "Human-readable Space name (unique)",
  "description": "Short description shown in the dashboard",
  "starter_template": "identifier matching the filename minus .json",
  "schema_json": {
    "fields": [
      {"name": "priority", "type": "select", "options": ["P0", "P1", "P2", "P3"]},
      {"name": "due_date", "type": "date"},
      {"name": "assignee", "type": "text"}
    ]
  },
  "access_rules": {
    "read": ["*"],
    "write": ["cos", "cto"],
    "comment": ["*"]
  }
}
```

**Field types (MVP):**

| Type | Stored as | Notes |
|------|-----------|-------|
| `text` | JSONB string | Single-line text input |
| `markdown` | JSONB string | Multi-line, rendered as markdown |
| `number` | JSONB number | Integer or float |
| `date` | JSONB ISO-8601 string | `YYYY-MM-DD` |
| `datetime` | JSONB ISO-8601 string | `YYYY-MM-DDThh:mm:ssZ` |
| `select` | JSONB string from `options` | Single choice |
| `multi_select` | JSONB array of strings | Multi-choice from `options` |
| `boolean` | JSONB true/false | Checkbox in UI |
| `relation` | JSONB `{space, record_id}` | FK to another record |

**Access rules:** officer abbreviations (e.g., `cos`, `cto`) or `*` for anyone. `read`, `write`, `comment` are independent. Rules are enforced on all `library.sh` operations and the Library MCP server. Captain (`OFFICER_NAME=captain`) always bypasses access_rules. Dashboard API routes run as captain context and are not subject to officer access checks.

## Adding a new starter

1. Create `cabinet/starter-spaces/<name>.json` matching the format above
2. Test with `bash cabinet/scripts/install-starter-space.sh <name>`
3. Verify the Space appears in Neon (`library_list_spaces` or dashboard)

Once Phase 0 preset refactor lands, starter-spaces/ will move under `presets/work/starter-spaces/` and `presets/personal/starter-spaces/`. Until then they live here.

## Shipped starters

- **blank** — empty Space with no custom fields. Freeform title + markdown + labels only.

More starters ship in Sprint B and C (Issues, Business Brain, Research Archive, Decisions Log, Playbooks, Team Handbook, Customer Insights, ADR).
