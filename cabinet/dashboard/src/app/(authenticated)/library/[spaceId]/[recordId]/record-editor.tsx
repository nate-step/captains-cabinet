'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'

interface Props {
  recordId: string
  spaceId: string
  initialTitle: string
  initialContent: string
  initialLabels: string[]
  initialSchemaData: Record<string, unknown>
  isDeleted: boolean
  isArchived: boolean
}

export default function RecordEditor({
  recordId,
  spaceId,
  initialTitle,
  initialContent,
  initialLabels,
  initialSchemaData,
  isDeleted,
  isArchived,
}: Props) {
  const [title, setTitle] = useState(initialTitle)
  const [content, setContent] = useState(initialContent)
  const [labels, setLabels] = useState(initialLabels.join(', '))
  const [schemaRaw, setSchemaRaw] = useState(
    Object.keys(initialSchemaData).length > 0
      ? JSON.stringify(initialSchemaData, null, 2)
      : ''
  )
  const [schemaError, setSchemaError] = useState<string | null>(null)
  const [preview, setPreview] = useState(false)
  const [saving, setSaving] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const router = useRouter()

  const readonly = isDeleted || isArchived

  function validateSchema(raw: string): Record<string, unknown> | null {
    if (!raw.trim()) return {}
    try {
      return JSON.parse(raw) as Record<string, unknown>
    } catch {
      return null
    }
  }

  async function handleSave(e: React.FormEvent) {
    e.preventDefault()
    if (!title.trim()) return

    const schemaData = validateSchema(schemaRaw)
    if (schemaData === null) {
      setSchemaError('Invalid JSON in schema data')
      return
    }
    setSchemaError(null)
    setSaving(true)
    setSaveError(null)

    const parsedLabels = labels
      .split(',')
      .map((l) => l.trim())
      .filter(Boolean)

    try {
      const res = await fetch(`/api/library/records/${recordId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title: title.trim(),
          content_markdown: content,
          labels: parsedLabels,
          schema_data: schemaData,
        }),
      })
      if (!res.ok) {
        const data = (await res.json()) as { error?: string }
        throw new Error(data.error ?? 'Failed to save')
      }
      const data = (await res.json()) as { record: { id: string } }
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
      // Navigate to the new record id (new version)
      router.push(`/library/${spaceId}/${data.record.id}`)
      router.refresh()
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setSaving(false)
    }
  }

  async function handleDelete() {
    if (!confirm('Delete this record? It will be hidden from lists (soft delete).')) return
    setDeleting(true)
    try {
      const res = await fetch(`/api/library/records/${recordId}`, {
        method: 'DELETE',
      })
      if (!res.ok) {
        const data = (await res.json()) as { error?: string }
        throw new Error(data.error ?? 'Failed to delete')
      }
      router.push(`/library/${spaceId}`)
      router.refresh()
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Delete failed')
      setDeleting(false)
    }
  }

  return (
    <form onSubmit={handleSave} className="flex flex-col gap-5">
      {/* Readonly banner */}
      {(isDeleted || isArchived) && (
        <div className="rounded-lg border border-amber-900/40 bg-amber-950/20 px-4 py-3 text-sm text-amber-400">
          {isDeleted
            ? 'This record has been deleted. Viewing only.'
            : 'This is an archived version. Navigate to the current version to edit.'}
        </div>
      )}

      {/* Title */}
      <div>
        <label className="mb-1.5 block text-xs font-medium text-zinc-400">
          Title <span className="text-red-500">*</span>
        </label>
        <input
          type="text"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          disabled={readonly}
          className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-50"
          required
        />
      </div>

      {/* Content — toggle between raw + preview */}
      <div>
        <div className="mb-1.5 flex items-center justify-between">
          <label className="text-xs font-medium text-zinc-400">Content (Markdown)</label>
          {!readonly && (
            <button
              type="button"
              onClick={() => setPreview(!preview)}
              className="text-xs text-zinc-500 hover:text-zinc-300 transition-colors"
            >
              {preview ? 'Edit' : 'Preview'}
            </button>
          )}
        </div>

        {preview ? (
          <div
            className="min-h-[200px] rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm text-zinc-300 prose prose-invert prose-sm max-w-none overflow-auto whitespace-pre-wrap"
          >
            {content || <span className="text-zinc-600 italic">No content</span>}
          </div>
        ) : (
          <textarea
            value={content}
            onChange={(e) => setContent(e.target.value)}
            disabled={readonly}
            rows={12}
            className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 font-mono text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none resize-y disabled:cursor-not-allowed disabled:opacity-50"
            placeholder="Write in markdown…"
          />
        )}
      </div>

      {/* Labels */}
      <div>
        <label className="mb-1.5 block text-xs font-medium text-zinc-400">Labels</label>
        <input
          type="text"
          value={labels}
          onChange={(e) => setLabels(e.target.value)}
          disabled={readonly}
          placeholder="comma-separated, e.g. decision, blocker"
          className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-50"
        />
      </div>

      {/* Schema data */}
      <div>
        <label className="mb-1.5 block text-xs font-medium text-zinc-400">
          Schema Data (JSON)
        </label>
        <textarea
          value={schemaRaw}
          onChange={(e) => {
            setSchemaRaw(e.target.value)
            setSchemaError(null)
          }}
          disabled={readonly}
          rows={5}
          placeholder='{"priority": "P1", "status": "open"}'
          className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 font-mono text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none resize-y disabled:cursor-not-allowed disabled:opacity-50"
        />
        {schemaError && (
          <p className="mt-1 text-xs text-red-400">{schemaError}</p>
        )}
      </div>

      {/* Save error */}
      {saveError && (
        <p className="rounded bg-red-950/30 px-3 py-2 text-xs text-red-400">{saveError}</p>
      )}

      {/* Actions */}
      {!readonly && (
        <div className="flex items-center gap-3">
          <button
            type="submit"
            disabled={saving || !title.trim()}
            className="rounded-lg bg-white px-5 py-2 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200 disabled:opacity-50"
          >
            {saving ? 'Saving…' : saved ? 'Saved!' : 'Save'}
          </button>
          <button
            type="button"
            onClick={handleDelete}
            disabled={deleting}
            className="rounded-lg border border-red-900/50 px-4 py-2 text-sm font-medium text-red-500 transition-colors hover:bg-red-950/30 disabled:opacity-50"
          >
            {deleting ? 'Deleting…' : 'Delete'}
          </button>
          <span className="text-xs text-zinc-600">
            Saving creates a new version with history preserved.
          </span>
        </div>
      )}
    </form>
  )
}
