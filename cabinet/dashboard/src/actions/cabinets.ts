'use server'

/**
 * Spec 034 PR 2 — Server actions for cabinet management UI
 *
 * Wraps the /api/cabinets/* routes for use from Client Components
 * (suspend, resume, archive) and provides the getPresets() server
 * action that reads preset dirs from the filesystem.
 */

import fs from 'fs'
import path from 'path'
import yaml from 'js-yaml'

// ----------------------------------------------------------------
// Types
// ----------------------------------------------------------------

export interface PresetInfo {
  slug: string
  name: string
  description: string
  officerCount: number
  namingStyle: string
  autonomyLevel: string
}

export interface CabinetRow {
  cabinet_id: string
  captain_id: string
  name: string
  preset: string
  capacity: string
  state: string
  state_entered_at: string
  officer_slots: unknown
  retry_count: number
  created_at: string
}

export interface AuditEvent {
  event_id: number
  cabinet_id: string
  timestamp: string
  actor: string
  entry_point: string
  event_type: string
  state_before: string | null
  state_after: string | null
  payload: Record<string, unknown>
  error: string | null
}

// ----------------------------------------------------------------
// Preset discovery (server action — reads from filesystem)
// ----------------------------------------------------------------

const PRESETS_DIR =
  process.env.PRESETS_DIR || '/opt/founders-cabinet/presets'

/**
 * Read available presets from the presets/ directory.
 * Skips _template and any directory without a preset.yml.
 * Gracefully handles missing/malformed preset.yml — excludes those dirs.
 */
export async function getPresets(): Promise<PresetInfo[]> {
  const presets: PresetInfo[] = []

  let dirs: string[]
  try {
    dirs = fs.readdirSync(PRESETS_DIR, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith('_'))
      .map((d) => d.name)
  } catch {
    // Presets dir not accessible (test env / Docker) — return empty
    return []
  }

  for (const slug of dirs) {
    const presetFile = path.join(PRESETS_DIR, slug, 'preset.yml')
    try {
      const raw = fs.readFileSync(presetFile, 'utf8')
      const parsed = yaml.load(raw) as Record<string, unknown>

      // Validate required fields — skip malformed entries
      if (!parsed || typeof parsed !== 'object') continue
      if (typeof parsed.name !== 'string') continue

      const archetypes = parsed.agent_archetypes
      const officerCount = Array.isArray(archetypes) ? archetypes.length : 0

      presets.push({
        slug,
        name: (parsed.name as string) || slug,
        description: ((parsed.description as string) || '').trim(),
        officerCount,
        namingStyle: (parsed.naming_style as string) || 'functional',
        autonomyLevel: (parsed.autonomy_level as string) || 'execution_medium',
      })
    } catch {
      // Missing or unparseable preset.yml — skip this directory silently
      continue
    }
  }

  return presets
}

// ----------------------------------------------------------------
// Cabinet management actions (thin wrappers over the API routes)
// These run on the server so we avoid exposing the base URL in client
// bundles and get proper cookie forwarding automatically.
// ----------------------------------------------------------------

/** Base URL for internal API calls from server actions */
function apiBase(): string {
  // In Docker / Vercel the Next.js server calls itself on localhost
  return process.env.NEXT_PUBLIC_BASE_URL || 'http://localhost:3000'
}

async function cabinetsPost(id: string, subpath: string): Promise<{ ok: boolean; message?: string; state?: string }> {
  const url = `${apiBase()}/api/cabinets/${id}/${subpath}`
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    // Server actions run in the same process — cookies() is read
    // by requireProvisioningAccess() on the API side automatically
    // when both share the same Next.js runtime instance.
    cache: 'no-store',
  })
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { message?: string }
    return { ok: false, message: body.message || `HTTP ${res.status}` }
  }
  return (await res.json()) as { ok: boolean; message?: string; state?: string }
}

export async function suspendCabinet(cabinetId: string): Promise<{ ok: boolean; message?: string }> {
  return cabinetsPost(cabinetId, 'suspend')
}

export async function resumeCabinet(cabinetId: string): Promise<{ ok: boolean; message?: string }> {
  return cabinetsPost(cabinetId, 'resume')
}

export async function archiveCabinet(cabinetId: string): Promise<{ ok: boolean; message?: string }> {
  return cabinetsPost(cabinetId, 'archive')
}
