'use client'

import { useDashboardMode } from '@/hooks/use-dashboard-mode'
import SettingsConsumer from '@/components/consumer/settings-consumer'
import type { GlobalConfig } from '@/lib/config'

/**
 * Picks the Settings view based on dashboard mode.
 *
 * The Advanced view is passed as children from the server page.tsx so we
 * don't have to lift all the existing settings-forms imports up into a
 * client module. Consumer view is fully self-contained.
 *
 * When `consumerModeEnabled: false`, this component is never rendered —
 * page.tsx renders the Advanced children directly, matching PR 1's
 * "feature-flag-off is structurally inert" pattern.
 */
export default function SettingsModeSwitch({
  consumerProps,
  children,
}: {
  consumerProps: {
    config: GlobalConfig
    officerRoles: string[]
    timezone: string
  }
  children: React.ReactNode
}) {
  const [mode] = useDashboardMode()
  if (mode === 'consumer') {
    return <SettingsConsumer {...consumerProps} />
  }
  return <>{children}</>
}
