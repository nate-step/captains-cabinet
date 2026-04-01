import { getCostHistory } from '@/lib/redis'
import { BarChart, HorizontalBars, StackedBarChart, ChartLegend } from '@/components/cost-chart'

export const dynamic = 'force-dynamic'

function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

export default async function CostsPage() {
  const history = await getCostHistory(30)
  const today = history[0]
  const last7 = history.slice(0, 7).reverse()
  const monthlyTotal = history.reduce((sum, d) => sum + d.total, 0)

  // Per-officer totals for today
  const officerTodayData = today
    ? Object.entries(today.officers)
        .map(([role, value]) => ({ label: role.toUpperCase(), value, role }))
        .sort((a, b) => b.value - a.value)
    : []

  // 7-day trend data
  const trendData = last7.map((d) => ({
    label: d.date.slice(5), // MM-DD
    value: d.total,
  }))

  // Stacked chart data
  const stackedData = last7.map((d) => ({
    label: d.date.slice(5),
    total: d.total,
    segments: Object.entries(d.officers)
      .map(([role, value]) => ({ role, value }))
      .sort((a, b) => b.value - a.value),
  }))

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <div>
        <h1 className="text-2xl font-bold text-white">Cost Analytics</h1>
        <p className="mt-1 text-sm text-zinc-500">
          API usage costs across all officers
        </p>
      </div>

      {/* Top stats */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
          <span className="text-sm text-zinc-500">Today</span>
          <p className="mt-1 text-3xl font-bold text-white">
            {today ? formatCents(today.total) : '$0.00'}
          </p>
        </div>
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
          <span className="text-sm text-zinc-500">7-Day Average</span>
          <p className="mt-1 text-3xl font-bold text-white">
            {formatCents(
              Math.round(last7.reduce((s, d) => s + d.total, 0) / Math.max(last7.length, 1))
            )}
          </p>
        </div>
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
          <span className="text-sm text-zinc-500">Monthly Total (30d)</span>
          <p className="mt-1 text-3xl font-bold text-white">
            {formatCents(monthlyTotal)}
          </p>
        </div>
      </div>

      {/* Per-officer breakdown today */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Today&apos;s Breakdown</h2>
        <div className="mt-4">
          <HorizontalBars data={officerTodayData} />
        </div>
      </div>

      {/* 7-day trend */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-white">7-Day Trend</h2>
          <ChartLegend />
        </div>
        <div className="mt-4">
          <BarChart data={trendData} height={220} />
        </div>
      </div>

      {/* Stacked bar chart */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">7-Day Per-Officer Breakdown</h2>
        <div className="mt-4">
          <StackedBarChart data={stackedData} height={220} />
        </div>
      </div>

      {/* 30-day table */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Last 30 Days</h2>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-zinc-800">
                <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Date</th>
                <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Total</th>
                {['cos', 'cto', 'cpo', 'cro', 'coo'].map((role) => (
                  <th key={role} className="font-medium text-zinc-500 uppercase" style={{ padding: '8px 12px' }}>
                    {role}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {history.map((day) => (
                <tr key={day.date} className="border-b border-zinc-800/50">
                  <td className="text-zinc-300" style={{ padding: '10px 12px' }}>{day.date}</td>
                  <td className="font-medium text-white" style={{ padding: '10px 12px' }}>
                    {formatCents(day.total)}
                  </td>
                  {['cos', 'cto', 'cpo', 'cro', 'coo'].map((role) => (
                    <td key={role} className="text-zinc-400" style={{ padding: '10px 12px' }}>
                      {formatCents(day.officers[role] || 0)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
