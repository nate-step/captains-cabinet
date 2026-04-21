/**
 * PATCH  /api/tasks/[id]   — transition a task (done, block, unblock, cancel, update)
 * DELETE /api/tasks/[id]   — cancel a task
 *
 * Spec 038 Phase A v1.2.
 *
 * v1.2 038.5: any Postgres errcode 23514 from the WIP trigger is coerced to
 * `WipCapExceededError` via `coerceWipCapError`, returning the same 409 body
 * as the app-level pre-check. Keeps contract consistent regardless of write path.
 */

import { NextRequest, NextResponse } from 'next/server'
import {
  getTask,
  doneTask,
  setBlocked,
  cancelTask,
  updateTask,
  WipCapExceededError,
  coerceWipCapError,
} from '@/lib/tasks'

export const dynamic = 'force-dynamic'

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params
    const taskId = parseInt(id, 10)
    if (isNaN(taskId)) {
      return NextResponse.json({ error: 'Invalid task id' }, { status: 400 })
    }
    const task = await getTask(taskId)
    if (!task) {
      return NextResponse.json({ error: 'Task not found' }, { status: 404 })
    }
    return NextResponse.json({ task })
  } catch (err) {
    console.error('[tasks] GET /api/tasks/[id]', err)
    return NextResponse.json({ error: 'Failed to fetch task' }, { status: 500 })
  }
}

export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  // Hoisted out of try so catch can include it in 23514 coercion body.
  let officerSlug = '?'
  try {
    const { id } = await params
    const taskId = parseInt(id, 10)
    if (isNaN(taskId)) {
      return NextResponse.json({ error: 'Invalid task id' }, { status: 400 })
    }

    const body = (await req.json()) as {
      action: 'done' | 'block' | 'unblock' | 'cancel' | 'update'
      officer_slug?: string
      blocked_reason?: string
      title?: string
      description?: string
      linked_url?: string
      linked_kind?: string
      linked_id?: string
    }
    if (body.officer_slug?.trim()) officerSlug = body.officer_slug

    if (!body.action) {
      return NextResponse.json({ error: 'action is required' }, { status: 400 })
    }

    // Ownership-aware transitions all require officer_slug. (update is a
    // whitelisted-field edit, no state change — ownership is enforced at DB
    // level via context_slug + other constraints, not per-officer.)
    const requiresOfficer = ['done', 'block', 'unblock', 'cancel'].includes(body.action)
    if (requiresOfficer && !body.officer_slug?.trim()) {
      return NextResponse.json(
        { error: `officer_slug required for action "${body.action}"` },
        { status: 400 }
      )
    }

    let task
    switch (body.action) {
      case 'done': {
        task = await doneTask(taskId, body.officer_slug!)
        break
      }
      case 'block': {
        if (!body.blocked_reason?.trim()) {
          return NextResponse.json({ error: 'blocked_reason is required' }, { status: 400 })
        }
        task = await setBlocked(taskId, body.officer_slug!, true, body.blocked_reason)
        break
      }
      case 'unblock': {
        task = await setBlocked(taskId, body.officer_slug!, false)
        break
      }
      case 'cancel': {
        task = await cancelTask(taskId, body.officer_slug!)
        break
      }
      case 'update': {
        const fields: Record<string, unknown> = {}
        if (body.title !== undefined) fields.title = body.title
        if (body.description !== undefined) fields.description = body.description
        if (body.linked_url !== undefined) fields.linked_url = body.linked_url
        if (body.linked_kind !== undefined) fields.linked_kind = body.linked_kind
        if (body.linked_id !== undefined) fields.linked_id = body.linked_id

        if (Object.keys(fields).length === 0) {
          return NextResponse.json({ error: 'No fields to update' }, { status: 400 })
        }

        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        task = await updateTask(taskId, fields as any)
        break
      }
      default:
        return NextResponse.json(
          { error: 'action must be "done", "block", "unblock", "cancel", or "update"' },
          { status: 400 }
        )
    }

    return NextResponse.json({ task })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    console.error('[tasks] PATCH /api/tasks/[id]', err)

    // 038.5: Postgres errcode 23514 from the WIP trigger → same 409 body as
    // the app-level pre-check. Uses the officer_slug we hoisted out of the
    // try scope so the 409 body reports the real caller, not '?'.
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
    if (message.includes('not found')) {
      return NextResponse.json({ error: message }, { status: 404 })
    }
    return NextResponse.json({ error: message }, { status: 500 })
  }
}

export async function DELETE(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params
    const taskId = parseInt(id, 10)
    if (isNaN(taskId)) {
      return NextResponse.json({ error: 'Invalid task id' }, { status: 400 })
    }

    const body = (await req.json().catch(() => ({}))) as { officer_slug?: string }
    if (!body.officer_slug) {
      return NextResponse.json({ error: 'officer_slug required' }, { status: 400 })
    }

    const task = await cancelTask(taskId, body.officer_slug)
    return NextResponse.json({ task })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    console.error('[tasks] DELETE /api/tasks/[id]', err)

    // 038.5: cancel can't trip the WIP cap, but keep the coercion here too
    // in case a future edge (e.g. cancel→requeue) ever routes through.
    const coerced = coerceWipCapError(err, '?')
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
    if (message.includes('not found')) {
      return NextResponse.json({ error: message }, { status: 404 })
    }
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
