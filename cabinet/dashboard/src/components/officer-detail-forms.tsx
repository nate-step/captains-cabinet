'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { EditableField } from '@/components/editable-field'
import { updateOfficerVoiceConfig } from '@/actions/config'
import { updateRoleDefinition, updateLoopPrompt } from '@/actions/files'
import { deleteOfficer, startOfficer, stopOfficer, restartOfficer } from '@/actions/officers'
import type { OfficerConfig } from '@/lib/config'

interface VoiceEditSectionProps {
  role: string
  config: OfficerConfig
}

export function VoiceEditSection({ role, config }: VoiceEditSectionProps) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Voice Configuration</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Voice ID"
          value={config.voiceId}
          onSave={(v) => updateOfficerVoiceConfig(role, 'voices', v)}
          mono
        />
        <EditableField
          label="Model"
          value={config.voiceModel}
          onSave={(v) => updateOfficerVoiceConfig(role, 'models', v)}
          mono
        />
        <EditableField
          label="Stability"
          value={config.voiceId ? String(config.voiceStability) : ''}
          onSave={(v) => updateOfficerVoiceConfig(role, 'stability', v)}
        />
        <EditableField
          label="Speed"
          value={config.voiceId ? String(config.voiceSpeed) : ''}
          onSave={(v) => updateOfficerVoiceConfig(role, 'speeds', v)}
        />
        <EditableField
          label="Voice Prompt"
          value={config.voicePrompt}
          onSave={(v) => updateOfficerVoiceConfig(role, 'naturalize_prompts', v)}
          type="textarea"
        />
        {!config.voiceId && (
          <p className="text-sm text-zinc-600">
            Voice is not configured for this officer.
          </p>
        )}
      </div>
    </div>
  )
}

interface TextEditSectionProps {
  role: string
  title: string
  content: string
  onSave: (role: string, content: string) => Promise<{ success: boolean; error?: string }>
  emptyText: string
}

export function TextEditSection({ role, title, content, onSave, emptyText }: TextEditSectionProps) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(content)
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  function handleEdit() {
    setDraft(content)
    setEditing(true)
    setError(null)
  }

  function handleCancel() {
    setEditing(false)
    setError(null)
  }

  function handleSave() {
    startTransition(async () => {
      const result = await onSave(role, draft)
      if (result.success) {
        setEditing(false)
        setError(null)
      } else {
        setError(result.error || 'Failed to save')
      }
    })
  }

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-white">{title}</h2>
        {!editing && (
          <button
            onClick={handleEdit}
            className="text-zinc-600 transition-colors hover:text-zinc-400"
            title="Edit"
          >
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" />
            </svg>
          </button>
        )}
      </div>

      {editing ? (
        <div className="mt-4">
          <textarea
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            className="w-full rounded-lg border border-zinc-700 bg-zinc-800 font-mono text-sm leading-relaxed text-zinc-300 focus:border-zinc-500 focus:outline-none"
            style={{ padding: '16px', minHeight: '300px' }}
            disabled={isPending}
          />
          {error && <p className="mt-2 text-xs text-red-400">{error}</p>}
          <div className="mt-3 flex gap-2">
            <button
              onClick={handleSave}
              disabled={isPending}
              className="rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-green-500 disabled:opacity-50"
            >
              {isPending ? 'Saving...' : 'Save'}
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
        <div
          className="mt-4 max-h-96 overflow-y-auto rounded-lg border border-zinc-700 bg-zinc-800 font-mono text-sm leading-relaxed text-zinc-300 whitespace-pre-wrap"
          style={{ padding: '16px' }}
        >
          {content || emptyText}
        </div>
      )}
    </div>
  )
}

export function RoleDefinitionSection({ role, content }: { role: string; content: string }) {
  return (
    <TextEditSection
      role={role}
      title="Role Definition"
      content={content}
      onSave={updateRoleDefinition}
      emptyText="No role definition file found."
    />
  )
}

export function LoopPromptSection({ role, content }: { role: string; content: string }) {
  return (
    <TextEditSection
      role={role}
      title="Loop Prompt"
      content={content}
      onSave={updateLoopPrompt}
      emptyText="No loop prompt configured."
    />
  )
}

type OfficerStatus = 'running' | 'stopped' | 'no-heartbeat'

interface OfficerActionsProps {
  role: string
  status: OfficerStatus
}

export function OfficerActions({ role, status }: OfficerActionsProps) {
  const [isPending, startTransition] = useTransition()

  return (
    <div className="flex gap-2">
      {status === 'stopped' && (
        <button
          onClick={() => startTransition(async () => { await startOfficer(role) })}
          disabled={isPending}
          className="inline-flex items-center gap-1.5 rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-green-500 disabled:opacity-50"
        >
          {isPending ? 'Starting...' : 'Start'}
        </button>
      )}
      {(status === 'running' || status === 'no-heartbeat') && (
        <>
          <button
            onClick={() => startTransition(async () => { await stopOfficer(role) })}
            disabled={isPending}
            className="inline-flex items-center gap-1.5 rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-red-500 disabled:opacity-50"
          >
            {isPending ? 'Stopping...' : 'Stop'}
          </button>
          <button
            onClick={() => startTransition(async () => { await restartOfficer(role) })}
            disabled={isPending}
            className="inline-flex items-center gap-1.5 rounded-lg bg-amber-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-amber-500 disabled:opacity-50"
          >
            {isPending ? 'Restarting...' : 'Restart'}
          </button>
        </>
      )}
    </div>
  )
}

interface DeleteOfficerButtonProps {
  role: string
}

export function DeleteOfficerButton({ role }: DeleteOfficerButtonProps) {
  const [confirming, setConfirming] = useState(false)
  const [isPending, startTransition] = useTransition()
  const router = useRouter()

  function handleDelete() {
    if (!confirming) {
      setConfirming(true)
      return
    }
    startTransition(async () => {
      const result = await deleteOfficer(role)
      if (result.success) {
        router.push('/officers')
      }
    })
  }

  return (
    <div className="rounded-xl border border-red-900/50 bg-red-900/10" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-red-400">Danger Zone</h2>
      <p className="mt-2 text-sm text-zinc-500">
        Permanently delete this officer. This removes the role definition, loop prompt,
        voice configuration, and Redis state. This action cannot be undone.
      </p>
      <div className="mt-4 flex items-center gap-3">
        <button
          onClick={handleDelete}
          disabled={isPending}
          className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors disabled:opacity-50 ${
            confirming
              ? 'bg-red-600 text-white hover:bg-red-500'
              : 'border border-red-500/30 bg-red-900/20 text-red-400 hover:bg-red-900/40'
          }`}
        >
          {isPending
            ? 'Deleting...'
            : confirming
              ? 'Confirm Delete'
              : 'Delete Officer'}
        </button>
        {confirming && (
          <button
            onClick={() => setConfirming(false)}
            disabled={isPending}
            className="rounded-lg border border-zinc-700 px-4 py-2 text-sm font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
          >
            Cancel
          </button>
        )}
      </div>
    </div>
  )
}
