'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import dynamic from 'next/dynamic'
import { useRouter } from 'next/navigation'
import type { LibraryGraphData, LibraryGraphNode } from '@/lib/library'

// react-force-graph-2d ships as ESM and reaches for `window` at import time —
// next/dynamic with ssr:false keeps the bundle out of the SSR pass entirely.
const ForceGraph2D = dynamic(() => import('react-force-graph-2d'), { ssr: false })

interface SpaceMeta {
  id: string
  name: string
}

interface Props {
  spaces: SpaceMeta[]
}

interface GraphNode extends LibraryGraphNode {
  x?: number
  y?: number
  vx?: number
  vy?: number
}

interface GraphLink {
  [key: string]: unknown
  source: string | GraphNode
  target: string | GraphNode
}

// Spec 045 Phase 2 — color palette indexed by Space-id position. Stable across
// renders because the spaces array order is deterministic from layout SSR.
const SPACE_PALETTE = [
  '#60a5fa', // blue-400
  '#a78bfa', // violet-400
  '#34d399', // emerald-400
  '#fbbf24', // amber-400
  '#f87171', // red-400
  '#fb7185', // rose-400
  '#22d3ee', // cyan-400
  '#a3e635', // lime-400
  '#f472b6', // pink-400
  '#94a3b8', // slate-400
]

