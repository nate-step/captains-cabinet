/**
 * GET  /api/tasks          — all officer boards (+ Captain Linear items)
 * POST /api/tasks          — create a task (queue or start wip)
 *
 * Spec 038 Phase A v1.2.
 *
 * v1.2 038.5: any Postgres errcode 23514 from the WIP trigger is coerced to
 * `WipCapExceededError` via `coerceWipCapError`, returning the same 409 body
 * as the app-level pre-check. Keeps contract consistent regardless of write path.
 */

import path from 'node:path'
import { readFile } from 'node:fs/promises'
import { NextRequest, NextResponse } from 'next/server'
import {
  getAllOfficerBoards,
  startTask,
  queueTask,
  WipCapExceededError,
  coerceWipCapError,
  type LinkedKind,
} from '@/lib/tasks'
import { getLinearFounderActions } from '@/lib/linear-tasks'

export const dynamic = 'force-dynamic'

/** Resolve active context from env > active-project.txt. Matches page.tsx. */
async function resolveActiveContext(): Promise<string> {
  if (process.env.CABINET_CONTEXT?.trim()) return process.env.CABINET_CONTEXT.trim()
  const cabinetRoot = process.env.CABINET_ROOT || '/opt/founders-cabinet'
  const txt = await readFile(path.join(cabinetRoot, 'instance/config/active-project.txt'), 'utf-8')
  const slug = txt.trim()
  if (!slug) throw new Error('active-project.txt is empty')
  return slug
}

export async function GET(req: NextRequest) {
  try {
    const queryContext = new URL(req.url).searchParams.get('context')?.trim()
    const contextSlug = queryContext || (await resolveActiveContext())
    const [boards, captainTasks] = await Promise.all([
      getAllOfficerBoards(contextSlug),
      getLinearFounderActions(),
    ])

    return NextResponse.json({ boards, captain: captainTasks, context_slug: contextSlug })
  } catch (err) {
    console.error('[tasks] GET /api/tasks', err)
    return NextResponse.json({ error: 'Failed to fetch tasks' }, { status: 500 })
  }
}

export async function POST(req: NextRequest) {
  // Pull officer_slug out of the try scope so the catch can include it in the
  // 23514-coerced WipCapExceededError. Spec AC #23 wants the real slug in the
  // error body, not a '?' placeholder.
  let officerSlug = '?'
  try {
    const body = (await req.json()) as {
      officer_slug: string
      title: string
      action: 'start' | 'queue'
      linked_url?: string
      linked_kind?: LinkedKind
      linked_id?: string
      context_slug?: string
    }

    if (!body.officer_slug?.trim()) {
      return NextResponse.json({ error: 'officer_slug is required' }, { status: 400 })
    }
    officerSlug = body.officer_slug
    if (!body.title?.trim()) {
      return NextResponse.json({ error: 'title is required' }, { status: 400 })
    }
    if (!body.action || !['start', 'queue'].includes(body.action)) {
      return NextResponse.json({ error: 'action must be "start" or "queue"' }, { status: 400 })
    }

    const opts = {
      linkedUrl: body.linked_url,
      linkedKind: body.linked_kind,
      linkedId: body.linked_id,
      contextSlug: body.context_slug,
    }

    const task =
      body.action === 'start'
        ? await startTask(body.officer_slug, body.title, opts)
        : await queueTask(body.officer_slug, body.title, opts)

    return NextResponse.json({ task }, { status: 201 })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    console.error('[tasks] POST /api/tasks', err)

    // WIP cap exceeded gets a structured 409 per Spec 038 v1.2 AC #4/§4.7.
    // App-level pre-check throws WipCapExceededError directly; the DB trigger
    // (errcode 23514) gets coerced — same response shape either way.
    const coerced =
      err instanceof WipCapExceededError
        ? err
        : coerceWipCapError(err, officerSlug)
    if (coerced) {
      return NextResponse.json(
        {
          error: 'wip-cap-exceeded',
          current_wip_count: coerced.current,
          cap: coerced.cap,
          titles: coerced.titles,
        },
        { status: 409 }
      )
    }

    // Spec §4.8 context_slug validation:
    //   missing / orphan (YAML doesn't exist) → 400 (caller misuse — fix your slug)
    //   malformed (invalid regex) → 503 (shouldn't happen — CLI validates first)
    if (
      message.includes('context_slug is required') ||
      (message.includes('context_slug') && message.includes('not found'))
    ) {
      return NextResponse.json({ error: message }, { status: 400 })
    }
    if (message.includes('context_slug') && message.includes('is invalid')) {
      return NextResponse.json({ error: message }, { status: 503 })
    }
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
