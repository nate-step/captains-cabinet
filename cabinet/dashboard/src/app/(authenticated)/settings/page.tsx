import { getGlobalConfig, getDashboardConfig, getConfig } from '@/lib/config'
import {
  ProductSection,
  VoiceSection,
  ImageGenSection,
  EmbeddingsSection,
} from '@/components/settings-forms'
import SettingsModeSwitch from '@/components/consumer/settings-mode-switch'

export const dynamic = 'force-dynamic'

function AdvancedSettings({ config }: { config: ReturnType<typeof getGlobalConfig> }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <div>
        <h1 className="text-2xl font-bold text-white">Settings</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Global configuration for the Cabinet
        </p>
      </div>

      <ProductSection config={config.product} />
      <VoiceSection config={config.voice} />
      <ImageGenSection config={config.image_generation} />
      <EmbeddingsSection config={config.embeddings} />
    </div>
  )
}

export default function SettingsPage() {
  const config = getGlobalConfig()
  const { consumerModeEnabled } = getDashboardConfig()

  // Feature-flag-off: render Advanced directly, never mount the mode switch.
  if (!consumerModeEnabled) {
    return <AdvancedSettings config={config} />
  }

  // Timezone is a platform-level setting on instance/config/platform.yml —
  // read directly from getConfig() since the current typed GlobalConfig
  // doesn't surface it yet. Displayed read-only in Consumer for now.
  const rawConfig = getConfig() as Record<string, unknown>
  const timezone = (rawConfig.captain_timezone as string) || 'UTC'

  // Officer roles from the telegram.officers map — we show a read-only chip
  // roster in Consumer mode. Editing moves to Advanced.
  const telegram = (rawConfig.telegram as Record<string, unknown>) || {}
  const officers = (telegram.officers as Record<string, unknown>) || {}
  const officerRoles = Object.keys(officers)

  return (
    <SettingsModeSwitch
      consumerProps={{ config, officerRoles, timezone }}
    >
      <AdvancedSettings config={config} />
    </SettingsModeSwitch>
  )
}
