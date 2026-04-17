import Nav from '@/components/nav'
import KillSwitchHeader from '@/components/kill-switch-header'
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

  return (
    <>
      {/* Sidebar navigation — handles its own mobile header (branding + hamburger) */}
      <Nav
        projects={projects}
        activeProject={activeProject}
        consumerModeEnabled={consumerModeEnabled}
      />

      {/*
        Persistent kill switch pill — Spec 032 §5.
        Fixed top-right, z-[60] (above the nav's z-50 mobile header) so it is
        always visible on mobile AND desktop without needing to touch the nav
        client component. The pill is small enough not to overlap the branding.
        min-h/min-w ensures ≥ 44pt tap target on mobile.
      */}
      <div className="fixed right-3 top-2 z-[60]">
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
