'use client'

import { EditableField, MaskedField } from '@/components/editable-field'
import { updateNotionConfig, updateLinearConfig } from '@/actions/config'
import { updateEnvVar } from '@/actions/env'

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

const API_KEY_NAMES = [
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
]

export function ApiKeysSection({ envVars }: ApiKeysSectionProps) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">API Keys</h2>
      <div className="mt-4 space-y-4">
        {API_KEY_NAMES.map((key) => (
          <MaskedField
            key={key}
            label={key.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())}
            value={envVars[key] || ''}
            onSave={(v) => updateEnvVar(key, v)}
          />
        ))}
      </div>
    </div>
  )
}
