#!/bin/bash
# pre-tool-use.sh — Runs before every tool invocation
# Exit 0 = allow, Exit 2 = block (with reason on stdout)
# Claude Code passes JSON on stdin: { tool_name, tool_input }

# Read JSON from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_input // {}' 2>/dev/null)

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

# ============================================================
# 1. KILL SWITCH CHECK
# ============================================================
KILLSWITCH=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
if [ "$KILLSWITCH" = "active" ]; then
  # Allow the command that deactivates the kill switch
  if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    case "$CMD" in
      *"DEL cabinet:killswitch"*|*"del cabinet:killswitch"*)
        exit 0
        ;;
    esac
  fi
  echo "KILL SWITCH ACTIVE — all operations halted by Captain. Send /resume to deactivate."
  exit 2
fi

# ============================================================
# 2. DAILY SPENDING LIMIT CHECK
# ============================================================
TODAY=$(date -u +%Y-%m-%d)
DAILY_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:daily:$TODAY" 2>/dev/null)
DAILY_COST=${DAILY_COST:-0}

DAILY_LIMIT=30000
if [ "$DAILY_COST" -ge "$DAILY_LIMIT" ] 2>/dev/null; then
  echo "DAILY SPENDING LIMIT REACHED. Alert the Captain."
  exit 2
fi

# Per-officer daily limit
OFFICER="${OFFICER_NAME:-unknown}"
OFFICER_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:officer:$OFFICER:$TODAY" 2>/dev/null)
OFFICER_COST=${OFFICER_COST:-0}
OFFICER_LIMIT=7500
if [ "$OFFICER_COST" -ge "$OFFICER_LIMIT" ] 2>/dev/null; then
  echo "OFFICER DAILY LIMIT REACHED ($OFFICER). Pause non-critical work and alert the Captain."
  exit 2
fi

# ============================================================
# 3. PROHIBITED ACTIONS
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  case "$CMD" in
    *"rm -rf /"*|*"rm -rf /*"*)
      echo "BLOCKED: Destructive filesystem operation"
      exit 2
      ;;
    *"docker"*|*"systemctl"*|*"sudo"*)
      echo "BLOCKED: System-level command not permitted"
      exit 2
      ;;
    *"shutdown"*|*"reboot"*|*"halt"*)
      echo "BLOCKED: System control command not permitted"
      exit 2
      ;;
    *"vercel deploy"*|*"vercel --prod"*)
      echo "BLOCKED: Production deployment requires Captain approval"
      exit 2
      ;;
    *"DROP TABLE"*|*"DROP DATABASE"*|*"TRUNCATE"*|*"DELETE FROM"*)
      echo "BLOCKED: Destructive database operation requires Captain approval"
      exit 2
      ;;
  esac
fi

