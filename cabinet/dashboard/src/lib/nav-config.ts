import type { DashboardMode } from '@/hooks/use-dashboard-mode'

export type NavLink = {
  href: string
  label: string
  /** If true, renders as an external anchor with target=_blank. */
  external?: boolean
}

/**
 * Nav link set per dashboard mode (Spec 032).
 *
 * Consumer (4 items, mirrors the 4 content cards):
 *   Dashboard / Costs / Library / Settings
 *
 * Advanced (all 11 items, zero regression from the pre-Spec-032 nav):
 *   Dashboard / Project / Officers / Health / Settings / Governance
 *   / Integrations / Costs / Crons / Library / Terminal (external)
 *
 * Terminal-to-Advanced per CoS plan review 2026-04-17 — a raw-shell utility
 * doesn't fit the consumer "check in" intent.
 */

export const ADVANCED_NAV: NavLink[] = [
  { href: '/', label: 'Dashboard' },
  { href: '/project', label: 'Project' },
  { href: '/officers', label: 'Officers' },
  { href: '/health', label: 'Health' },
  { href: '/settings', label: 'Settings' },
  { href: '/governance', label: 'Governance' },
  { href: '/integrations', label: 'Integrations' },
  { href: '/costs', label: 'Costs' },
  { href: '/crons', label: 'Crons' },
  { href: '/library', label: 'Library' },
  { href: 'https://terminal.sensed.app', label: 'Terminal', external: true },
]

export const CONSUMER_NAV: NavLink[] = [
  { href: '/', label: 'Dashboard' },
  { href: '/costs', label: 'Costs' },
  { href: '/library', label: 'Library' },
  { href: '/settings', label: 'Settings' },
]

export function navForMode(mode: DashboardMode, consumerEnabled: boolean): NavLink[] {
  if (!consumerEnabled) return ADVANCED_NAV
  return mode === 'consumer' ? CONSUMER_NAV : ADVANCED_NAV
}
