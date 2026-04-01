import Nav from '@/components/nav'
import { getProjects, getActiveProject } from '@/actions/projects'

export default async function AuthenticatedLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const [projects, activeProject] = await Promise.all([
    getProjects(),
    getActiveProject(),
  ])

  return (
    <>
      <Nav projects={projects} activeProject={activeProject} />
      <main className="pt-14 md:pl-64 md:pt-0">
        <div className="mx-auto max-w-6xl px-6 py-8 sm:px-10 lg:px-12">
          {children}
        </div>
      </main>
    </>
  )
}
