'use client'

import { EditableField, ToggleField } from '@/components/editable-field'
import {
  updateProductConfig,
  updateGlobalVoiceConfig,
  updateImageGenConfig,
  updateEmbeddingsConfig,
} from '@/actions/config'
import type { GlobalConfig } from '@/lib/config'

export function ProductSection({ config }: { config: GlobalConfig['product'] }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Product</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Name"
          value={config.name}
          onSave={(v) => updateProductConfig('name', v)}
        />
        <EditableField
          label="Description"
          value={config.description}
          onSave={(v) => updateProductConfig('description', v)}
          type="textarea"
        />
        <EditableField
          label="Captain Name"
          value={config.captain_name}
          onSave={(v) => updateProductConfig('captain_name', v)}
        />
        <EditableField
          label="Repository"
          value={config.repo}
          onSave={(v) => updateProductConfig('repo', v)}
          mono
        />
        <EditableField
          label="Branch"
          value={config.repo_branch}
          onSave={(v) => updateProductConfig('repo_branch', v)}
          mono
        />
      </div>
    </div>
  )
}

export function VoiceSection({ config }: { config: GlobalConfig['voice'] }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Voice (Global)</h2>
      <div className="mt-4 space-y-4">
        <ToggleField
          label="Enabled"
          enabled={config.enabled}
          onToggle={(v) => updateGlobalVoiceConfig('enabled', String(v))}
        />
        <EditableField
          label="Mode"
          value={config.mode}
          onSave={(v) => updateGlobalVoiceConfig('mode', v)}
        />
        <ToggleField
          label="Naturalize"
          description="Apply voice personality prompts"
          enabled={config.naturalize}
          onToggle={(v) => updateGlobalVoiceConfig('naturalize', String(v))}
        />
        <EditableField
          label="Provider"
          value={config.provider}
          onSave={(v) => updateGlobalVoiceConfig('provider', v)}
        />
        <EditableField
          label="Model"
          value={config.model}
          onSave={(v) => updateGlobalVoiceConfig('model', v)}
          mono
        />
      </div>
    </div>
  )
}

export function ImageGenSection({ config }: { config: GlobalConfig['image_generation'] }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Image Generation</h2>
      <div className="mt-4 space-y-4">
        <ToggleField
          label="Enabled"
          enabled={config.enabled}
          onToggle={(v) => updateImageGenConfig('enabled', String(v))}
        />
        <EditableField
          label="Provider"
          value={config.provider}
          onSave={(v) => updateImageGenConfig('provider', v)}
        />
        <EditableField
          label="Model"
          value={config.model}
          onSave={(v) => updateImageGenConfig('model', v)}
          mono
        />
      </div>
    </div>
  )
}

export function EmbeddingsSection({ config }: { config: GlobalConfig['embeddings'] }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h2 className="text-lg font-semibold text-white">Embeddings</h2>
      <div className="mt-4 space-y-4">
        <EditableField
          label="Provider"
          value={config.provider}
          onSave={(v) => updateEmbeddingsConfig('provider', v)}
        />
        <EditableField
          label="Storage Model"
          value={config.models.storage}
          onSave={(v) => updateEmbeddingsConfig('models.storage', v)}
          mono
        />
        <EditableField
          label="Query Model"
          value={config.models.query}
          onSave={(v) => updateEmbeddingsConfig('models.query', v)}
          mono
        />
        <EditableField
          label="Dimensions"
          value={String(config.dimensions)}
          onSave={(v) => updateEmbeddingsConfig('dimensions', v)}
        />
      </div>
    </div>
  )
}
