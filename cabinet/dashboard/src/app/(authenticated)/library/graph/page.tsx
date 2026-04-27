import { listSpaces } from '@/lib/library'
import GraphCanvas from '@/components/library/GraphCanvas'

export const dynamic = 'force-dynamic'

// Spec 045 Phase 2 — /library/graph
// Force-directed graph view of [[wiki-link]] connections across the Library.
// Server component fetches Space metadata (for the cluster-color legend +
// filter chips); the GraphCanvas client component fetches /api/library/graph
// on mount and re-fetches when the Space filter changes.
//
// Visual choices per spec:
// - 2D mode (clearer labels, less disorientation than 3D for knowledge graphs)
// - cluster-color by space_id, node-size by degree
// - warmupTicks=100, cooldownTicks=0 → instant render, no jitter post-paint
// - label culling at zoom<1 to keep dense corpora readable
// - click-to-open record at /library/[spaceId]/[recordId]
export default async function LibraryGraphPage() {
  let spaces: Array<{ id: string; name: string }>
  try {
    const rows = await listSpaces()
    spaces = rows.map((s) => ({ id: s.id, name: s.name }))
  } catch (err) {
    console.error('[LibraryGraphPage] listSpaces failed', err)
    spaces = []
  }

  return (
    <div className="flex flex-col gap-4">
      <div>
        <h1 className="text-2xl font-bold text-white">Library graph</h1>
        <p className="mt-1 text-sm text-zinc-500">
          [[wiki-link]] network across all Spaces. Click a node to open the record. Filter by Space
          using the chips below; toggle labels to declutter dense areas.
        </p>
      </div>
      <GraphCanvas spaces={spaces} />
    </div>
  )
}
