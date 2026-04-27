#!/usr/bin/env bun
/**
 * Library MCP Server — Founder's Cabinet structured-edit layer
 *
 * Exposes library.sh CRUD operations as MCP tools so Officers can
 * read/write Library Spaces and Records via tool calls.
 *
 * Strategy: delegate to library.sh via child_process.exec — reuses
 * all validated Bash logic including SQL injection safety and embedding.
 *
 * Usage: OFFICER_NAME=cos bun run index.ts
 * Or via .mcp.json as an MCP server.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "node:child_process";

const LIBRARY_SH = "/opt/founders-cabinet/cabinet/scripts/lib/library.sh";
const ENV_FILE = "/opt/founders-cabinet/cabinet/.env";

// ---------------------------------------------------------------
// Shell helper — sources .env + library.sh then calls a function.
// Args are passed via environment variables (_LIB_ARG_0, _LIB_ARG_1, ...)
// so no shell injection is possible regardless of arg content. The
// script body is piped to `bash -s` via stdin — no temp file on disk,
// no /tmp race, no cleanup (Apr 17 reviewer fix: prior impl wrote a
// 0700 script into /tmp per call, predictable enough for a local race
// on shared hosts).
// ---------------------------------------------------------------
// Read OFFICER_NAME at request time from env (not cached at startup)
function getOfficerName(): string {
  return process.env.OFFICER_NAME || "system";
}

// Returned by callLibrary when the shell script exits non-zero
class LibraryAccessError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LibraryAccessError";
  }
}

async function callLibrary(fn: string, args: string[]): Promise<string> {
  // Pass each argument as a named env var — zero shell injection risk
  const envVars: Record<string, string> = {};
  args.forEach((arg, i) => {
    envVars[`_LIB_ARG_${i}`] = arg;
  });

  const argRefs = args.map((_, i) => `"$_LIB_ARG_${i}"`).join(" ");

  const script = [
    `set -a`,
    `source "${ENV_FILE}" 2>/dev/null || true`,
    `set +a`,
    `source "${LIBRARY_SH}"`,
    `${fn} ${argRefs}`,
  ].join("\n");

  // Pipe the script to `bash -s` via stdin — no disk artifact, no race.
  // Capture stdout + stderr into buffers with a maxBuffer cap so a
  // runaway library.sh call can't exhaust memory.
  const MAX_BUFFER = 10 * 1024 * 1024;
  const TIMEOUT_MS = 60_000;

  const result = await new Promise<{stdout: string; stderr: string; code: number | null}>((resolve, reject) => {
    const child = spawn("bash", ["-s"], {
      env: {
        ...process.env,
        OFFICER_NAME: getOfficerName(),
        ...envVars,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let killedForOverflow = false;

    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`library.sh call timed out after ${TIMEOUT_MS}ms (fn=${fn})`));
    }, TIMEOUT_MS);

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (stdout.length > MAX_BUFFER && !killedForOverflow) {
        killedForOverflow = true;
        child.kill("SIGKILL");
        reject(new Error(`library.sh stdout exceeded maxBuffer (${MAX_BUFFER} bytes, fn=${fn})`));
      }
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      if (stderr.length > MAX_BUFFER && !killedForOverflow) {
        killedForOverflow = true;
        child.kill("SIGKILL");
        reject(new Error(`library.sh stderr exceeded maxBuffer (${MAX_BUFFER} bytes, fn=${fn})`));
      }
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      if (killedForOverflow) return; // reject already fired
      resolve({ stdout, stderr, code });
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });

    child.stdin.end(script);
  });

  if (result.stderr) {
    if (result.stderr.includes("access denied")) {
      throw new LibraryAccessError(
        result.stderr.split("\n").find((l) => l.includes("access denied")) ?? "Access denied"
      );
    }
    process.stderr.write(`[library.sh stderr] ${result.stderr}\n`);
  }

  return result.stdout.trim();
}

// ---------------------------------------------------------------
// Output parsers — convert tab-separated psql output to objects
// ---------------------------------------------------------------

function parseSpaces(raw: string): object[] {
  if (!raw) return [];
  return raw.split("\n").filter(Boolean).map((line) => {
    const [id, name, description, starter_template, owner, created_at] =
      line.split("\t");
    return { id, name, description, starter_template, owner, created_at };
  });
}

function parseRecord(raw: string): object | null {
  if (!raw) return null;
  const lines = raw.split("\n").filter(Boolean);
  if (!lines.length) return null;
  const [
    id, space_id, title, content_markdown, schema_data_str,
    labels_str, version, superseded_by, created_by_officer,
    created_at, updated_at
  ] = lines[0].split("\t");
  let schema_data: object = {};
  try { schema_data = JSON.parse(schema_data_str || "{}"); } catch {}
  return {
    id,
    space_id,
    title,
    content_markdown,
    schema_data,
    labels: labels_str ? labels_str.split(",").filter(Boolean) : [],
    version: parseInt(version, 10),
    superseded_by: superseded_by || null,
    created_by_officer,
    created_at,
    updated_at,
  };
}

function parseHistory(raw: string): object[] {
  if (!raw) return [];
  return raw.split("\n").filter(Boolean).map((line) => {
    const [id, version, title, status, created_at] = line.split("\t");
    return {
      id,
      version: parseInt(version, 10),
      title,
      status: status === "HEAD" ? "active" : `superseded_by:${status}`,
      created_at,
    };
  });
}

function parseSearchResults(raw: string): object[] {
  if (!raw) return [];
  return raw.split("\n").filter(Boolean).map((line) => {
    const [space_id, id, title, similarity, preview, officer, created_at] =
      line.split("\t");
    return {
      id,
      space_id,
      title,
      similarity: parseFloat(similarity),
      preview,
      created_by_officer: officer,
      created_at,
    };
  });
}

function parseListRecords(raw: string): object[] {
  if (!raw) return [];
  return raw.split("\n").filter(Boolean).map((line) => {
    const [id, title, labels_str, preview, version, officer, created_at] =
      line.split("\t");
    return {
      id,
      title,
      labels: labels_str ? labels_str.split(",").filter(Boolean) : [],
      preview,
      version: parseInt(version, 10),
      created_by_officer: officer,
      created_at,
    };
  });
}

// ---------------------------------------------------------------
// MCP Server setup
// ---------------------------------------------------------------
const server = new Server(
  { name: "library-mcp", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

// ---------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "library_create_space",
      description:
        "Create or update a Library Space. Spaces are user-defined collections with optional JSON schema, starter template, and access rules. If the name already exists, description/schema/access_rules are updated (upsert).",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string", description: "Unique space name" },
          description: { type: "string", description: "Human-readable description" },
          schema_json: {
            type: "string",
            description:
              'JSON string defining custom fields, e.g. {"fields":[{"name":"priority","type":"select","options":["P1","P2"]}]}',
          },
          starter_template: {
            type: "string",
            description: 'Template hint: blank | issues | business_brain | research_archive',
          },
          access_rules: {
            type: "string",
            description:
              'JSON string, e.g. {"read":["*"],"write":["cos","cto"]}',
          },
        },
        required: ["name"],
      },
    },
    {
      name: "library_list_spaces",
      description: "List all Library Spaces with id, name, description, template, owner, and creation date.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "library_create_record",
      description:
        "Create a new record in a Space. Accepts either a space id (numeric) or space name. Generates a voyage-4-large embedding for semantic search.",
      inputSchema: {
        type: "object",
        properties: {
          space_id_or_name: {
            type: "string",
            description: "Numeric space id or exact space name",
          },
          title: { type: "string", description: "Record title" },
          content_markdown: { type: "string", description: "Main body in Markdown" },
          schema_data: {
            type: "string",
            description: "JSON string of custom field values per the Space schema",
          },
          labels: {
            type: "string",
            description: "Comma-separated labels, e.g. blocker,v1",
          },
        },
        required: ["space_id_or_name", "title"],
      },
    },
    {
      name: "library_update_record",
      description:
        "Update an existing record. Creates a new version row and marks the old one as superseded (full version history preserved). Returns the new record id and version number.",
      inputSchema: {
        type: "object",
        properties: {
          record_id: { type: "string", description: "Existing record id" },
          title: { type: "string", description: "New title" },
          content_markdown: { type: "string", description: "New body in Markdown" },
          schema_data: { type: "string", description: "JSON string of updated custom fields" },
          labels: { type: "string", description: "Comma-separated labels" },
        },
        required: ["record_id", "title"],
      },
    },
    {
      name: "library_get_record",
      description:
        "Fetch a record by id. Returns the full record plus version history chain.",
      inputSchema: {
        type: "object",
        properties: {
          record_id: { type: "string", description: "Record id to fetch" },
        },
        required: ["record_id"],
      },
    },
    {
      name: "library_get_backlinks",
      description:
        "Get the records that link IN to a target record via [[wikilink]] syntax. Returns up to 50 source records with title, source space, link text, ±40 char context, and link position.",
      inputSchema: {
        type: "object",
        properties: {
          record_id: { type: "string", description: "Target record id" },
        },
        required: ["record_id"],
      },
    },
    {
      name: "library_graph_data",
      description:
        "Returns the [[wiki-link]] network as JSON {nodes: [{id, title, space_id, degree}], edges: [{source, target}]} for graph-view rendering. Top-N nodes by degree. Default limit_nodes=500; pass space_ids to scope to one or more Spaces.",
      inputSchema: {
        type: "object",
        properties: {
          space_ids: {
            type: "string",
            description:
              "Optional comma-separated Space ids (e.g., '12,15'). Omit for cross-Space.",
          },
          limit_nodes: {
            type: "number",
            description: "Max nodes returned (default 500, top-N by degree)",
          },
        },
      },
    },
    {
      name: "library_search",
      description:
        "Semantic search across Library Records using voyage-4-large embeddings. Returns top-K records ordered by cosine similarity.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Natural language search query" },
          space: {
            type: "string",
            description: "Optional space id or name to restrict search",
          },
          labels: {
            type: "string",
            description: "Optional comma-separated labels to filter by",
          },
          limit: {
            type: "number",
            description: "Max results (default 10)",
          },
        },
        required: ["query"],
      },
    },
    {
      name: "library_list_records",
      description:
        "List active records in a Space, newest first. Accepts space id or space name.",
      inputSchema: {
        type: "object",
        properties: {
          space_id_or_name: {
            type: "string",
            description: "Numeric space id or exact space name",
          },
          limit: { type: "number", description: "Max records (default 50)" },
        },
        required: ["space_id_or_name"],
      },
    },
    {
      name: "library_delete_record",
      description:
        "Soft-delete a record (marks it superseded_by itself). Record data is preserved for auditing. Cannot be undone via MCP.",
      inputSchema: {
        type: "object",
        properties: {
          record_id: { type: "string", description: "Record id to delete" },
        },
        required: ["record_id"],
      },
    },
  ],
}));

// ---------------------------------------------------------------
// Tool call handler
// ---------------------------------------------------------------
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;

  try {
    switch (name) {
      // ---- library_create_space ----
      case "library_create_space": {
        const { name: spaceName, description = "", schema_json = "{}", starter_template = "blank", access_rules = "{}" } = args as any;
        const raw = await callLibrary("library_create_space", [
          spaceName, description, schema_json, starter_template,
          process.env.OFFICER_NAME || "system", access_rules,
        ]);
        const id = raw.trim();
        if (!id) throw new Error("Space creation failed — check space name is not empty");
        return {
          content: [{ type: "text", text: JSON.stringify({ id, name: spaceName }) }],
        };
      }

      // ---- library_list_spaces ----
      case "library_list_spaces": {
        const raw = await callLibrary("library_list_spaces", []);
        const spaces = parseSpaces(raw);
        return {
          content: [{ type: "text", text: JSON.stringify(spaces) }],
        };
      }

      // ---- library_create_record ----
      case "library_create_record": {
        const { space_id_or_name, title, content_markdown = "", schema_data = "{}", labels = "" } = args as any;

        // Resolve name → id if needed
        let spaceId = space_id_or_name;
        if (!/^\d+$/.test(spaceId)) {
          spaceId = await callLibrary("library_space_id", [space_id_or_name]);
          if (!spaceId) throw new Error(`Space not found: ${space_id_or_name}`);
        }

        const raw = await callLibrary("library_create_record", [
          spaceId, title, content_markdown, schema_data, labels,
        ]);
        const id = raw.trim();
        if (!id) throw new Error("Record creation failed — ensure title is non-empty and embedding service is available");
        return {
          content: [{ type: "text", text: JSON.stringify({ id, version: 1 }) }],
        };
      }

      // ---- library_update_record ----
      case "library_update_record": {
        const { record_id, title, content_markdown = "", schema_data = "{}", labels = "" } = args as any;
        const raw = await callLibrary("library_update_record", [
          record_id, title, content_markdown, schema_data, labels,
        ]);
        // library_update_record outputs the new record id from the SELECT at end
        const lines = raw.split("\n").filter(Boolean);
        const newId = lines[lines.length - 1]?.trim();
        if (!newId) throw new Error("Update failed — record may not exist or is already deleted");

        // Fetch version from the new record
        const recRaw = await callLibrary("library_get_record", [newId]);
        const rec = parseRecord(recRaw);
        return {
          content: [{ type: "text", text: JSON.stringify({ id: newId, version: (rec as any)?.version }) }],
        };
      }

      // ---- library_get_record ----
      case "library_get_record": {
        const { record_id } = args as any;
        const raw = await callLibrary("library_get_record", [record_id]);
        const rec = parseRecord(raw);
        if (!rec) throw new Error(`Record not found: ${record_id}`);

        // Also fetch history
        const histRaw = await callLibrary("library_record_history", [record_id]);
        const history = parseHistory(histRaw);
        return {
          content: [{ type: "text", text: JSON.stringify({ ...rec, history }) }],
        };
      }

      // ---- library_get_backlinks ----
      case "library_get_backlinks": {
        const { record_id } = args as any;
        if (!record_id || !/^\d+$/.test(String(record_id))) {
          throw new Error("library_get_backlinks: record_id must be numeric");
        }
        const raw = await callLibrary("library_get_backlinks", [String(record_id)]);
        const lines = raw.trim().split("\n").filter(Boolean);
        const backlinks = lines.map((line) => {
          const [
            source_record_id,
            source_title,
            source_space_id,
            source_space_name,
            link_text,
            link_context,
            link_position,
          ] = line.split("\t");
          return {
            source_record_id,
            source_title,
            source_space_id,
            source_space_name,
            link_text,
            link_context,
            link_position: parseInt(link_position || "0", 10),
          };
        });
        return {
          content: [{ type: "text", text: JSON.stringify({ backlinks }) }],
        };
      }

      // ---- library_graph_data (Spec 045 Phase 2) ----
      case "library_graph_data": {
        const { space_ids = "", limit_nodes = 500 } = args as any;
        // Validate space_ids: comma-separated digits only
        const idsCsv = String(space_ids).trim();
        if (idsCsv && !/^\d+(,\d+)*$/.test(idsCsv)) {
          throw new Error("library_graph_data: space_ids must be comma-separated numeric ids");
        }
        const limitNum = parseInt(String(limit_nodes), 10);
        if (!Number.isFinite(limitNum) || limitNum < 1 || limitNum > 5000) {
          throw new Error("library_graph_data: limit_nodes must be 1..5000");
        }
        const raw = await callLibrary("library_graph_data", [idsCsv, String(limitNum)]);
        // psql returns the JSON literal as a single line. Re-parse to normalize
        // whitespace + validate shape, then re-stringify so the MCP client
        // gets a clean object.
        let parsed: { nodes: unknown[]; edges: unknown[] };
        try {
          parsed = JSON.parse(raw.trim());
        } catch (parseErr) {
          // Surface the failure on stderr so misconfigured psql / NOTICE-leakage
          // is debuggable instead of silently returning an empty graph.
          process.stderr.write(
            `[library-mcp] library_graph_data JSON parse failed: ${String(parseErr)} (raw bytes=${raw.length})\n`
          );
          parsed = { nodes: [], edges: [] };
        }
        return {
          content: [{ type: "text", text: JSON.stringify(parsed) }],
        };
      }

      // ---- library_search ----
      case "library_search": {
        const { query, space = "", labels = "", limit = 10 } = args as any;

        // Resolve space name → id if provided and non-numeric
        let spaceFilter = space;
        if (spaceFilter && !/^\d+$/.test(spaceFilter)) {
          spaceFilter = await callLibrary("library_space_id", [spaceFilter]);
        }

        const raw = await callLibrary("library_search", [
          query, spaceFilter, labels, String(limit),
        ]);
        const results = parseSearchResults(raw);
        return {
          content: [{ type: "text", text: JSON.stringify(results) }],
        };
      }

      // ---- library_list_records ----
      case "library_list_records": {
        const { space_id_or_name, limit = 50 } = args as any;

        let spaceId = space_id_or_name;
        if (!/^\d+$/.test(spaceId)) {
          spaceId = await callLibrary("library_space_id", [space_id_or_name]);
          if (!spaceId) throw new Error(`Space not found: ${space_id_or_name}`);
        }

        const raw = await callLibrary("library_list_records", [spaceId, String(limit)]);
        const records = parseListRecords(raw);
        return {
          content: [{ type: "text", text: JSON.stringify(records) }],
        };
      }

      // ---- library_delete_record ----
      case "library_delete_record": {
        const { record_id } = args as any;
        const raw = await callLibrary("library_delete_record", [record_id]);
        const deletedId = raw.trim();
        if (!deletedId) throw new Error(`Delete failed — record ${record_id} not found or already deleted`);
        return {
          content: [{ type: "text", text: JSON.stringify({ deleted: true, id: deletedId }) }],
        };
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (err: any) {
    const isAccessDenied = err instanceof LibraryAccessError || err.message?.includes("access denied");
    return {
      content: [{ type: "text", text: `Error: ${err.message}` }],
      isError: true,
      ...(isAccessDenied ? { errorCode: "ACCESS_DENIED" } : {}),
    };
  }
});

// ---------------------------------------------------------------
// Start
// ---------------------------------------------------------------
async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write("[library-mcp] Server started\n");
}

main().catch((err) => {
  process.stderr.write(`[library-mcp] Fatal: ${err.message}\n`);
  process.exit(1);
});
