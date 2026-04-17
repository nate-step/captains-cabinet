/**
 * Spec 034 PR 5 — Consolidated STATE_LABELS
 *
 * Single source of truth for cabinet state display configuration.
 * Previously duplicated in cabinet-list.tsx, cabinet-detail-client.tsx,
 * and the detail page.tsx. All UI files now import from here.
 *
 * Also exports STATE_LABEL_TEXT for the Telegram bot's plain-text labels.
 */

export interface StateLabelConfig {
  label: string
  dot: string
  text: string
}

export const STATE_LABELS: Record<string, StateLabelConfig> = {
  'creating':      { label: 'Creating',      dot: 'bg-amber-400',  text: 'text-amber-400'  },
  'adopting-bots': { label: 'Adopting bots', dot: 'bg-amber-400',  text: 'text-amber-400'  },
  'provisioning':  { label: 'Provisioning',  dot: 'bg-blue-400',   text: 'text-blue-400'   },
  'starting':      { label: 'Starting',      dot: 'bg-blue-400',   text: 'text-blue-400'   },
  'active':        { label: 'Active',        dot: 'bg-green-400',  text: 'text-green-400'  },
  'suspended':     { label: 'Suspended',     dot: 'bg-zinc-500',   text: 'text-zinc-400'   },
  'failed':        { label: 'Failed',        dot: 'bg-red-500',    text: 'text-red-400'    },
  'archiving':     { label: 'Archiving',     dot: 'bg-orange-400', text: 'text-orange-400' },
  'archived':      { label: 'Archived',      dot: 'bg-zinc-600',   text: 'text-zinc-500'   },
}

/** Plain-text labels used in Telegram bot status messages. */
export const STATE_LABEL_TEXT: Record<string, string> = {
  creating: 'Creating cabinet…',
  'adopting-bots': 'Waiting for bot tokens…',
  provisioning: 'Provisioning containers and migrating rows…',
  starting: 'Starting containers — waiting for first heartbeat…',
  active: 'Cabinet is live!',
  suspended: 'Cabinet suspended.',
  failed: 'Provisioning failed.',
  archiving: 'Archiving…',
  archived: 'Cabinet archived.',
}