export default function GraphCanvas({ spaces }: Props) {
  const router = useRouter()
  const [data, setData] = useState<LibraryGraphData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [showLabels, setShowLabels] = useState(true)
  const [selectedSpaces, setSelectedSpaces] = useState<Set<string>>(new Set())
  const containerRef = useRef<HTMLDivElement | null>(null)
  const [size, setSize] = useState({ width: 800, height: 600 })

  const spaceColor = useMemo(() => {
    const map = new Map<string, string>()
    spaces.forEach((s, i) => map.set(s.id, SPACE_PALETTE[i % SPACE_PALETTE.length]))
    return map
  }, [spaces])

  const spaceName = useMemo(() => {
    const map = new Map<string, string>()
    spaces.forEach((s) => map.set(s.id, s.name))
    return map
  }, [spaces])

  // Fetch graph data on mount + whenever space filter changes.
  useEffect(() => {
    let cancelled = false
    const url = new URL('/api/library/graph', window.location.origin)
    if (selectedSpaces.size > 0) {
      url.searchParams.set('space_ids', Array.from(selectedSpaces).join(','))
    }
    setLoading(true)
    setError(null)
    fetch(url.toString())
      .then((r) => {
        if (!r.ok) throw new Error(`graph fetch failed: ${r.status}`)
        return r.json()
      })
      .then((d: LibraryGraphData) => {
        if (cancelled) return
        setData(d)
        setLoading(false)
      })
      .catch((err) => {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'failed to load graph')
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [selectedSpaces])

  // Resize observer for responsive canvas sizing.
  useEffect(() => {
    if (!containerRef.current) return
    const el = containerRef.current
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const { width, height } = entry.contentRect
        setSize({ width: Math.max(300, width), height: Math.max(400, height) })
      }
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const searchLower = search.trim().toLowerCase()
  const matchedNodeIds = useMemo(() => {
    if (!searchLower || !data) return null
    return new Set(
      data.nodes.filter((n) => n.title.toLowerCase().includes(searchLower)).map((n) => n.id)
    )
  }, [searchLower, data])

  const handleNodeClick = useCallback(
    (node: GraphNode) => {
      if (!node.space_id || !node.id) return
      router.push(`/library/${node.space_id}/${node.id}`)
    },
    [router]
  )

  const nodeCanvasObject = useCallback(
    (node: GraphNode, ctx: CanvasRenderingContext2D, globalScale: number) => {
      if (typeof node.x !== 'number' || typeof node.y !== 'number') return
      const baseRadius = 4 + Math.min(8, Math.sqrt(node.degree || 0) * 1.5)
      const isMatch = matchedNodeIds === null || matchedNodeIds.has(node.id)
      const fill = spaceColor.get(node.space_id) ?? '#94a3b8'

      ctx.beginPath()
      ctx.arc(node.x, node.y, baseRadius, 0, 2 * Math.PI)
      ctx.fillStyle = isMatch ? fill : 'rgba(120, 120, 120, 0.25)'
      ctx.fill()
      ctx.strokeStyle = isMatch ? 'rgba(255,255,255,0.6)' : 'rgba(255,255,255,0.15)'
      ctx.lineWidth = 1 / globalScale
      ctx.stroke()

      // Label culling — only render labels at zoom>=1 unless toggle forces them.
      if (showLabels && (globalScale >= 1 || isMatch)) {
        const fontSize = Math.max(10, 12 / globalScale)
        ctx.font = `${fontSize}px sans-serif`
        ctx.fillStyle = isMatch ? 'rgba(255,255,255,0.85)' : 'rgba(255,255,255,0.25)'
        ctx.textAlign = 'left'
        ctx.textBaseline = 'middle'
        const label = node.title.length > 32 ? node.title.slice(0, 30) + '…' : node.title
        ctx.fillText(label, node.x + baseRadius + 2, node.y)
      }
    },
    [spaceColor, matchedNodeIds, showLabels]
  )

  const linkColor = useCallback(() => 'rgba(140, 140, 140, 0.35)', [])

  const toggleSpace = (id: string) => {
    setSelectedSpaces((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const totalNodes = data?.nodes.length ?? 0
  const totalEdges = data?.edges.length ?? 0
  const totalRecordCount = data?.total_record_count ?? 0
  const matchedCount = matchedNodeIds === null ? null : matchedNodeIds.size
  const isTruncated = totalRecordCount > totalNodes && totalNodes > 0

  return (
    <div className="flex h-[calc(100vh-7rem)] flex-col gap-3">
      {/* Toolbar */}
      <div className="flex flex-wrap items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-900/50 p-3 text-sm">
        <input
          type="search"
          placeholder="Search records…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="rounded-md border border-zinc-700 bg-zinc-950 px-2 py-1 text-white placeholder:text-zinc-500 focus:border-zinc-500 focus:outline-none"
        />
        <label className="flex items-center gap-1.5 text-zinc-300">
          <input
            type="checkbox"
            checked={showLabels}
            onChange={(e) => setShowLabels(e.target.checked)}
          />
          Labels
        </label>
        <div className="flex flex-wrap items-center gap-1.5">
          {spaces.map((s) => {
            const active = selectedSpaces.size === 0 || selectedSpaces.has(s.id)
            const color = spaceColor.get(s.id) ?? '#94a3b8'
            return (
              <button
                key={s.id}
                type="button"
                onClick={() => toggleSpace(s.id)}
                className={`flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs ${
                  active
                    ? 'border-zinc-600 bg-zinc-800 text-white'
                    : 'border-zinc-800 bg-zinc-950 text-zinc-500'
                }`}
              >
                <span
                  className="inline-block h-2 w-2 rounded-full"
                  style={{ background: color }}
                />
                {s.name}
              </button>
            )
          })}
        </div>
        <div className="ml-auto flex items-center gap-2 text-xs text-zinc-500">
          {loading && 'loading…'}
          {!loading && (
            <>
              <span>
                {isTruncated ? (
                  <>
                    showing top {totalNodes} of {totalRecordCount} record
                    {totalRecordCount === 1 ? '' : 's'} (by degree) · {totalEdges} edge
                    {totalEdges === 1 ? '' : 's'}
                  </>
                ) : (
                  <>
                    {totalNodes} record{totalNodes === 1 ? '' : 's'} · {totalEdges} edge
                    {totalEdges === 1 ? '' : 's'}
                  </>
                )}
                {matchedCount !== null && ` · ${matchedCount} matched`}
              </span>
              {isTruncated && (
                <span
                  className="rounded-md border border-zinc-700 bg-zinc-800/60 px-2 py-0.5 text-zinc-400"
                  title={`${totalRecordCount - totalNodes} lower-degree records not rendered. Filter by Space to scope, or pass ?limit=${Math.min(totalRecordCount, 5000)} via the URL.`}
                >
                  truncated
                </span>
              )}
              {totalNodes > 1000 && (
                <span
                  className="rounded-md border border-amber-500/40 bg-amber-500/10 px-2 py-0.5 text-amber-300"
                  title="Large graphs may be sluggish on iOS Safari and low-power devices. Filter by Space to scope."
                >
                  large graph — perf may degrade
                </span>
              )}
            </>
          )}
        </div>
      </div>

      {/* Canvas */}
      <div
        ref={containerRef}
        className="relative flex-1 overflow-hidden rounded-lg border border-zinc-800 bg-zinc-950"
      >
        {error && (
          <div className="absolute inset-0 flex items-center justify-center text-sm text-red-400">
            {error}
          </div>
        )}
        {!error && data && data.nodes.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center text-sm text-zinc-500">
            No records yet. Create some library records to see the graph.
          </div>
        )}
        {!error && data && data.nodes.length > 0 && (
          <ForceGraph2D
            graphData={{ nodes: data.nodes as GraphNode[], links: data.edges as unknown as GraphLink[] }}
            width={size.width}
            height={size.height}
            backgroundColor="#09090b"
            warmupTicks={100}
            cooldownTicks={0}
            nodeRelSize={4}
            nodeCanvasObject={(node, ctx, globalScale) =>
              nodeCanvasObject(node as GraphNode, ctx, globalScale)
            }
            nodePointerAreaPaint={(node, color, ctx) => {
              const n = node as GraphNode
              if (typeof n.x !== 'number' || typeof n.y !== 'number') return
              const r = 4 + Math.min(8, Math.sqrt(n.degree || 0) * 1.5)
              ctx.fillStyle = color
              ctx.beginPath()
              ctx.arc(n.x, n.y, r, 0, 2 * Math.PI)
              ctx.fill()
            }}
            linkSource="source"
            linkTarget="target"
            linkColor={linkColor}
            linkWidth={0.6}
            onNodeClick={(node) => handleNodeClick(node as GraphNode)}
            nodeLabel={(node) => {
              const n = node as GraphNode
              const space = spaceName.get(n.space_id) ?? ''
              return `${n.title} · ${space} · degree ${n.degree}`
            }}
          />
        )}
      </div>
    </div>
  )
}
