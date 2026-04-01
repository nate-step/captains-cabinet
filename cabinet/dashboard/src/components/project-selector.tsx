'use client'

import { useState, useRef, useEffect, useTransition } from 'react'
import { switchProject } from '@/actions/projects'

interface ProjectInfo {
  slug: string
  name: string
  active: boolean
}

export default function ProjectSelector({
  projects,
  activeProject,
}: {
  projects: ProjectInfo[]
  activeProject: string
}) {
  const [open, setOpen] = useState(false)
  const [confirming, setConfirming] = useState<string | null>(null)
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)
  const dropdownRef = useRef<HTMLDivElement>(null)

  const active = projects.find((p) => p.active) || projects.find((p) => p.slug === activeProject)
  const activeName = active?.name || activeProject

  // Close dropdown on outside click
  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setOpen(false)
        setConfirming(null)
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  function handleSelect(slug: string) {
    if (slug === activeProject || (active && slug === active.slug)) {
      setOpen(false)
      return
    }
    setConfirming(slug)
  }

  function handleConfirm() {
    if (!confirming) return
    setError(null)
    startTransition(async () => {
      const result = await switchProject(confirming)
      if (result.success) {
        setConfirming(null)
        setOpen(false)
        // Force page refresh to reload all data
        window.location.reload()
      } else {
        setError(result.error || 'Failed to switch project')
      }
    })
  }

  function handleCancel() {
    setConfirming(null)
    setError(null)
  }

  const confirmingProject = projects.find((p) => p.slug === confirming)

  return (
    <div ref={dropdownRef} className="relative" style={{ padding: '12px 12px 0 12px' }}>
      {/* Trigger button */}
      <button
        onClick={() => {
          setOpen(!open)
          setConfirming(null)
          setError(null)
        }}
        disabled={isPending}
        className="flex w-full items-center gap-2 rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-left text-sm transition-colors hover:border-zinc-600 hover:bg-zinc-750 disabled:opacity-50"
      >
        {/* Green dot */}
        <span
          className="inline-block h-2 w-2 flex-shrink-0 rounded-full bg-emerald-500"
          style={{ boxShadow: '0 0 4px rgba(16, 185, 129, 0.4)' }}
        />
        <span className="flex-1 truncate font-medium text-white">
          {isPending ? 'Switching...' : activeName}
        </span>
        {/* Chevron */}
        <svg
          className={`h-4 w-4 flex-shrink-0 text-zinc-500 transition-transform ${open ? 'rotate-180' : ''}`}
          fill="none"
          viewBox="0 0 24 24"
          strokeWidth={2}
          stroke="currentColor"
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
        </svg>
      </button>

      {/* Dropdown */}
      {open && (
        <div
          className="absolute left-3 right-3 z-50 mt-1 overflow-hidden rounded-lg border border-zinc-700 bg-zinc-800 shadow-xl"
        >
          {/* Confirmation dialog */}
          {confirming && confirmingProject ? (
            <div style={{ padding: '12px' }}>
              <p className="text-sm text-zinc-300">
                Switch to <span className="font-medium text-white">{confirmingProject.name}</span>?
              </p>
              <p className="mt-1 text-xs text-zinc-500">
                This will restart all officers.
              </p>
              {error && (
                <p className="mt-2 text-xs text-red-400">{error}</p>
              )}
              <div className="mt-3 flex gap-2">
                <button
                  onClick={handleConfirm}
                  disabled={isPending}
                  className="flex-1 rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-emerald-500 disabled:opacity-50"
                >
                  {isPending ? 'Switching...' : 'Confirm'}
                </button>
                <button
                  onClick={handleCancel}
                  disabled={isPending}
                  className="flex-1 rounded-md border border-zinc-600 px-3 py-1.5 text-xs font-medium text-zinc-300 transition-colors hover:bg-zinc-700 disabled:opacity-50"
                >
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            /* Project list */
            <div style={{ padding: '4px 0' }}>
              {projects.map((project) => {
                const isActive = project.active || project.slug === activeProject
                return (
                  <button
                    key={project.slug}
                    onClick={() => handleSelect(project.slug)}
                    className={`flex w-full items-center gap-2 px-3 py-2 text-left text-sm transition-colors ${
                      isActive
                        ? 'bg-zinc-700/50 text-white'
                        : 'text-zinc-400 hover:bg-zinc-700/30 hover:text-zinc-200'
                    }`}
                  >
                    {/* Status dot */}
                    <span
                      className={`inline-block h-2 w-2 flex-shrink-0 rounded-full ${
                        isActive ? 'bg-emerald-500' : 'bg-zinc-600'
                      }`}
                    />
                    <span className={`flex-1 truncate ${isActive ? 'font-medium' : ''}`}>
                      {project.name}
                    </span>
                    {isActive && (
                      <span className="text-xs text-zinc-500">active</span>
                    )}
                  </button>
                )
              })}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
