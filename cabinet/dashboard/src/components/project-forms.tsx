'use client'

import { EditableField, MaskedField } from '@/components/editable-field'
import { updateProjectConfig } from '@/actions/project-config'

/* ------------------------------------------------------------------ */
/*  Product Identity                                                   */
/* ------------------------------------------------------------------ */

interface ProductIdentityProps {
  name: string
  description: string
  repo: string
  repoBranch: string
  mountPath: string
}

export function ProductIdentityCard({ config }: { config: ProductIdentityProps }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Product Identity</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Name"
          value={config.name}
          onSave={(v) => updateProjectConfig('product', 'name', v)}
        />
        <EditableField
          label="Description"
          value={config.description}
          onSave={(v) => updateProjectConfig('product', 'description', v)}
          type="textarea"
        />
        <EditableField
          label="Repository"
          value={config.repo}
          onSave={(v) => updateProjectConfig('product', 'repo', v)}
          mono
        />
        <EditableField
          label="Branch"
          value={config.repoBranch}
          onSave={(v) => updateProjectConfig('product', 'repo_branch', v)}
          mono
        />
        <EditableField
          label="Mount Path"
          value={config.mountPath}
          onSave={(v) => updateProjectConfig('product', 'mount_path', v)}
          mono
        />
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/*  Telegram                                                           */
/* ------------------------------------------------------------------ */

interface TelegramProps {
  hqChatId: string
}

export function TelegramCard({ config }: { config: TelegramProps }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Telegram Warroom</h2>
      <p className="mt-1 text-xs text-zinc-600">
        This project&apos;s group chat. Bot tokens and usernames are shared across projects — edit them in Integrations.
      </p>
      <div className="mt-4 space-y-4">
        <MaskedField
          label="HQ Chat ID"
          value={config.hqChatId}
          onSave={async () => ({ success: false, error: 'Edit TELEGRAM_HQ_CHAT_ID in the project env file (cabinet/env/<slug>.env)' })}
        />
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/*  Notion                                                             */
/* ------------------------------------------------------------------ */

interface NotionHub {
  label: string
  fields: { label: string; path: string; value: string }[]
}

interface NotionProps {
  cabinetHqId: string
  hubs: NotionHub[]
}

export function NotionCard({ config }: { config: NotionProps }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Notion</h2>
      <div className="mt-4 space-y-6">
        <EditableField
          label="Cabinet HQ Page ID"
          value={config.cabinetHqId}
          onSave={(v) => updateProjectConfig('notion', 'cabinet_hq_id', v)}
          mono
        />
        {config.hubs.map((hub) => (
          <div key={hub.label}>
            <h3 className="mb-3 text-sm font-medium text-zinc-400">{hub.label}</h3>
            <div className="space-y-3 pl-2 border-l border-zinc-800">
              {hub.fields.map((field) => (
                <EditableField
                  key={field.path}
                  label={field.label}
                  value={field.value}
                  onSave={(v) => updateProjectConfig('notion', field.path, v)}
                  mono
                />
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/*  Linear                                                             */
/* ------------------------------------------------------------------ */

interface LinearProps {
  teamKey: string
  workspaceUrl: string
}

export function LinearCard({ config }: { config: LinearProps }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Linear</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Team Key"
          value={config.teamKey}
          onSave={(v) => updateProjectConfig('linear', 'team_key', v)}
          mono
        />
        <EditableField
          label="Workspace URL"
          value={config.workspaceUrl}
          onSave={(v) => updateProjectConfig('linear', 'workspace_url', v)}
          mono
        />
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/*  Neon                                                               */
/* ------------------------------------------------------------------ */

interface NeonProps {
  project: string
  connectionString: string
}

export function NeonCard({ config }: { config: NeonProps }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Neon</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Project Name"
          value={config.project}
          onSave={(v) => updateProjectConfig('neon', 'project', v)}
          mono
        />
        <MaskedField
          label="Connection String (env)"
          value={config.connectionString}
          onSave={async () => ({ success: false, error: 'Connection string is set via environment variable, not config' })}
        />
      </div>
    </div>
  )
}
