import Nav from '@/components/nav'
import KillSwitchHeader from '@/components/kill-switch-header'
import CommandPalette from '@/components/library/CommandPalette'
import { getProjects, getActiveProject } from '@/actions/projects'
import { getDashboardConfig } from '@/lib/config'
import redis from '@/lib/redis'

async function getKillSwitchState(): Promise<boolean> {
  const value = await redis.get('cabinet:killswitch')
  return value === 'active'
}

export default async function AuthenticatedLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const [projects, activeProject, killSwitchActive] = await Promise.all([
    getProjects(),
    getActiveProject(),
    getKillSwitchState(),
  ])
  const { consumerModeEnabled } = getDashboardConfig()

  // Spec 034: hide /cabinets nav link when provisioning flag is off
  const cabinetsEnabled =
    consumerModeEnabled || process.env.CABINETS_PROVISIONING_ENABLED === 'true'

  return (
    <>
      {/* Sidebar navigation — handles its own mobile header (branding + hamburger) */}
      <Nav
        projects={projects}
        activeProject={activeProject}
        consumerModeEnabled={consumerModeEnabled}
        cabinetsEnabled={cabinetsEnabled}
      />

      {/*
        Command Palette — Spec 037 A3.
        Global Cmd-K / Ctrl-K listener across all authenticated pages.
        Client island — no SSR, z-[70] above kill switch (z-60).
      */}
      <CommandPalette />

      {/*
        Persistent kill switch pill — Spec 032 §5.
        Fixed top-right on desktop, fixed top with a right offset on mobile so
        it sits LEFT of the nav's hamburger button (which lives at right-4 inside
        the z-50 mobile header). z-[60] is above the nav so the pill paints on top,
        but the pill background is bg-red-600/20 (20% opaque) — without the offset
        the hamburger shows through the translucent fill and looks like it
        overlaps the "Stop All" label.
        min-h/min-w ensures ≥ 44pt tap target on mobile.
      */}
      <div className="fixed right-14 top-2 z-[60] md:right-3">
        <KillSwitchHeader active={killSwitchActive} />
      </div>

      {/* Main content area */}
      <main className="pt-14 md:pl-64 md:pt-0">
        <div className="mx-auto max-w-6xl px-6 py-8 sm:px-10 lg:px-12">
          {children}
        </div>
      </main>
    </>
  )
}
