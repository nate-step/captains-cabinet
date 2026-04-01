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
            The officer has been created and is ready to start.
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
          <svg
            className="h-4 w-4"
            fill="none"
            viewBox="0 0 24 24"
            strokeWidth={2}
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M10.5 19.5L3 12m0 0l7.5-7.5M3 12h18"
            />
          </svg>
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-white">Create Officer</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Define a new officer role and Telegram bot
          </p>
        </div>
      </div>

      {/* Form */}
      <form
        action={formAction}
        className="max-w-lg space-y-6 rounded-xl border border-zinc-800 bg-zinc-900 p-6"
      >
        {state?.error && (
          <div className="rounded-lg border border-red-500/30 bg-red-900/20 px-4 py-3 text-sm text-red-500">
            {state.error}
          </div>
        )}

        <div>
          <label
            htmlFor="abbreviation"
            className="block text-sm font-medium text-zinc-400"
          >
            Abbreviation
          </label>
          <input
            id="abbreviation"
            name="abbreviation"
            type="text"
            required
            pattern="[a-z]{2,4}"
            maxLength={4}
            className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
            placeholder="e.g. cfo"
          />
          <p className="mt-1 text-xs text-zinc-600">
            2-4 lowercase letters (e.g. cos, cto, cro, cpo)
          </p>
        </div>

        <div>
          <label
            htmlFor="title"
            className="block text-sm font-medium text-zinc-400"
          >
            Title
          </label>
          <input
            id="title"
            name="title"
            type="text"
            required
            className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
            placeholder="e.g. Chief Financial Officer"
          />
        </div>

        <div>
          <label
            htmlFor="domain"
            className="block text-sm font-medium text-zinc-400"
          >
            Domain
          </label>
          <input
            id="domain"
            name="domain"
            type="text"
            required
            className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
            placeholder="e.g. finance, budgeting, cost optimization"
          />
          <p className="mt-1 text-xs text-zinc-600">
            Comma-separated list of domain responsibilities
          </p>
        </div>

        <div>
          <label
            htmlFor="botUsername"
            className="block text-sm font-medium text-zinc-400"
          >
            Telegram Bot Username
          </label>
          <input
            id="botUsername"
            name="botUsername"
            type="text"
            required
            className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
            placeholder="e.g. MyCabinetCFO_bot"
          />
        </div>

        <div>
          <label
            htmlFor="botToken"
            className="block text-sm font-medium text-zinc-400"
          >
            Telegram Bot Token
          </label>
          <input
            id="botToken"
            name="botToken"
            type="password"
            required
            className="mt-1.5 block w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-white placeholder-zinc-500 focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500"
            placeholder="From @BotFather"
          />
        </div>

        <div className="flex gap-3 pt-2">
          <button
            type="submit"
            disabled={isPending}
            className="rounded-lg bg-white px-4 py-2.5 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200 disabled:opacity-50"
          >
            {isPending ? 'Creating...' : 'Create Officer'}
          </button>
          <Link
            href="/officers"
            className="rounded-lg border border-zinc-700 px-4 py-2.5 text-sm font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
          >
            Cancel
          </Link>
        </div>
      </form>
    </div>
  )
}
