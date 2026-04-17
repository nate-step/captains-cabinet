/**
 * Card 0: YOUR PRODUCTS — Spec 032 Consumer Mode.
 *
 * Shows health/Sentry/Vercel status for the active product. Server component.
 * Hidden when products list is empty (spec §2 / AC #14).
 */

import { getConfig } from '@/lib/config'
import { getLatestProdDeploy } from '@/lib/vercel'
import { getSentryStats } from '@/lib/sentry'

function ageLabel(seconds: number): string {
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.round(seconds / 3600)}h ago`
  return `${Math.round(seconds / 86400)}d ago`
}

type ProductStatus = 'green' | 'amber' | 'red'

function StatusDot({ status }: { status: ProductStatus }) {
  const map = {
    green: 'bg-green-500',
    amber: 'bg-amber-400',
    red: 'bg-red-500',
  }
  return <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${map[status]}`} />
}

function statusEmoji(status: ProductStatus) {
  return status === 'green' ? '🟢' : status === 'amber' ? '🟡' : '🔴'
}

function statusLabel(status: ProductStatus) {
  return status === 'green' ? 'all systems normal' : status === 'amber' ? 'degraded' : 'SERVICE DEGRADED'
}

export default async function CardProducts() {
  const config = getConfig()
  const products = (config.products as unknown[] | undefined) ?? []

  // Hide card entirely when no products configured (spec §7 "No products configured")
  if (products.length === 0) return null

  const [deploy, sentry] = await Promise.all([getLatestProdDeploy(), getSentryStats()])

  const productName = (config.product as Record<string, unknown>)?.name as string ?? 'Your App'

  // Determine overall status
  // Compute worst-case status: severity order red > amber > green
  function worsen(current: ProductStatus, next: ProductStatus): ProductStatus {
    const rank: Record<ProductStatus, number> = { green: 0, amber: 1, red: 2 }
    return rank[next] > rank[current] ? next : current
  }

  let status: ProductStatus = 'green'

  if (deploy.configured) {
    if (deploy.status === 'ERROR' || deploy.status === 'CANCELED') {
      status = worsen(status, 'red')
    } else if (deploy.status === 'BUILDING' || deploy.status === 'QUEUED') {
      status = worsen(status, 'amber')
    } else if (deploy.ageSeconds !== null && deploy.ageSeconds > 7 * 86400) {
      // No deploy in 7 days → amber (stale per spec)
      status = worsen(status, 'amber')
    }
  }

  if (sentry.configured && sentry.isSpiking) {
    status = worsen(status, 'red')
  } else if (sentry.configured && sentry.issues24h !== null && sentry.issues24h > 0) {
    status = worsen(status, 'amber')
  }

  const isDegraded = status !== 'green'

  return (
    <div
      className={`rounded-xl border p-5 transition-colors ${
        status === 'red'
          ? 'border-red-500/40 bg-red-900/10'
          : status === 'amber'
            ? 'border-amber-500/30 bg-amber-900/10'
            : 'border-zinc-800 bg-zinc-900'
      }`}
    >
      {/* Card header */}
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
          Your Products
        </h2>
        {isDegraded && (
          <span className="text-xs font-medium text-red-400">Needs attention</span>
        )}
      </div>

      {/* Product row */}
      <div className="flex items-start gap-3">
        <div className="mt-0.5">
          <StatusDot status={status} />
        </div>
        <div className="min-w-0 flex-1">
          <p className="font-semibold text-white">
            {statusEmoji(status)} {productName} &mdash; {statusLabel(status)}
          </p>

          {/* Deploy info */}
          {deploy.configured && (
            <p className="mt-1 text-sm text-zinc-400">
              Last deploy:{' '}
              {deploy.ageSeconds !== null ? ageLabel(deploy.ageSeconds) : 'unknown'}
              {deploy.status !== 'READY' && deploy.status !== 'unknown' && (
                <span className="ml-2 font-medium text-amber-400">
                  ({deploy.status.toLowerCase()})
                </span>
              )}
            </p>
          )}

          {/* Sentry info */}
          {sentry.configured && sentry.issues24h !== null && (
            <p className="mt-0.5 text-sm text-zinc-400">
              {sentry.issues24h === 0
                ? '0 errors in last 24h'
                : `${sentry.issues24h} error${sentry.issues24h !== 1 ? 's' : ''} in last 24h`}
            </p>
          )}

          {/* No deploy data yet */}
          {!deploy.configured && !sentry.configured && (
            <p className="mt-1 text-sm text-zinc-500">
              Nothing deployed yet &mdash; health monitoring starts after first deploy.
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
