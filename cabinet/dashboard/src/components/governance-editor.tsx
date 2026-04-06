'use client'

import { useState, useTransition } from 'react'
import { updateGovernanceFile } from '@/actions/governance'

interface GovernanceDocument {
  key: string
  title: string
  description: string
  filePath: string
  accentColor: string
  content: string
}

const DOCUMENT_META: Record<string, { title: string; description: string; filePath: string; accentColor: string }> = {
  constitution: {
    title: 'Constitution',
    description: 'Operating principles — the rules all officers follow',
    filePath: '/opt/founders-cabinet/constitution/CONSTITUTION.md',
    accentColor: '#d97706', // amber
  },
  safety: {
    title: 'Safety Boundaries',
    description: 'Hard limits that can never be violated',
    filePath: '/opt/founders-cabinet/constitution/SAFETY_BOUNDARIES.md',
    accentColor: '#dc2626', // red
  },
  registry: {
    title: 'Role Registry',
    description: 'Who does what — active officers, shared interfaces, hooks',
    filePath: '/opt/founders-cabinet/constitution/ROLE_REGISTRY.md',
    accentColor: '#2563eb', // blue
  },
  operating_manual: {
    title: 'Operating Manual',
    description: 'Session-start instructions loaded by every officer',
    filePath: '/opt/founders-cabinet/CLAUDE.md',
    accentColor: '#16a34a', // green
  },
}

function DocumentCard({ doc }: { doc: GovernanceDocument }) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(doc.content)
  const [isPending, startTransition] = useTransition()
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null)

  function handleEdit() {
    setDraft(doc.content)
    setEditing(true)
    setFeedback(null)
  }

  function handleCancel() {
    setEditing(false)
    setFeedback(null)
  }

  function handleSave() {
    startTransition(async () => {
      const result = await updateGovernanceFile(doc.key, draft)
      if (result.success) {
        setEditing(false)
        setFeedback({ type: 'success', message: 'Saved successfully. Officers will load the new version on their next session.' })
        setTimeout(() => setFeedback(null), 5000)
      } else {
        setFeedback({ type: 'error', message: result.error || 'Failed to save' })
      }
    })
  }

  return (
    <div
      className="rounded-xl border bg-zinc-900"
      style={{
        padding: '24px',
        borderColor: doc.accentColor,
        borderLeftWidth: '4px',
      }}
    >
      <div className="flex items-start justify-between">
        <div>
          <h2 className="text-lg font-semibold text-white">{doc.title}</h2>
          <p className="mt-1 text-sm text-zinc-500">{doc.description}</p>
          <p className="mt-0.5 font-mono text-xs text-zinc-600">{doc.filePath}</p>
        </div>
        {!editing && (
          <button
            onClick={handleEdit}
            className="flex shrink-0 items-center gap-1.5 rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:border-zinc-600 hover:bg-zinc-800 hover:text-zinc-200"
          >
            <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" />
            </svg>
            Edit
          </button>
        )}
      </div>

      {feedback && (
        <div
          className={`mt-3 rounded-lg text-sm ${
            feedback.type === 'success'
              ? 'border border-green-800 bg-green-900/30 text-green-400'
              : 'border border-red-800 bg-red-900/30 text-red-400'
          }`}
          style={{ padding: '8px 12px' }}
        >
          {feedback.message}
        </div>
      )}

      <div className="mt-4">
        {editing ? (
          <div className="flex flex-col gap-3">
            <textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              disabled={isPending}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-800 font-mono text-sm text-zinc-200 focus:border-zinc-500 focus:outline-none disabled:opacity-50"
              style={{
                padding: '12px 16px',
                minHeight: '300px',
                lineHeight: '1.6',
                resize: 'vertical',
                tabSize: 2,
              }}
              spellCheck={false}
            />
            <div className="flex gap-2">
              <button
                onClick={handleSave}
                disabled={isPending}
                className="rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-green-500 disabled:opacity-50"
              >
                {isPending ? 'Saving...' : 'Save Changes'}
              </button>
              <button
                onClick={handleCancel}
                disabled={isPending}
                className="rounded-lg border border-zinc-700 px-4 py-2 text-sm font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          <pre
            className="overflow-auto whitespace-pre-wrap rounded-lg border border-zinc-800 bg-zinc-950 font-mono text-sm text-zinc-300"
            style={{
              padding: '12px 16px',
              maxHeight: '400px',
              lineHeight: '1.6',
            }}
          >
            {doc.content || '(empty)'}
          </pre>
        )}
      </div>
    </div>
  )
}

export default function GovernanceEditor({ files }: { files: Record<string, string> }) {
  const documents: GovernanceDocument[] = Object.entries(DOCUMENT_META).map(([key, meta]) => ({
    key,
    ...meta,
    content: files[key] || '',
  }))

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '24px' }}>
      {/* Warning banner */}
      <div
        className="flex items-start gap-3 rounded-xl border border-amber-700/50 bg-amber-900/20"
        style={{ padding: '16px 20px' }}
      >
        <svg className="mt-0.5 h-5 w-5 shrink-0 text-amber-500" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
        </svg>
        <div>
          <p className="text-sm font-medium text-amber-400">Changes take effect immediately</p>
          <p className="mt-0.5 text-sm text-amber-500/80">
            Officers read these documents at session start. Any edits here will be picked up on their next session.
          </p>
        </div>
      </div>

      {/* Document cards */}
      {documents.map((doc) => (
        <DocumentCard key={doc.key} doc={doc} />
      ))}
    </div>
  )
}
