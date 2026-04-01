'use client'

import { useState, useTransition } from 'react'

interface EditableFieldProps {
  label: string
  value: string
  onSave: (value: string) => Promise<{ success: boolean; error?: string }>
  mono?: boolean
  type?: 'text' | 'textarea'
}

export function EditableField({ label, value, onSave, mono, type = 'text' }: EditableFieldProps) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(value)
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function handleEdit() {
    setDraft(value)
    setEditing(true)
    setError(null)
  }

  function handleCancel() {
    setEditing(false)
    setError(null)
  }

  function handleSave() {
    startTransition(async () => {
      const result = await onSave(draft)
      if (result.success) {
        setEditing(false)
        setError(null)
      } else {
        setError(result.error || 'Failed to save')
      }
    })
  }

  if (editing) {
    return (
      <div className="flex flex-col gap-2">
        <label className="text-sm text-zinc-500">{label}</label>
        {type === 'textarea' ? (
          <textarea
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            className="w-full rounded-lg border border-zinc-700 bg-zinc-800 text-sm text-zinc-200 focus:border-zinc-500 focus:outline-none font-mono"
            style={{ padding: '8px 12px', minHeight: '80px' }}
            disabled={isPending}
          />
        ) : (
          <input
            type="text"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            className={`w-full rounded-lg border border-zinc-700 bg-zinc-800 text-sm text-zinc-200 focus:border-zinc-500 focus:outline-none ${mono ? 'font-mono' : ''}`}
            style={{ padding: '8px 12px' }}
            disabled={isPending}
          />
        )}
        {error && <p className="text-xs text-red-400">{error}</p>}
        <div className="flex gap-2">
          <button
            onClick={handleSave}
            disabled={isPending}
            className="rounded-lg bg-green-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-green-500 disabled:opacity-50"
          >
            {isPending ? 'Saving...' : 'Save'}
          </button>
          <button
            onClick={handleCancel}
            disabled={isPending}
            className="rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
          >
            Cancel
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex items-baseline justify-between gap-3">
      <div className="min-w-0 flex-1">
        <span className="text-sm text-zinc-500">{label}</span>
        <p className={`mt-0.5 text-sm text-zinc-300 ${mono ? 'font-mono' : ''}`}>
          {value || 'Not configured'}
        </p>
      </div>
      <button
        onClick={handleEdit}
        className="shrink-0 text-zinc-600 transition-colors hover:text-zinc-400"
        title="Edit"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" />
        </svg>
      </button>
    </div>
  )
}

interface ToggleFieldProps {
  label: string
  description?: string
  enabled: boolean
  onToggle: (value: boolean) => Promise<{ success: boolean; error?: string }>
}

export function ToggleField({ label, description, enabled, onToggle }: ToggleFieldProps) {
  const [isPending, startTransition] = useTransition()

  function handleToggle() {
    startTransition(async () => {
      await onToggle(!enabled)
    })
  }

  return (
    <div className="flex items-center justify-between gap-3">
      <div>
        <span className="text-sm text-zinc-300">{label}</span>
        {description && <p className="text-xs text-zinc-600">{description}</p>}
      </div>
      <button
        onClick={handleToggle}
        disabled={isPending}
        className={`relative h-6 w-11 shrink-0 rounded-full transition-colors disabled:opacity-50 ${
          enabled ? 'bg-green-600' : 'bg-zinc-700'
        }`}
      >
        <span
          className={`absolute top-0.5 left-0.5 h-5 w-5 rounded-full bg-white transition-transform ${
            enabled ? 'translate-x-5' : 'translate-x-0'
          }`}
        />
      </button>
    </div>
  )
}

interface MaskedFieldProps {
  label: string
  value: string
  onSave: (value: string) => Promise<{ success: boolean; error?: string }>
}

export function MaskedField({ label, value, onSave }: MaskedFieldProps) {
  const [revealed, setRevealed] = useState(false)
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(value)
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function maskValue(val: string): string {
    if (!val) return 'Not configured'
    if (val.length <= 8) return val.substring(0, 2) + '...' + val.substring(val.length - 2)
    return val.substring(0, 4) + '...' + val.substring(val.length - 4)
  }

  function handleEdit() {
    setDraft(value)
    setEditing(true)
    setError(null)
  }

  function handleCancel() {
    setEditing(false)
    setError(null)
  }

  function handleSave() {
    startTransition(async () => {
      const result = await onSave(draft)
      if (result.success) {
        setEditing(false)
        setError(null)
      } else {
        setError(result.error || 'Failed to save')
      }
    })
  }

  if (editing) {
    return (
      <div className="flex flex-col gap-2">
        <label className="text-sm text-zinc-500">{label}</label>
        <input
          type="text"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          className="w-full rounded-lg border border-zinc-700 bg-zinc-800 font-mono text-sm text-zinc-200 focus:border-zinc-500 focus:outline-none"
          style={{ padding: '8px 12px' }}
          disabled={isPending}
        />
        {error && <p className="text-xs text-red-400">{error}</p>}
        <div className="flex gap-2">
          <button
            onClick={handleSave}
            disabled={isPending}
            className="rounded-lg bg-green-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-green-500 disabled:opacity-50"
          >
            {isPending ? 'Saving...' : 'Save'}
          </button>
          <button
            onClick={handleCancel}
            disabled={isPending}
            className="rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
          >
            Cancel
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex items-baseline justify-between gap-3">
      <div className="min-w-0 flex-1">
        <span className="text-sm text-zinc-500">{label}</span>
        <p className="mt-0.5 font-mono text-sm text-zinc-300">
          {revealed ? value || 'Not configured' : maskValue(value)}
        </p>
      </div>
      <div className="flex shrink-0 gap-1.5">
        <button
          onClick={() => setRevealed(!revealed)}
          className="text-zinc-600 transition-colors hover:text-zinc-400"
          title={revealed ? 'Hide' : 'Reveal'}
        >
          {revealed ? (
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M3.98 8.223A10.477 10.477 0 001.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.45 10.45 0 0112 4.5c4.756 0 8.773 3.162 10.065 7.498a10.523 10.523 0 01-4.293 5.774M6.228 6.228L3 3m3.228 3.228l3.65 3.65m7.894 7.894L21 21m-3.228-3.228l-3.65-3.65m0 0a3 3 0 10-4.243-4.243m4.242 4.242L9.88 9.88" />
            </svg>
          ) : (
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" />
              <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
          )}
        </button>
        <button
          onClick={handleEdit}
          className="text-zinc-600 transition-colors hover:text-zinc-400"
          title="Edit"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" />
          </svg>
        </button>
      </div>
    </div>
  )
}
