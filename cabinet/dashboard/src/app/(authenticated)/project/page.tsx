import { getProjectConfig, getActiveProjectSlug } from '@/lib/config'
import { getEnvVars } from '@/lib/docker'
import {
  ProductIdentityCard,
  TelegramCard,
  NotionCard,
  LinearCard,
  NeonCard,
} from '@/components/project-forms'

export const dynamic = 'force-dynamic'

/* ------------------------------------------------------------------ */
/*  Helpers to safely walk the nested config                           */
/* ------------------------------------------------------------------ */

function str(obj: unknown, key: string): string {
  if (obj && typeof obj === 'object') {
    return ((obj as Record<string, unknown>)[key] as string) || ''
  }
  return ''
}

function rec(obj: unknown, key: string): Record<string, unknown> {
  if (obj && typeof obj === 'object') {
    const v = (obj as Record<string, unknown>)[key]
    if (v && typeof v === 'object') return v as Record<string, unknown>
  }
  return {}
}

/** Human-readable label from a snake_case key */
function humanize(key: string): string {
  return key
    .replace(/_/g, ' ')
    .replace(/\b(id|db|url)\b/gi, (m) => m.toUpperCase())
    .replace(/\b\w/g, (c) => c.toUpperCase())
}

/* ------------------------------------------------------------------ */
/*  Build Notion hub structures from the raw config                    */
/* ------------------------------------------------------------------ */

interface NotionHubDef {
  label: string
  key: string
}

const NOTION_HUBS: NotionHubDef[] = [
  { label: 'Dashboard', key: 'dashboard' },
  { label: 'Business Brain', key: 'business_brain' },
  { label: 'Research Hub', key: 'research_hub' },
  { label: 'Product Hub', key: 'product_hub' },
  { label: 'Engineering Hub', key: 'engineering_hub' },
  { label: 'Cabinet Ops', key: 'cabinet_ops' },
  { label: 'Reference', key: 'reference' },
  { label: 'Archive', key: 'archive' },
]

function buildNotionHubs(notion: Record<string, unknown>) {
  return NOTION_HUBS.map((hub) => {
    const section = rec(notion, hub.key)
    const fields = Object.entries(section).map(([fieldKey, fieldValue]) => ({
      label: humanize(fieldKey),
      path: `${hub.key}.${fieldKey}`,
      value: (fieldValue as string) || '',
    }))
    return { label: hub.label, fields }
  }).filter((hub) => hub.fields.length > 0)
}

/* ------------------------------------------------------------------ */
/*  Page                                                               */
/* ------------------------------------------------------------------ */

export default async function ProjectPage() {
  const config = getProjectConfig()
  const slug = getActiveProjectSlug()
  const env = await getEnvVars()

  const product = rec(config, 'product')
  const notion = rec(config, 'notion')
  const linear = rec(config, 'linear')
  const neon = rec(config, 'neon')
  const telegram = rec(config, 'telegram')
  const telegramOfficers = rec(telegram, 'officers')

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <div>
        <h1 className="text-2xl font-bold text-white">
          Project{' '}
          <span className="text-zinc-500 font-normal">/ {str(product, 'name') || slug}</span>
        </h1>
        <p className="mt-1 text-sm text-zinc-500">
          All project-specific configuration for{' '}
          <span className="font-mono text-zinc-400">{slug}</span>
        </p>
      </div>

      {/* Product Identity */}
      <ProductIdentityCard
        config={{
          name: str(product, 'name'),
          description: str(product, 'description'),
          repo: str(product, 'repo'),
          repoBranch: str(product, 'repo_branch'),
          mountPath: str(product, 'mount_path'),
        }}
      />

      {/* Telegram */}
      <TelegramCard
        config={{
          hqChatId: env.TELEGRAM_HQ_CHAT_ID || '',
          officers: Object.fromEntries(
            ['cos', 'cto', 'cpo', 'cro', 'coo'].map((r) => [
              r,
              str(telegramOfficers, r),
            ]),
          ),
        }}
      />

      {/* Notion */}
      <NotionCard
        config={{
          cabinetHqId: str(notion, 'cabinet_hq_id'),
          hubs: buildNotionHubs(notion),
        }}
      />

      {/* Linear */}
      <LinearCard
        config={{
          teamKey: str(linear, 'team_key'),
          workspaceUrl: str(linear, 'workspace_url'),
        }}
      />

      {/* Neon */}
      <NeonCard
        config={{
          project: str(neon, 'project'),
          connectionString: env.NEON_CONNECTION_STRING || '',
        }}
      />
    </div>
  )
}
