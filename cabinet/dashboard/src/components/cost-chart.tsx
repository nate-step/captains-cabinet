const OFFICER_COLORS: Record<string, string> = {
  cos: '#22c55e', // green-500
  cto: '#3b82f6', // blue-500
  cpo: '#a855f7', // purple-500
  cro: '#f59e0b', // amber-500
  coo: '#ec4899', // pink-500
}

function getColor(role: string): string {
  return OFFICER_COLORS[role] || '#71717a'
}

function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

interface BarChartProps {
  data: { label: string; value: number }[]
  height?: number
}

export function BarChart({ data, height = 200 }: BarChartProps) {
  if (data.length === 0) return null
  const maxVal = Math.max(...data.map((d) => d.value), 1)
  const barWidth = Math.max(12, Math.min(40, (600 - data.length * 4) / data.length))
  const chartWidth = data.length * (barWidth + 4) + 40
  const chartHeight = height
  const bottomPadding = 40
  const topPadding = 20
  const leftPadding = 50
  const drawHeight = chartHeight - bottomPadding - topPadding

  return (
    <svg
      viewBox={`0 0 ${chartWidth} ${chartHeight}`}
      className="w-full"
      style={{ maxHeight: `${height}px` }}
    >
      {/* Y-axis labels */}
      {[0, 0.25, 0.5, 0.75, 1].map((frac) => {
        const y = topPadding + drawHeight * (1 - frac)
        const val = Math.round(maxVal * frac)
        return (
          <g key={frac}>
            <line
              x1={leftPadding}
              y1={y}
              x2={chartWidth}
              y2={y}
              stroke="#3f3f46"
              strokeWidth={0.5}
            />
            <text
              x={leftPadding - 5}
              y={y + 3}
              fill="#71717a"
              fontSize={9}
              textAnchor="end"
            >
              {formatCents(val)}
            </text>
          </g>
        )
      })}

      {/* Bars */}
      {data.map((d, i) => {
        const barH = (d.value / maxVal) * drawHeight
        const x = leftPadding + i * (barWidth + 4)
        const y = topPadding + drawHeight - barH
        return (
          <g key={i}>
            <rect
              x={x}
              y={y}
              width={barWidth}
              height={barH}
              rx={2}
              fill="#22c55e"
              opacity={0.8}
            />
            <text
              x={x + barWidth / 2}
              y={chartHeight - bottomPadding + 14}
              fill="#71717a"
              fontSize={8}
              textAnchor="middle"
            >
              {d.label}
            </text>
          </g>
        )
      })}
    </svg>
  )
}

interface HorizontalBarsProps {
  data: { label: string; value: number; role: string }[]
}

export function HorizontalBars({ data }: HorizontalBarsProps) {
  if (data.length === 0) return null
  const maxVal = Math.max(...data.map((d) => d.value), 1)

  return (
    <div className="space-y-2">
      {data.map((d) => {
        const pct = (d.value / maxVal) * 100
        return (
          <div key={d.role} className="flex items-center gap-3">
            <span className="w-10 shrink-0 text-right text-xs font-medium text-zinc-400 uppercase">
              {d.role}
            </span>
            <div className="relative h-5 flex-1 overflow-hidden rounded bg-zinc-800">
              <div
                className="absolute inset-y-0 left-0 rounded"
                style={{
                  width: `${pct}%`,
                  backgroundColor: getColor(d.role),
                  opacity: 0.8,
                }}
              />
            </div>
            <span className="w-16 shrink-0 text-right text-xs text-zinc-500">
              {formatCents(d.value)}
            </span>
          </div>
        )
      })}
    </div>
  )
}

interface StackedBarChartProps {
  data: {
    label: string
    segments: { role: string; value: number }[]
    total: number
  }[]
  height?: number
}

export function StackedBarChart({ data, height = 200 }: StackedBarChartProps) {
  if (data.length === 0) return null
  const maxVal = Math.max(...data.map((d) => d.total), 1)
  const barWidth = Math.max(12, Math.min(40, (600 - data.length * 4) / data.length))
  const chartWidth = data.length * (barWidth + 4) + 40
  const chartHeight = height
  const bottomPadding = 40
  const topPadding = 20
  const leftPadding = 50
  const drawHeight = chartHeight - bottomPadding - topPadding

  return (
    <svg
      viewBox={`0 0 ${chartWidth} ${chartHeight}`}
      className="w-full"
      style={{ maxHeight: `${height}px` }}
    >
      {/* Y-axis grid lines */}
      {[0, 0.25, 0.5, 0.75, 1].map((frac) => {
        const y = topPadding + drawHeight * (1 - frac)
        const val = Math.round(maxVal * frac)
        return (
          <g key={frac}>
            <line
              x1={leftPadding}
              y1={y}
              x2={chartWidth}
              y2={y}
              stroke="#3f3f46"
              strokeWidth={0.5}
            />
            <text
              x={leftPadding - 5}
              y={y + 3}
              fill="#71717a"
              fontSize={9}
              textAnchor="end"
            >
              {formatCents(val)}
            </text>
          </g>
        )
      })}

      {/* Stacked bars */}
      {data.map((d, i) => {
        const x = leftPadding + i * (barWidth + 4)
        let currentY = topPadding + drawHeight

        return (
          <g key={i}>
            {d.segments.map((seg) => {
              const segH = (seg.value / maxVal) * drawHeight
              currentY -= segH
              return (
                <rect
                  key={seg.role}
                  x={x}
                  y={currentY}
                  width={barWidth}
                  height={segH}
                  fill={getColor(seg.role)}
                  opacity={0.8}
                />
              )
            })}
            <text
              x={x + barWidth / 2}
              y={chartHeight - bottomPadding + 14}
              fill="#71717a"
              fontSize={8}
              textAnchor="middle"
            >
              {d.label}
            </text>
          </g>
        )
      })}
    </svg>
  )
}

export function ChartLegend() {
  return (
    <div className="flex flex-wrap gap-4">
      {Object.entries(OFFICER_COLORS).map(([role, color]) => (
        <div key={role} className="flex items-center gap-1.5">
          <span
            className="h-2.5 w-2.5 rounded-full"
            style={{ backgroundColor: color }}
          />
          <span className="text-xs text-zinc-500 uppercase">{role}</span>
        </div>
      ))}
    </div>
  )
}