# ============================================================
# 4. CODEBASE OWNERSHIP — Only CTO may modify product code
# ============================================================
if [ "$OFFICER" != "cto" ] && [ "$OFFICER" != "unknown" ]; then
  if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
    case "$FILE_PATH" in
      /workspace/product/*)
        echo "BLOCKED: Only CTO can modify the product codebase. Write a spec to shared/interfaces/product-specs/ and notify CTO."
        exit 2
        ;;
    esac
  fi
  if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    case "$CMD" in
      *"git commit"*|*"git push"*|*"git add"*)
        case "$CMD" in
          *"/workspace/product"*|*"cd /workspace/product"*)
            echo "BLOCKED: Only CTO can commit/push to the product codebase. Write a spec and notify CTO."
            exit 2
            ;;
        esac
        ;;
    esac
    # Block common Bash write patterns to product codebase (defense in depth)
    # Two-condition check: command mentions product path AND contains a write operation
    if echo "$CMD" | grep -q '/workspace/product/' && echo "$CMD" | grep -qE '(>\s|sed -i |tee |cp .+ |mv .+ )'; then
      echo "BLOCKED: Only CTO can modify the product codebase via Bash. Write a spec and notify CTO."
      exit 2
    fi
  fi
fi

# ============================================================
# 5. CONSTITUTION PROTECTION
# ============================================================
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
  case "$FILE_PATH" in
    *"constitution/"*)
      echo "BLOCKED: Constitution files are read-only. Propose amendments through the self-improvement loop."
      exit 2
      ;;
    *".env"*)
      echo "BLOCKED: Environment files cannot be modified by Officers"
      exit 2
      ;;
    *"cabinet/docker-compose"*|*"Dockerfile"*)
      echo "BLOCKED: Infrastructure files cannot be modified by Officers"
      exit 2
      ;;
    *"instance/memory/tier2/"*)
      # Officers can only write to their OWN tier2 directory
      if ! echo "$FILE_PATH" | grep -q "instance/memory/tier2/${OFFICER}/"; then
        echo "BLOCKED: Officers can only write to their own tier2 directory (instance/memory/tier2/${OFFICER}/)"
        exit 2
      fi
      ;;
  esac
fi


# ============================================================
# 6. LAYER 1 GATE — CTO must run Crew review before push/merge
# ============================================================
if [ "$OFFICER" = "cto" ] && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  if echo "$CMD" | grep -qE 'git push.*main|git push.*origin main|gh pr merge'; then
    REVIEWED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:layer1:cto:reviewed" 2>/dev/null)
    if [ -z "$REVIEWED" ] || [ "$REVIEWED" = "(nil)" ]; then
      echo "LAYER 1 GATE: Spawn a Crew agent to review your diff before pushing/merging. After review, run: redis-cli -h redis -p 6379 SET cabinet:layer1:cto:reviewed 1 EX 300"
      exit 2
    fi
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:layer1:cto:reviewed" > /dev/null 2>&1
  fi
fi

# ============================================================
# 7. CI GREEN GATE — CTO must verify CI before merge
# ============================================================
if [ "$OFFICER" = "cto" ] && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  if echo "$CMD" | grep -qE 'pulls/[0-9]+/merge'; then
    CI_VERIFIED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:layer1:cto:ci-green" 2>/dev/null)
    if [ -z "$CI_VERIFIED" ] || [ "$CI_VERIFIED" = "(nil)" ]; then
      echo "CI GREEN GATE: Run 'bash /opt/founders-cabinet/cabinet/scripts/verify-deploy.sh ci <commit-sha>' and confirm CI is green before merging. After CI passes, run: redis-cli -h redis -p 6379 SET cabinet:layer1:cto:ci-green 1 EX 300"
      exit 2
    fi
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:layer1:cto:ci-green" > /dev/null 2>&1
  fi
fi

# ============================================================
# 8. CONTEXT_SLUG VALIDATION + CAPACITY COUPLING (Phase 1 CP2)
# ============================================================
# YAML files at instance/config/contexts/*.yml are source of truth for
# known slugs and their capacity (work|personal). Every tool call that
# writes a context_slug must reference a known slug AND must not cross
# the capacity boundary of the acting officer.
#
# Cache layer: /tmp/cabinet-context-slugs.tsv (slug<TAB>capacity), rebuilt
# when any yaml in the contexts dir is newer than the cache. Keeps the
# hook fast (~1ms) on every call.

CONTEXTS_DIR="/opt/founders-cabinet/instance/config/contexts"
SLUG_CACHE="/tmp/cabinet-context-slugs.tsv"

if [ -d "$CONTEXTS_DIR" ]; then
  # Rebuild cache if stale or missing. Dir mtime covers both file modifications
  # AND deletions (Linux bumps dir mtime on unlink); file-newer covers individual
  # edits. Combined: cache reflects current yaml set even after a deletion.
  if [ ! -f "$SLUG_CACHE" ] \
     || [ -n "$(find "$CONTEXTS_DIR" -maxdepth 0 -newer "$SLUG_CACHE" 2>/dev/null)" ] \
     || [ -n "$(find "$CONTEXTS_DIR" -maxdepth 1 -name '*.yml' -newer "$SLUG_CACHE" 2>/dev/null)" ]; then
    : > "$SLUG_CACHE"
    for f in "$CONTEXTS_DIR"/*.yml "$CONTEXTS_DIR"/*.yaml; do
      [ -f "$f" ] || continue
      # Strip inline # comments, quotes, and surrounding whitespace before capture.
      slug=$(awk -F: '/^slug:/{sub(/[ \t]*#.*$/,"",$2); gsub(/^[ \t]+|[ \t\r\n]+$/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' "$f")
      cap=$(awk -F: '/^capacity:/{sub(/[ \t]*#.*$/,"",$2); gsub(/^[ \t]+|[ \t\r\n]+$/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' "$f")
      [ -n "$slug" ] && [ -n "$cap" ] && printf "%s\t%s\n" "$slug" "$cap" >> "$SLUG_CACHE"
    done
  fi

  # Extract context_slug from tool_input if present (any depth)
  SLUG_IN_CALL=$(echo "$TOOL_INPUT" | jq -r '.context_slug // (..|.context_slug? // empty)' 2>/dev/null | grep -v '^$' | head -1)

  # Also pull from Bash command args (e.g. record-experience.sh --context-slug foo)
  if [ -z "$SLUG_IN_CALL" ] && [ "$TOOL_NAME" = "Bash" ]; then
    BCMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    SLUG_IN_CALL=$(echo "$BCMD" | grep -oE -- '--context[_-]slug[= ]+[a-z0-9_-]+' | head -1 | awk -F'[= ]' '{print $NF}')
  fi

  if [ -n "$SLUG_IN_CALL" ]; then
    # Validate slug exists in cache
    CTX_CAPACITY=$(awk -F'\t' -v s="$SLUG_IN_CALL" '$1==s{print $2; exit}' "$SLUG_CACHE")
    if [ -z "$CTX_CAPACITY" ]; then
      echo "BLOCKED: unknown context_slug '$SLUG_IN_CALL' — add to instance/config/contexts/<slug>.yml first."
      echo "Known slugs: $(cut -f1 "$SLUG_CACHE" | tr '\n' ' ')"
      exit 2
    fi

    # Cross-capacity enforcement: officer's capacity (from env) must match the context's.
    # OFFICER_CAPACITY defaults to 'work' for the Sensed work preset. Phase 2 will read
    # from preset.yml or per-officer config, not hardcoded default.
    OFFICER_CAPACITY="${OFFICER_CAPACITY:-work}"
    if [ "$OFFICER_CAPACITY" != "$CTX_CAPACITY" ]; then
      echo "BLOCKED: capacity_check failed — officer '$OFFICER' has capacity '$OFFICER_CAPACITY' but context_slug '$SLUG_IN_CALL' has capacity '$CTX_CAPACITY'. Cross-capacity writes are forbidden."
      exit 2
    fi
  fi
fi

# ============================================================
# 9. MCP SCOPE ENFORCEMENT (Phase 1 CP5)
# ============================================================
# cabinet/mcp-scope.yml declares which MCP servers each hired agent may
# reach. On every MCP tool call (tool_name starts with 'mcp__'), the
# hook derives the server name and rejects the call if it is not in the
# acting officer's scope.
#
# Cache: /tmp/cabinet-mcp-scope.tsv (officer\tcsv-of-mcps), rebuilt when
# the yaml is newer than the cache. Same pattern as context cache.

MCP_SCOPE_FILE="/opt/founders-cabinet/cabinet/mcp-scope.yml"
MCP_SCOPE_CACHE="/tmp/cabinet-mcp-scope.tsv"

if [ -f "$MCP_SCOPE_FILE" ] && echo "$TOOL_NAME" | grep -q '^mcp__'; then
  # Rebuild cache if stale. Cache format per line:
  #   agent\tmcp1,mcp2,...
  # Universals from yaml's top-level 'universal:' list are merged into every
  # agent's set at build time, so the hook's membership check stays a single
  # string lookup per tool call.
  if [ ! -f "$MCP_SCOPE_CACHE" ] || [ "$MCP_SCOPE_FILE" -nt "$MCP_SCOPE_CACHE" ]; then
    python3 - "$MCP_SCOPE_FILE" "$MCP_SCOPE_CACHE" <<'PY' 2>/dev/null || true
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
out = []
section = None
cur_agent = None
universals = []
# First pass: collect universals
for line in text.splitlines():
    m = re.match(r'^universal:\s*\[([^\]]*)\]', line)
    if m:
        universals = [x.strip() for x in m.group(1).split(',') if x.strip()]
        break
# Second pass: parse agents/scaffolds
for line in text.splitlines():
    if re.match(r'^(agents|scaffolds):\s*$', line):
        section = line.split(':',1)[0]
        continue
    # Reset section when any other top-level key is hit
    if re.match(r'^[A-Za-z]', line):
        if not re.match(r'^(agents|scaffolds):\s*$', line):
            section = None
        continue
    if section and re.match(r'^  [A-Za-z][A-Za-z0-9_-]*:\s*$', line):
        cur_agent = line.strip().rstrip(':')
        continue
    if cur_agent and re.match(r'^\s+mcps:\s*\[', line):
        mcps_raw = line.split('[',1)[1].split(']',1)[0]
        mcps = [m.strip() for m in mcps_raw.split(',') if m.strip()]
        # Merge universals (deduped, order preserved with agent's own first)
        seen = set(mcps)
        for u in universals:
            if u not in seen:
                mcps.append(u)
                seen.add(u)
        out.append(f"{cur_agent}\t{','.join(mcps)}")
        cur_agent = None
with open(dst, 'w') as f:
    f.write('\n'.join(out) + '\n')
PY
  fi

  # Resolve acting officer
  AGENT_KEY="${OFFICER:-unknown}"
  ALLOWED=$(awk -F'\t' -v a="$AGENT_KEY" '$1==a{print $2; exit}' "$MCP_SCOPE_CACHE" 2>/dev/null)

  # Derive MCP server from tool_name. Formats observed:
  #   mcp__<server>__<tool>                      (e.g. mcp__notion__API-post-page)
  #   mcp__plugin_<server>_<server>__<tool>      (e.g. mcp__plugin_telegram_telegram__reply)
  #   mcp__claude_ai_<Service>__<tool>           (e.g. mcp__claude_ai_Google_Drive__authenticate)
  # Note: assumes single-token server names. Multi-word plugin names
  # (e.g. a hypothetical mcp__plugin_google_drive_google_drive__...) would
  # truncate to 'google' under current parser. None in use today.
  MCP_SERVER=$(echo "$TOOL_NAME" | awk -F'__' '{print $2}')
  case "$MCP_SERVER" in
    plugin_*) MCP_SERVER=$(echo "$MCP_SERVER" | sed 's/^plugin_//' | awk -F'_' '{print $1}') ;;
    claude_ai_*) MCP_SERVER=$(echo "$MCP_SERVER" | sed 's/^claude_ai_//' | tr '[:upper:]' '[:lower:]') ;;
  esac

  if [ -z "$ALLOWED" ]; then
    # Unknown officer — fail-warn (not fail-open, not fail-closed). Hard block
    # would brick hiring flows when a new officer starts before mcp-scope.yml
    # is updated; silent allow hides configuration drift. Warn + allow lets
    # the call through while surfacing the gap for the retro.
    echo "WARN: mcp-scope — officer '$AGENT_KEY' has no entry in cabinet/mcp-scope.yml. Allowing '$MCP_SERVER' call. Add an entry to enforce scope." >&2
  else
    # Check membership
    if ! echo ",$ALLOWED," | grep -qi ",${MCP_SERVER}," ; then
      echo "BLOCKED: MCP scope check — officer '$OFFICER' is not scoped for MCP server '$MCP_SERVER'. Allowed: $ALLOWED. Edit cabinet/mcp-scope.yml to grant access."
      exit 2
    fi
  fi
fi

exit 0
