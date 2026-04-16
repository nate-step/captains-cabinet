# Skill: Create a New Project

**Status:** promoted
**Created by:** CoS + Captain
**Date:** 2026-04-02
**Validated against:** Sensed project setup
**Usage count:** 0

## When to Use

When the Captain wants to start a new product/project that the Cabinet will work on. This creates the full infrastructure: Notion page hierarchy, Neon database, Linear team, GitHub repo, and Cabinet config files.

## Prerequisites

- Captain must approve the new project
- Captain must have accounts on: Notion (shared workspace), Neon, Linear, GitHub

## Workflow

### 1. Captain Provides Project Details

Ask the Captain for:
- **Project name** (e.g., "NewCo")
- **Slug** (lowercase, e.g., "newco")
- **Description** (one-line elevator pitch)
- **GitHub org/repo name** (e.g., "nate-step/newco")

### 2. Create Notion Structure (MCP tools)

Use `notion-create-pages` to create the full page hierarchy under the shared workspace:

1. **Project Root Page** — "[ProjectName] — Cabinet HQ"
2. Under root, create pages:
   - **Captain's Dashboard** (with databases: Decision Queue, Daily Briefings, Weekly Reports)
   - **Business Brain** (with pages: Vision, Strategy Brief, Brand Guidelines, Messaging Pillars, Growth Guardrails, Pricing)
   - **Research Hub** (with databases: Research Briefs, Competitive Intel, Market Trends)
   - **Product Hub** (with databases: Product Roadmap, Feature Specs, User Feedback)
   - **Engineering Hub** (with databases: Architecture Decisions, Tech Debt)
   - **Cabinet Operations** (with databases: Decision Journal, Improvement Proposals)
   - **Reference**
   - **Archive**

Collect all page and database IDs.

### 3. Create Neon Database (MCP tools)

Use `neon create_project` with the project name.
Note the project name for config.

### 4. Create Linear Team (MCP tools or manual)

Use `linear save_project` or ask Captain to create a Linear team.
Note the team key and workspace URL.

### 5. Create GitHub Repo

```bash
gh repo create <org>/<repo-name> --private --description "<description>"
```
Clone it to the server at the path specified in PRODUCT_REPO_PATH.

### 6. Create Telegram Group

Ask the Captain to:
1. Create a new Telegram group named "[ProjectName] Warroom"
2. Add all officer bots to the group
3. Send any message, then get the chat ID

Or use the Telegram Bot API to get the chat ID after adding a bot.

### 7. Create Config Files

```bash
# Copy template
cp /opt/founders-cabinet/instance/config/projects/_template.yml /opt/founders-cabinet/instance/config/projects/<slug>.yml

# Edit with the IDs collected above
# Fill in: product.name, product.description, product.repo, all notion.* IDs, linear.*, neon.*, telegram.*
```

```bash
# Copy env template
cp /opt/founders-cabinet/cabinet/env/_template.env /opt/founders-cabinet/cabinet/env/<slug>.env

# Edit with:
# TELEGRAM_HQ_CHAT_ID=<new group chat id>
# NEON_CONNECTION_STRING=<from neon project>
# PRODUCT_REPO_PATH=<path to cloned repo on server>
# CABINET_PREFIX=<slug>
```

### 8. Switch to New Project

```bash
bash /opt/founders-cabinet/cabinet/scripts/switch-project.sh <slug>
```

This stops all officers, assembles the new config, and restarts officers on the new project context.

### 9. Verify

- Officers announce on the new warroom group
- Dashboard shows the new project in the selector
- `list-projects.sh` shows the new project as active

### 10. Record Experience

```bash
bash /opt/founders-cabinet/cabinet/scripts/record-experience.sh
```

## Expected Outcome

A fully operational project with:
- Notion page hierarchy with all databases
- Neon database project
- Linear team
- GitHub repo
- Cabinet config files
- Telegram warroom group
- Officers working on the new project

## Known Pitfalls

- Notion page creation is sequential — creating 30+ pages/databases takes a few minutes
- The Telegram group chat ID must be negative (groups have negative IDs)
- Same bot tokens work across projects — only the group chat changes
- PRODUCT_REPO_PATH must exist on the server before switching
- If officers fail to boot on the new project, check that all env vars are set correctly

## Origin

Evolved skill — created for multi-project support.
