import { readAllGovernanceFiles } from '@/actions/governance'
import GovernanceEditor from '@/components/governance-editor'

export const dynamic = 'force-dynamic'

export default async function GovernancePage() {
  const files = await readAllGovernanceFiles()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <div>
        <h1 className="text-2xl font-bold text-white">Governance</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Foundational documents that govern all officer behavior. Only the Captain can edit these.
        </p>
      </div>

      <GovernanceEditor files={files} />
    </div>
  )
}
