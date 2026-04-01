import { getGlobalConfig } from '@/lib/config'
import {
  ProductSection,
  VoiceSection,
  ImageGenSection,
  EmbeddingsSection,
} from '@/components/settings-forms'

export const dynamic = 'force-dynamic'

export default function SettingsPage() {
  const config = getGlobalConfig()

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
