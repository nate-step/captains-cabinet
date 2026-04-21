/**
 * PATCH  /api/tasks/[id]   — transition a task (done, block, cancel, update)
 * DELETE /api/tasks/[id]   — cancel a task
 *
 * Spec 038 Phase A.
 */

import { NextRequest, NextResponse } from 'next/server'
import { getTask, doneTask, blockTask, cancelTask, updateTask } from '@/lib/tasks'

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
  try {
    const { id } = await params
    const taskId = parseInt(id, 10)
    if (isNaN(taskId)) {
      return NextResponse.json({ error: 'Invalid task id' }, { status: 400 })
    }

    const body = (await req.json()) as {
      action: 'done' | 'block' | 'cancel' | 'update'
      officer_slug?: string
      blocked_reason?: string
      title?: string
      description?: string
      linked_url?: string
      linked_kind?: string
      linked_id?: string
    }

    if (!body.action) {
      return NextResponse.json({ error: 'action is required' }, { status: 400 })
    }

    let task
    switch (body.action) {
      case 'done': {
        if (!body.officer_slug) {
          return NextResponse.json({ error: 'officer_slug required for done' }, { status: 400 })
        }
        task = await doneTask(body.officer_slug)
        break
      }
      case 'block': {
        if (!body.officer_slug) {
          return NextResponse.json({ error: 'officer_slug required for block' }, { status: 400 })
        }
        if (!body.blocked_reason?.trim()) {
          return NextResponse.json({ error: 'blocked_reason is required' }, { status: 400 })
        }
        task = await blockTask(body.officer_slug, body.blocked_reason)
        break
      }
      case 'cancel': {
        if (!body.officer_slug) {
          return NextResponse.json({ error: 'officer_slug required for cancel' }, { status: 400 })
        }
        task = await cancelTask(taskId, body.officer_slug)
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
          { error: 'action must be "done", "block", "cancel", or "update"' },
          { status: 400 }
        )
    }

    return NextResponse.json({ task })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    console.error('[tasks] PATCH /api/tasks/[id]', err)

    if (message.includes('not found')) {
      return NextResponse.json({ error: message }, { status: 404 })
    }
    if (message.includes('WIP conflict')) {
      return NextResponse.json({ error: message }, { status: 409 })
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

    if (message.includes('not found')) {
      return NextResponse.json({ error: message }, { status: 404 })
    }
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
