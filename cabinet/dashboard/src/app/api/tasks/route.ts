/**
 * GET  /api/tasks          — all officer boards (+ Captain Linear items)
 * POST /api/tasks          — create a task (queue or start wip)
 *
 * Spec 038 Phase A.
 */

import { NextRequest, NextResponse } from 'next/server'
import {
  getAllOfficerBoards,
  startTask,
  queueTask,
  type LinkedKind,
} from '@/lib/tasks'
import { getLinearFounderActions } from '@/lib/linear-tasks'

export const dynamic = 'force-dynamic'

export async function GET() {
  try {
    const [boards, captainTasks] = await Promise.all([
      getAllOfficerBoards(),
      getLinearFounderActions(),
    ])

    return NextResponse.json({ boards, captain: captainTasks })
  } catch (err) {
    console.error('[tasks] GET /api/tasks', err)
    return NextResponse.json({ error: 'Failed to fetch tasks' }, { status: 500 })
  }
}

export async function POST(req: NextRequest) {
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

    // WIP conflict gets a 409
    if (message.includes('WIP conflict')) {
      return NextResponse.json({ error: message }, { status: 409 })
    }
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
