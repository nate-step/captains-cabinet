'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import SchemaFields from './[recordId]/schema-fields'
import type { SchemaJson } from './[recordId]/schema-fields'

// Build a defaults object from schema field definitions
function buildDefaults(schemaJson: SchemaJson): Record<string, unknown> {
  const defaults: Record<string, unknown> = {}
  for (const field of schemaJson.fields ?? []) {
    if (field.default !== undefined) {
      defaults[field.name] = field.default
    }
  }
  return defaults
}

interface Props {
  spaceId: string
  schemaJson: SchemaJson
}

export default function CreateRecordForm({ spaceId, schemaJson }: Props) {
  const [open, setOpen] = useState(false)
  const [title, setTitle] = useState('')
  const [content, setContent] = useState('')
  const [labels, setLabels] = useState('')
  const [schemaData, setSchemaData] = useState<Record<string, unknown>>(
    buildDefaults(schemaJson)
  )
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const router = useRouter()

  const hasSchemaFields = (schemaJson.fields ?? []).length > 0

  function handleOpen() {
    // Reset form to defaults on each open
    setTitle('')
    setContent('')
    setLabels('')
    setSchemaData(buildDefaults(schemaJson))
    setError(null)
    setOpen(true)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!title.trim()) return
    setSaving(true)
    setError(null)

    const parsedLabels = labels
      .split(',')
      .map((l) => l.trim())
      .filter(Boolean)

    try {
      const res = await fetch(`/api/library/spaces/${spaceId}/records`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title: title.trim(),
          content_markdown: content,
          labels: parsedLabels.length > 0 ? parsedLabels : undefined,
          schema_data: Object.keys(schemaData).length > 0 ? schemaData : undefined,
        }),
      })
      if (!res.ok) {
        const data = (await res.json()) as { error?: string }
        throw new Error(data.error ?? 'Failed to create record')
      }
      setOpen(false)
      router.refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setSaving(false)
    }
  }

  if (!open) {
    return (
      <button
        onClick={handleOpen}
        className="inline-flex items-center gap-2 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
        New Record
      </button>
    )
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div className="w-full max-w-2xl rounded-2xl border border-zinc-800 bg-zinc-950 p-6 shadow-xl max-h-[90vh] overflow-y-auto">
        <h2 className="text-lg font-semibold text-white">New Record</h2>

        <form onSubmit={handleSubmit} className="mt-5 flex flex-col gap-4">
          <div>
            <label className="mb-1.5 block text-xs font-medium text-zinc-400">
              Title <span className="text-red-500">*</span>
            </label>
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Record title"
              className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none"
              autoFocus
              required
            />
          </div>

          <div>
            <label className="mb-1.5 block text-xs font-medium text-zinc-400">
              Content (Markdown)
            </label>
            <textarea
              value={content}
              onChange={(e) => setContent(e.target.value)}
              placeholder="Write in markdown…"
              rows={6}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 font-mono text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none resize-y"
            />
          </div>

          <div>
            <label className="mb-1.5 block text-xs font-medium text-zinc-400">
              Labels
            </label>
            <input
              type="text"
              value={labels}
              onChange={(e) => setLabels(e.target.value)}
              placeholder="comma-separated, e.g. decision, blocker"
              className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none"
            />
          </div>

          {/* Schema fields with defaults pre-populated */}
          {hasSchemaFields && (
            <div>
              <label className="mb-3 block text-xs font-medium text-zinc-400">
                Fields
              </label>
              <SchemaFields
                schemaJson={schemaJson}
                schemaData={schemaData}
                onChange={setSchemaData}
              />
            </div>
          )}

          {error && (
            <p className="rounded bg-red-950/30 px-3 py-2 text-xs text-red-400">{error}</p>
          )}

          <div className="flex items-center gap-3 pt-1">
            <button
              type="submit"
              disabled={saving || !title.trim()}
              className="flex-1 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200 disabled:opacity-50"
            >
              {saving ? 'Creating…' : 'Create Record'}
            </button>
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="rounded-lg border border-zinc-700 px-4 py-2 text-sm font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
            >
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
