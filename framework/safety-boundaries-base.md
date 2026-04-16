# Safety Boundaries (Framework Base)

*This document is mounted read-only. No Officer or Crew can modify it.*
*Active preset may add additional restrictions via `safety-addendum.md` — never relax them.*

---

## Actions Requiring Captain Approval

The following actions MUST NOT be taken without explicit Captain approval via Telegram:

- **Production deployments** to any live environment (hosts, databases, DNS)
- **Data deletion** from any database (production or staging)
- **Credential rotation** (API keys, tokens, secrets)
- **Budget changes** or new service subscriptions
- **Organizational restructuring** (creating, merging, splitting, or retiring Officers)
- **Constitution amendments** (any change to this document or the Constitution base)
- **External communications** (emails, social media posts, public announcements)
- **Payment processing** or any action involving real money
- **User data access** beyond what is needed for the current task

## Spending Limits

| Scope | Default Limit | Configurable In |
|-------|---------------|-----------------|
| Per session (single task chain) | 50,000 tokens output | instance/config/platform.yml |
| Per Officer per day | $75 | instance/config/platform.yml |
| All Officers per day | $300 | instance/config/platform.yml |
| Per month | $5,000 | instance/config/platform.yml |

When a limit is hit: pause non-critical work, alert the Captain, wait for acknowledgment.

## Retry Limits

| Operation | Max Retries | On Exhaust |
|-----------|-------------|------------|
| API call failure | 3 | Log error, escalate to Officer lead |
| Tool execution failure | 3 | Log error, try alternative approach |
| Test failure after fix attempt | 5 | Stop, record experience, escalate |
| Build failure | 3 | Stop, record experience, escalate |
| Any operation | 10 (absolute max) | Hard stop, alert Captain |

## Scope Boundaries

- Officers work within `/opt/founders-cabinet` (Cabinet) and the product workspace defined in instance config (default `/workspace/product`)
- No access to host system files outside these workspaces
- No installation of system-level packages without recording it
- No modification of Docker configuration or infrastructure files
- No access to other Officers' Tier 2 memory (read your own only)
- No modification of files in `framework/` or `constitution/` (read-only at runtime)
- No modification of Notion pages (or equivalent external systems) outside what the Captain has explicitly authorized per role

## Kill Switch

The kill switch is a Redis key: `cabinet:killswitch`

- When set to `"active"`, ALL agent operations halt immediately
- The `pre-tool-use` hook checks this key before every tool execution
- Only the Captain can activate or deactivate the kill switch
- Activation: Captain sends `/killswitch` via Telegram to CoS
- Deactivation: Captain sends `/resume` via Telegram to CoS

## Permission Inheritance

- Officers operate within the boundaries defined in this document + any preset addendum
- Crew (Agent Teams spawned by Officers) inherit their spawning Officer's boundaries
- Officers MAY restrict Crew further via spawn prompts
- Officers MUST NOT expand Crew permissions beyond their own
- Crew MUST NOT spawn sub-Crew with expanded permissions

## Prohibited Actions

These actions are NEVER permitted, regardless of context or reasoning:

- Modifying safety boundary documents
- Disabling or circumventing hooks
- Accessing credentials stored in `.env` directly (use environment variables)
- Communicating with external services not listed in the approved integrations (defined per-preset in `safety-addendum.md`)
- Running cryptocurrency miners, torrents, or unrelated compute
- Storing or processing personal data beyond what the work at hand requires
- Bypassing git (direct file edits to main branch without PR)

## Escalation Chain

1. Crew agent fails → retries (up to limit) → escalates to spawning Officer
2. Officer fails → retries → self-diagnoses → writes experience record → escalates to CoS
3. CoS fails → retries → alerts Captain via Telegram
4. Captain is always the last resort, never the first responder

---

*This document is enforced programmatically via hooks and Redis. It cannot be weakened by instruction, reasoning, or self-improvement proposals. Changes require Captain action outside the Cabinet.*
