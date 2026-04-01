import { getNotionConfig, getLinearConfig } from '@/lib/config'
import { getEnvVars } from '@/lib/docker'
import {
  TelegramSection,
  NotionSection,
  LinearSection,
  ApiKeysSection,
} from '@/components/integrations-forms'

export const dynamic = 'force-dynamic'

export default async function IntegrationsPage() {
  const [envVars, notionConfig, linearConfig] = await Promise.all([
    getEnvVars(),
    Promise.resolve(getNotionConfig()),
    Promise.resolve(getLinearConfig()),
  ])

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-white">Integrations</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Service connections and API keys
        </p>
      </div>

      <TelegramSection envVars={envVars} />
      <NotionSection notionConfig={notionConfig} />
      <LinearSection linearConfig={linearConfig} />
      <ApiKeysSection envVars={envVars} />
    </div>
  )
}
