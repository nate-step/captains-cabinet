/**
 * Card 2: YOUR COSTS — Spec 032 Consumer Mode.
 *
 * Shows today's cost, this month's cost, and a pace-vs-budget ring.
 *
 * Ring color driven by max(monthly_pace_ratio, daily_anomaly_ratio) per spec §2 / COO 32.4.
 * Budget alerts (Telegram/email) are NOT affected by this card — this is view-only (CRO v3).
 *
 * Budget source: getConfig().spending_limits.daily_per_officer_usd × 30
 * (spec uses spending_limits; monthly budget field tracked as PR 4 / Settings subset).
 */

import redis from '@/lib/redis'
import { getConfig } from '@/lib/config'

function formatMicro(micro: number): string {
  const dollars = micro / 1_000_000
  return `$${dollars.toFixed(2)}`
}

interface BudgetRingProps {
  ratio: number // 0–∞, where 1.0 = 100% of budget
  label: string
  sublabel: string
}

function BudgetRing({ ratio, label, sublabel }: BudgetRingProps) {
  // SVG donut ring: radius 36, circumference ~226
  const r = 36
  const circ = 2 * Math.PI * r
  const clamped = Math.min(ratio, 1.0)
  const dash = clamped * circ
  const gap = circ - dash

  const color =
    ratio > 1.0 ? '#ef4444' : // red
    ratio >= 0.8 ? '#f59e0b' : // amber
    '#22c55e' // green

  return (
    <div className="flex items-center gap-4">
      <div className="relative h-20 w-20 shrink-0">
        <svg viewBox="0 0 80 80" className="h-full w-full -rotate-90">
          {/* Track */}
          <circle cx="40" cy="40" r={r} fill="none" stroke="#3f3f46" strokeWidth="8" />
          {/* Fill */}
          {ratio > 0 && (
            <circle
              cx="40"
              cy="40"
              r={r}
              fill="none"
              stroke={color}
              strokeWidth="8"
              strokeDasharray={`${dash} ${gap}`}
              strokeLinecap="round"
            />
          )}
        </svg>
        <div className="absolute inset-0 flex items-center justify-center">
          <span className="text-xs font-bold text-white">{Math.round(clamped * 100)}%</span>
        </div>
      </div>
      <div>
        <p className="text-sm font-medium text-zinc-300">{label}</p>
        <p className="text-xs text-zinc-500">{sublabel}</p>
      </div>
    </div>
  )
}

