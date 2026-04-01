'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createOfficer } from '@/actions/officers'

export default function CreateOfficerPage() {
  const [state, formAction, isPending] = useActionState(createOfficer, null)

  if (state?.success) {
    return (
      <div className="space-y-6">
        <div className="rounded-xl border border-green-500/30 bg-green-900/20 p-8 text-center">
          <svg
            className="mx-auto h-12 w-12 text-green-500"
            fill="none"
            viewBox="0 0 24 24"
            strokeWidth={1.5}
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <h2 className="mt-4 text-lg font-bold text-white">
            Officer Created
          </h2>
          <p className="mt-2 text-sm text-zinc-400">
            The officer is booting and will announce on the warroom shortly.
          </p>
          <Link
            href="/officers"
            className="mt-4 inline-flex items-center rounded-lg bg-white px-4 py-2 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200"
          >
            Back to Officers
          </Link>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex items-center gap-4">
        <Link
          href="/officers"
          className="rounded-lg border border-zinc-700 p-2 text-zinc-400 transition-colors hover:bg-zinc-800 hover:text-white"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M10.5 19.5L3 12m0 0l7.5-7.5M3 12h18" />
          </svg>
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-white">Create Officer</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Define a new officer role, Telegram bot, and voice personality
          </p>
        </div>
      </div>

      {/* Form */}
      <form action={formAction} className="max-w-2xl space-y-8">
        {state?.error && (
          <div className="rounded-lg border border-red-500/30 bg-red-900/20 px-4 py-3 text-sm text-red-500">
            {state.error}
          </div>
        )}

        {/* Identity */}
        <div className="space-y-4 rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-6">
          <h3 className="text-sm font-semibold text-white">Identity</h3>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="abbreviation" className="block text-sm font-medium text-zinc-400">
                Abbreviation
              </label>
              <input id="abbreviation" name="abbreviation" type="text" required pattern="[a-z]{2,4}" maxLength={4}
                className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
                placeholder="e.g. cfo" />
              <p className="mt-1 text-xs text-zinc-600">2-4 lowercase letters</p>
            </div>

            <div>
              <label htmlFor="title" className="block text-sm font-medium text-zinc-400">
                Title
              </label>
              <input id="title" name="title" type="text" required
                className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
                placeholder="e.g. Chief Financial Officer" />
            </div>
          </div>

          <div>
            <label htmlFor="domain" className="block text-sm font-medium text-zinc-400">
              Domain
            </label>
            <input id="domain" name="domain" type="text" required
              className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
              placeholder="e.g. finance, budgeting, cost optimization" />
            <p className="mt-1 text-xs text-zinc-600">What this officer owns</p>
          </div>

          <div>
            <label htmlFor="interfaceName" className="block text-sm font-medium text-zinc-400">
              Shared Interface
            </label>
            <input id="interfaceName" name="interfaceName" type="text"
              className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
              placeholder="e.g. financial-reports (optional)" />
            <p className="mt-1 text-xs text-zinc-600">Creates shared/interfaces/&lt;name&gt;.md for cross-officer output</p>
          </div>
        </div>

        {/* Telegram */}
        <div className="space-y-4 rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-6">
          <h3 className="text-sm font-semibold text-white">Telegram</h3>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="botUsername" className="block text-sm font-medium text-zinc-400">
                Bot Username
              </label>
              <input id="botUsername" name="botUsername" type="text" required
                className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
                placeholder="e.g. MyCabinetCFO_bot" />
            </div>

            <div>
              <label htmlFor="botToken" className="block text-sm font-medium text-zinc-400">
                Bot Token
              </label>
              <input id="botToken" name="botToken" type="password" required
                className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
                placeholder="From @BotFather" />
            </div>
          </div>
        </div>

        {/* Voice */}
        <div className="space-y-4 rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-6">
          <h3 className="text-sm font-semibold text-white">Voice</h3>

          <div>
            <label htmlFor="voiceId" className="block text-sm font-medium text-zinc-400">
              ElevenLabs Voice ID
            </label>
            <input id="voiceId" name="voiceId" type="text"
              className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
              placeholder="e.g. NOpBlnGInO9m6vDvFkFC (optional — voice disabled if empty)" />
            <p className="mt-1 text-xs text-zinc-600">
              Browse voices at{' '}
              <a href="https://elevenlabs.io/voice-library" target="_blank" rel="noopener" className="text-zinc-400 underline">
                elevenlabs.io/voice-library
              </a>
            </p>
          </div>

          <div>
            <label htmlFor="voicePrompt" className="block text-sm font-medium text-zinc-400">
              Voice Personality
            </label>
            <textarea id="voicePrompt" name="voicePrompt" rows={3}
              className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
              placeholder="e.g. You are a friendly grandpa who tells tall tales. Use [chuckles] and [sighs] for warmth..." />
            <p className="mt-1 text-xs text-zinc-600">
              How should this officer sound? Include ElevenLabs v3 audio tags like [laughs], [sighs], [excited]
            </p>
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="voiceStability" className="block text-sm font-medium text-zinc-400">
                Stability
              </label>
              <input id="voiceStability" name="voiceStability" type="number" step="0.1" min="0" max="1" defaultValue="0.5"
                className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500" />
              <p className="mt-1 text-xs text-zinc-600">0 = creative, 1 = consistent</p>
            </div>

            <div>
              <label htmlFor="voiceSpeed" className="block text-sm font-medium text-zinc-400">
                Speed
              </label>
              <input id="voiceSpeed" name="voiceSpeed" type="number" step="0.05" min="0.7" max="1.2" defaultValue="1.0"
                className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500" />
              <p className="mt-1 text-xs text-zinc-600">0.7 = slow, 1.2 = fast</p>
            </div>
          </div>
        </div>

        <div className="flex gap-3">
          <button type="submit" disabled={isPending}
            className="rounded-lg bg-white px-6 py-2.5 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200 disabled:opacity-50">
            {isPending ? 'Creating...' : 'Create Officer'}
          </button>
          <Link href="/officers"
            className="rounded-lg border border-zinc-700 px-4 py-2.5 text-sm font-medium text-zinc-400 transition-colors hover:bg-zinc-800">
            Cancel
          </Link>
        </div>
      </form>
    </div>
  )
}
