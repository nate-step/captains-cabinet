'use client'

import { useState, useTransition } from 'react'
import { EditableField, MaskedField } from '@/components/editable-field'
import { updateNotionConfig, updateLinearConfig } from '@/actions/config'
import { updateEnvVar, deleteEnvVar, addEnvVar } from '@/actions/env'

interface TelegramSectionProps {
  envVars: Record<string, string>
}

export function TelegramSection({ envVars }: TelegramSectionProps) {
  const hqChatId = envVars['TELEGRAM_HQ_CHAT_ID'] || ''
  const captainId = envVars['CAPTAIN_TELEGRAM_ID'] || ''
  const botTokenKeys = Object.keys(envVars).filter((k) => k.startsWith('TELEGRAM_') && k.endsWith('_TOKEN'))

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Telegram</h2>
      <div className="mt-4 space-y-4">
        <MaskedField
          label="HQ Chat ID"
          value={hqChatId}
          onSave={(v) => updateEnvVar('TELEGRAM_HQ_CHAT_ID', v)}
        />
        <MaskedField
          label="Captain Telegram ID"
          value={captainId}
          onSave={(v) => updateEnvVar('CAPTAIN_TELEGRAM_ID', v)}
        />
        {botTokenKeys.length > 0 && (
          <>
            <div className="border-t border-zinc-800 pt-3">
              <span className="text-sm font-medium text-zinc-400">Bot Tokens</span>
            </div>
            {botTokenKeys.map((key) => {
              const role = key.replace('TELEGRAM_', '').replace('_TOKEN', '').toLowerCase()
              return (
                <MaskedField
                  key={key}
                  label={`${role.toUpperCase()} Bot Token`}
                  value={envVars[key] || ''}
                  onSave={(v) => updateEnvVar(key, v)}
                />
              )
            })}
          </>
        )}
      </div>
    </div>
  )
}

interface NotionSectionProps {
  notionConfig: Record<string, string>
}

export function NotionSection({ notionConfig }: NotionSectionProps) {
  const entries = Object.entries(notionConfig)

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Notion</h2>
      {entries.length === 0 ? (
        <p className="mt-4 text-sm text-zinc-600">No Notion IDs configured.</p>
      ) : (
        <div className="mt-4 space-y-4">
          {entries.map(([key, value]) => (
            <EditableField
              key={key}
              label={key.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())}
              value={value}
              onSave={(v) => updateNotionConfig(key, v)}
              mono
            />
          ))}
        </div>
      )}
    </div>
  )
}

interface LinearSectionProps {
  linearConfig: { team_key: string; workspace_url: string }
}

export function LinearSection({ linearConfig }: LinearSectionProps) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Linear</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Team Key"
          value={linearConfig.team_key}
          onSave={(v) => updateLinearConfig('team_key', v)}
          mono
        />
        <EditableField
          label="Workspace URL"
          value={linearConfig.workspace_url}
          onSave={(v) => updateLinearConfig('workspace_url', v)}
          mono
        />
      </div>
    </div>
  )
}

interface ApiKeysSectionProps {
  envVars: Record<string, string>
}

const KNOWN_API_KEYS = [
  'ANTHROPIC_API_KEY',
  'ELEVENLABS_API_KEY',
  'GITHUB_PAT',
  'LINEAR_API_KEY',
  'NOTION_API_KEY',
  'NEON_CONNECTION_STRING',
  'VOYAGE_API_KEY',
  'PERPLEXITY_API_KEY',
  'BRAVE_SEARCH_API_KEY',
  'EXA_API_KEY',
  'MAPBOX_TOKEN',
  'DASHBOARD_PASSWORD',
]

const TELEGRAM_KEYS = ['TELEGRAM_HQ_CHAT_ID', 'CAPTAIN_TELEGRAM_ID']

function DeleteKeyButton({ envKey }: { envKey: string }) {
  const [confirming, setConfirming] = useState(false)
  const [isPending, startTransition] = useTransition()

  if (confirming) {
    return (
      <div className="flex gap-1">
        <button
          onClick={() => startTransition(async () => { await deleteEnvVar(envKey); setConfirming(false) })}
          disabled={isPending}
          className="rounded bg-red-600 px-2 py-0.5 text-xs text-white hover:bg-red-700 disabled:opacity-50"
        >
          {isPending ? '...' : 'Confirm'}
        </button>
        <button onClick={() => setConfirming(false)}
          className="rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-400 hover:bg-zinc-800">
          No
        </button>
      </div>
    )
  }

  return (
    <button onClick={() => setConfirming(true)}
      className="rounded border border-red-800 px-2 py-0.5 text-xs text-red-400 hover:bg-red-900/30">
      Delete
    </button>
  )
}