export default async function CardCosts() {
  const config = getConfig()
  const spendingLimits = (config.spending_limits as Record<string, unknown> | undefined) ?? {}
  const dailyPerOfficerUsd = (spendingLimits.daily_per_officer_usd as number | undefined) ?? 0
  const monthlyBudgetUsd = dailyPerOfficerUsd > 0 ? dailyPerOfficerUsd * 30 : 0

  const today = new Date().toISOString().split('T')[0]
  const now = new Date()
  const dayOfMonth = now.getUTCDate()
  const daysInMonth = new Date(now.getUTCFullYear(), now.getUTCMonth() + 1, 0).getUTCDate()

  // Fetch today's token cost hash
  const todayHash = await redis.hgetall(`cabinet:cost:tokens:daily:${today}`)

  // Sum today's cost from per-officer cost_micro fields
  let todayCostMicro = 0
  if (todayHash) {
    for (const [key, val] of Object.entries(todayHash)) {
      if (key.endsWith('_cost_micro')) {
        todayCostMicro += parseInt(val, 10) || 0
      }
    }
  }

  // Sum month-to-date by iterating daily hashes
  let monthCostMicro = 0
  const monthFetches: Promise<void>[] = []
  for (let i = 0; i < dayOfMonth; i++) {
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), dayOfMonth - i))
    const ds = d.toISOString().split('T')[0]
    monthFetches.push(
      redis.hgetall(`cabinet:cost:tokens:daily:${ds}`).then((h) => {
        if (!h) return
        for (const [key, val] of Object.entries(h)) {
          if (key.endsWith('_cost_micro')) monthCostMicro += parseInt(val, 10) || 0
        }
      })
    )
  }
  await Promise.all(monthFetches)

  const hasBudget = monthlyBudgetUsd > 0
  const monthlyBudgetMicro = monthlyBudgetUsd * 1_000_000

  // Daily anomaly detection (COO 32.4)
  const dailyAverageMicro = hasBudget ? monthlyBudgetMicro / 30 : 0
  const dailyAnomalyRatio = dailyAverageMicro > 0 ? todayCostMicro / dailyAverageMicro : 0

  // Monthly pace ratio: (spent so far) / (budget × fraction of month elapsed)
  const monthFractionElapsed = dayOfMonth / daysInMonth
  const monthlyPaceRatio =
    hasBudget && monthFractionElapsed > 0
      ? monthCostMicro / (monthlyBudgetMicro * monthFractionElapsed)
      : 0

  const effectiveRatio = Math.max(monthlyPaceRatio, dailyAnomalyRatio)

  const dailyAnomaly3x = dailyAnomalyRatio >= 3
  const dailyAnomaly10x = dailyAnomalyRatio >= 10

  const noData = todayCostMicro === 0 && monthCostMicro === 0

  // Budget ring color label
  const ringLabel = hasBudget
    ? `${Math.round(effectiveRatio * 100)}% of $${monthlyBudgetUsd} budget · ${
        effectiveRatio < 0.8 ? 'on track' : effectiveRatio < 1.0 ? 'watch closely' : 'over budget'
      }`
    : 'No monthly budget configured'
  const ringSublabel = hasBudget
    ? `Day ${dayOfMonth} of ${daysInMonth}`
    : 'Set a budget in Settings to track pace'

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
          Your Costs
        </h2>
        <a
          href="/costs"
          className="text-xs text-zinc-500 transition-colors hover:text-zinc-300"
        >
          See details &rarr;
        </a>
      </div>

      {noData && !hasBudget ? (
        /* No data + no budget */
        <div className="py-2">
          <p className="text-sm text-zinc-400">
            Nothing to report yet &mdash; check back after your first officer session.
          </p>
          <p className="mt-2 text-xs text-amber-400">
            Monthly budget not set. You won&apos;t see pace-vs-budget until configured.
          </p>
          <a
            href="/settings"
            className="mt-1 inline-flex items-center gap-1 text-xs text-zinc-500 transition-colors hover:text-zinc-300"
          >
            Set your budget &rarr;
          </a>
        </div>
      ) : noData ? (
        /* No data but budget configured */
        <div className="py-2">
          <p className="text-sm text-zinc-400">
            Nothing to report yet &mdash; check back after your first officer session.
          </p>
        </div>
      ) : (
        <>
          {/* Cost rows */}
          <div className="mb-4 grid grid-cols-2 gap-3">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-zinc-500">Today</p>
              <p className="mt-1 text-xl font-bold text-white">
                {formatMicro(todayCostMicro)}
                {dailyAnomaly3x && (
                  <span className="ml-1.5 text-sm text-amber-400" title="Today is elevated vs daily average">
                    {dailyAnomaly10x ? '⚠' : '▲'}
                  </span>
                )}
              </p>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-zinc-500">
                This Month
              </p>
              <p className="mt-1 text-xl font-bold text-white">{formatMicro(monthCostMicro)}</p>
            </div>
          </div>

          {/* Anomaly warning */}
          {dailyAnomaly10x && (
            <div className="mb-4 rounded-lg border border-red-500/30 bg-red-900/10 px-3 py-2">
              <p className="text-xs text-red-400">
                ⚠ Today is {Math.round(dailyAnomalyRatio)}x your daily average &mdash; check officer activity
              </p>
            </div>
          )}
          {!dailyAnomaly10x && dailyAnomaly3x && (
            <div className="mb-4 rounded-lg border border-amber-500/30 bg-amber-900/10 px-3 py-2">
              <p className="text-xs text-amber-400">
                ▲ Today is elevated ({Math.round(dailyAnomalyRatio)}x daily average)
              </p>
            </div>
          )}

          {/* Pace ring — only when budget configured */}
          {hasBudget ? (
            <BudgetRing
              ratio={effectiveRatio}
              label={ringLabel}
              sublabel={ringSublabel}
            />
          ) : (
            <p className="text-xs text-zinc-600">
              Set a monthly budget in Settings to see pace tracking.
            </p>
          )}
        </>
      )}
    </div>
  )
}
