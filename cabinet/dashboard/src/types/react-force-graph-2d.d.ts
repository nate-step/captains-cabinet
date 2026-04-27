// Minimal ambient declaration for react-force-graph-2d so `npx tsc --noEmit`
// passes when node_modules is not yet installed (e.g., on dev workstations
// without `npm install` having run since the dep was added). The real types
// shipped with the package take precedence at runtime/CI under `npm ci`.
declare module 'react-force-graph-2d' {
  import type { ComponentType } from 'react'

  export interface ForceGraphNode {
    id?: string | number
    x?: number
    y?: number
    vx?: number
    vy?: number
    [key: string]: unknown
  }

  export interface ForceGraphLink {
    source: string | number | ForceGraphNode
    target: string | number | ForceGraphNode
    [key: string]: unknown
  }

  export interface ForceGraphData<N = ForceGraphNode, L = ForceGraphLink> {
    nodes: N[]
    links: L[]
  }

  export interface ForceGraph2DProps<N = ForceGraphNode, L = ForceGraphLink> {
    graphData?: ForceGraphData<N, L>
    width?: number
    height?: number
    backgroundColor?: string
    warmupTicks?: number
    cooldownTicks?: number
    nodeRelSize?: number
    nodeCanvasObject?: (node: N, ctx: CanvasRenderingContext2D, globalScale: number) => void
    nodePointerAreaPaint?: (node: N, color: string, ctx: CanvasRenderingContext2D) => void
    linkSource?: string
    linkTarget?: string
    linkColor?: string | ((link: L) => string)
    linkWidth?: number | ((link: L) => number)
    onNodeClick?: (node: N, event: MouseEvent) => void
    nodeLabel?: string | ((node: N) => string)
    [key: string]: unknown
  }

  const ForceGraph2D: ComponentType<ForceGraph2DProps>
  export default ForceGraph2D
}