function AddKeyForm() {
  const [open, setOpen] = useState(false)
  const [error, setError] = useState('')
  const [isPending, startTransition] = useTransition()

  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
        className="mt-3 rounded border border-zinc-700 px-3 py-1.5 text-xs text-zinc-400 hover:bg-zinc-800 hover:text-white">
        + Add Variable
      </button>
    )
  }

  return (
    <div className="mt-4 rounded-lg border border-zinc-700 bg-zinc-800" style={{ padding: '16px' }}>
      <form onSubmit={(e) => {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        const key = (fd.get('key') as string).trim()
        const value = (fd.get('value') as string).trim()
        if (!key || !value) { setError('Both fields required'); return }
        setError('')
        startTransition(async () => {
          const result = await addEnvVar(key, value)
          if (result.success) setOpen(false)
          else setError(result.error || 'Failed')
        })
      }}>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <div className="flex-1">
            <label className="text-xs text-zinc-500">Variable Name</label>
            <input name="key" placeholder="MY_API_KEY" required
              className="mt-1 block w-full rounded border border-zinc-600 bg-zinc-700 px-2 py-1.5 text-xs text-white font-mono placeholder-zinc-500 focus:border-zinc-500 focus:outline-none" />
          </div>
          <div className="flex-1">
            <label className="text-xs text-zinc-500">Value</label>
            <input name="value" type="password" placeholder="sk-..." required
              className="mt-1 block w-full rounded border border-zinc-600 bg-zinc-700 px-2 py-1.5 text-xs text-white font-mono placeholder-zinc-500 focus:border-zinc-500 focus:outline-none" />
          </div>
          <div className="flex gap-2">
            <button type="submit" disabled={isPending}
              className="rounded bg-white px-3 py-1.5 text-xs font-semibold text-zinc-900 hover:bg-zinc-200 disabled:opacity-50">
              {isPending ? 'Adding...' : 'Add'}
            </button>
            <button type="button" onClick={() => setOpen(false)}
              className="rounded border border-zinc-600 px-3 py-1.5 text-xs text-zinc-400 hover:bg-zinc-700">
              Cancel
            </button>
          </div>
        </div>
        {error && <p className="mt-2 text-xs text-red-500">{error}</p>}
      </form>
    </div>
  )
}

export function ApiKeysSection({ envVars }: ApiKeysSectionProps) {
  // Show known keys + any extra keys in .env that aren't Telegram or known
  const extraKeys = Object.keys(envVars).filter(
    (k) => !KNOWN_API_KEYS.includes(k) && !k.startsWith('TELEGRAM_') && !TELEGRAM_KEYS.includes(k) && !k.startsWith('POSTGRES_') && !k.startsWith('CABINET_')
  )

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">API Keys &amp; Tokens</h2>
      <div className="mt-4 space-y-4">
        {KNOWN_API_KEYS.map((key) => (
          <div key={key} className="flex items-start justify-between gap-2">
            <div className="flex-1">
              <MaskedField
                label={key.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())}
                value={envVars[key] || ''}
                onSave={(v) => updateEnvVar(key, v)}
              />
            </div>
            {envVars[key] && <div className="mt-5"><DeleteKeyButton envKey={key} /></div>}
          </div>
        ))}
        {extraKeys.length > 0 && (
          <>
            <div className="border-t border-zinc-800 pt-3">
              <span className="text-sm font-medium text-zinc-400">Custom Variables</span>
            </div>
            {extraKeys.map((key) => (
              <div key={key} className="flex items-start justify-between gap-2">
                <div className="flex-1">
                  <MaskedField
                    label={key}
                    value={envVars[key] || ''}
                    onSave={(v) => updateEnvVar(key, v)}
                  />
                </div>
                <div className="mt-5"><DeleteKeyButton envKey={key} /></div>
              </div>
            ))}
          </>
        )}
      </div>
      <AddKeyForm />
    </div>
  )
}
