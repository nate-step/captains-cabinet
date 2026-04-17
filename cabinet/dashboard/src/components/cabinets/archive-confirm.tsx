'use client'

/**
 * Spec 034 PR 5 — ArchiveConfirm
 *
 * Three-step modal for cabinet archival (AC 15):
 *   Step 1 — Type the cabinet name exactly (friction layer 1)
 *   Step 2 — Enter dashboard password for re-auth (friction layer 2, COO 034.7)
 *   Step 3 — Click "Archive" — passes OTU token to API
 *
 * Re-auth flow:
 *  1. POST /api/auth/reauth-challenge → { challenge_token }
 *  2. Captain enters password
 *  3. POST /api/auth/reauth-verify { challenge_token, password } → { otu_token }
 *  4. POST /api/cabinets/:id/archive { confirm_name, otu_token }
 *
 * Passkey (WebAuthn): deferred to Phase 3. Password-only for v1.
 *
 * Spec refs: AC 15, COO 034.7 (re-auth required), §Management actions (archive).
 */

import { useState, useTransition, useEffect } from 'react'

interface ArchiveConfirmProps {
  cabinetName: string
  cabinetId: string
  onClose: () => void
  onSuccess: () => void
}

type Step = 'name' | 'password' | 'confirm'

export default function ArchiveConfirm({ cabinetName, cabinetId, onClose, onSuccess }: ArchiveConfirmProps) {
  const [step, setStep] = useState<Step>('name')
  const [typedName, setTypedName] = useState('')
  const [password, setPassword] = useState('')
  const [challengeToken, setChallengeToken] = useState<string | null>(null)
  const [otuToken, setOtuToken] = useState<string | null>(null)
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  const nameMatches = typedName === cabinetName

  // Fetch re-auth challenge token when we reach the password step
  useEffect(() => {
    if (step !== 'password' || challengeToken) return

    void (async () => {
      try {
        const res = await fetch('/api/auth/reauth-challenge', { method: 'POST' })
        if (!res.ok) {
          setError('Could not start re-authentication. Try again.')
          setStep('name')
          return
        }
        const body = (await res.json()) as { ok: boolean; challenge_token: string }
        if (!body.ok || !body.challenge_token) {
          setError('Re-auth challenge failed. Try again.')
          setStep('name')
          return
        }
        setChallengeToken(body.challenge_token)
      } catch {
        setError('Network error during re-auth setup.')
        setStep('name')
      }
    })()
  }, [step, challengeToken])

  function handleNameNext() {
    if (!nameMatches) return
    setError(null)
    setStep('password')
  }

  function handlePasswordVerify() {
    if (!password || !challengeToken) return
    setError(null)

    startTransition(async () => {
      try {
        const res = await fetch('/api/auth/reauth-verify', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ challenge_token: challengeToken, password }),
        })
        const body = (await res.json()) as { ok: boolean; otu_token?: string; message?: string }

        if (!res.ok || !body.ok || !body.otu_token) {
          setError(body.message || 'Incorrect password')
          return
        }

        setOtuToken(body.otu_token)
        setPassword('') // Clear password from memory
        setStep('confirm')
      } catch {
        setError('Network error during verification. Try again.')
      }
    })
  }

  function handleArchive() {
    if (!nameMatches || !otuToken) return
    setError(null)

    startTransition(async () => {
      try {
        const res = await fetch(`/api/cabinets/${cabinetId}/archive`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ confirm_name: typedName, otu_token: otuToken }),
        })
        const body = (await res.json()) as { ok: boolean; message?: string }

        if (!res.ok || !body.ok) {
          setError(body.message || 'Archive failed')
          // If OTU was consumed or invalid, restart from step 1
          if (res.status === 401) {
            setOtuToken(null)
            setChallengeToken(null)
            setStep('name')
          }
        } else {
          onSuccess()
        }
      } catch {
        setError('Network error. Try again.')
      }
    })
  }

  function handleBackdropClick(e: React.MouseEvent<HTMLDivElement>) {
    if (e.target === e.currentTarget && !isPending) onClose()
  }

  const stepLabels: Record<Step, string> = {
    name: 'Step 1 of 3: Confirm name',
    password: 'Step 2 of 3: Re-authenticate',
    confirm: 'Step 3 of 3: Archive',
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
      onClick={handleBackdropClick}
      role="dialog"
      aria-modal="true"
      aria-labelledby="archive-confirm-title"
    >
      <div className="w-full max-w-md rounded-xl border border-red-800/50 bg-zinc-900 p-6 shadow-xl">
        {/* Header */}
        <div className="flex items-center justify-between">
          <h2 id="archive-confirm-title" className="text-lg font-semibold text-white">
            Archive Cabinet
          </h2>
          <span className="text-xs text-zinc-600">{stepLabels[step]}</span>
        </div>

        <p className="mt-3 text-sm text-zinc-300">
          This will stop containers and remove{' '}
          <span className="font-mono font-medium text-white">{cabinetName}</span> from your active
          cabinets. Your data (experience records, audit events) is preserved under this
          cabinet&rsquo;s ID — nothing is deleted.
        </p>

        {/* Step 1: Name confirmation */}
        {step === 'name' && (
          <div className="mt-5">
            <label htmlFor="archive-name-input" className="block text-sm font-medium text-zinc-300">
              Type{' '}
              <span className="font-mono font-semibold text-white">{cabinetName}</span>{' '}
              to confirm:
            </label>
            <input
              id="archive-name-input"
              type="text"
              value={typedName}
              onChange={(e) => setTypedName(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && nameMatches) handleNameNext() }}
              autoFocus
              autoComplete="off"
              spellCheck={false}
              disabled={isPending}
              className="mt-2 w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2.5 text-sm text-white placeholder-zinc-600 focus:border-red-500 focus:outline-none focus:ring-1 focus:ring-red-500 disabled:opacity-50"
              placeholder={cabinetName}
            />
          </div>
        )}

        {/* Step 2: Password re-auth */}
        {step === 'password' && (
          <div className="mt-5">
            <label htmlFor="archive-password-input" className="block text-sm font-medium text-zinc-300">
              Enter your dashboard password to confirm:
            </label>
            <p className="mt-1 text-xs text-zinc-500">
              Re-authentication is required before archive. Passkey support is coming in Phase 3.
            </p>
            <input
              id="archive-password-input"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && password) handlePasswordVerify() }}
              autoFocus
              autoComplete="current-password"
              disabled={isPending || !challengeToken}
              className="mt-2 w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2.5 text-sm text-white placeholder-zinc-600 focus:border-red-500 focus:outline-none focus:ring-1 focus:ring-red-500 disabled:opacity-50"
              placeholder={!challengeToken ? 'Loading…' : 'Dashboard password'}
            />
          </div>
        )}

        {/* Step 3: Final confirmation */}
        {step === 'confirm' && (
          <div className="mt-5 rounded-lg border border-red-800/50 bg-red-900/10 px-4 py-3">
            <p className="text-sm text-red-300 font-medium">Ready to archive</p>
            <p className="mt-1 text-xs text-zinc-400">
              Name confirmed. Re-authentication passed. Click &ldquo;Archive Cabinet&rdquo; to proceed.
              This action stops containers and removes peers.yml entries — data is preserved.
            </p>
          </div>
        )}

        {/* Error */}
        {error && (
          <p className="mt-3 text-sm text-red-400">{error}</p>
        )}

        {/* Actions */}
        <div className="mt-5 flex gap-3 justify-end">
          <button
            type="button"
            onClick={onClose}
            disabled={isPending}
            className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-50 min-h-[44px]"
          >
            Cancel
          </button>

          {step === 'name' && (
            <button
              type="button"
              onClick={handleNameNext}
              disabled={!nameMatches || isPending}
              className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed min-h-[44px]"
            >
              Next
            </button>
          )}

          {step === 'password' && (
            <button
              type="button"
              onClick={handlePasswordVerify}
              disabled={!password || !challengeToken || isPending}
              className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed min-h-[44px]"
            >
              {isPending ? 'Verifying…' : 'Verify'}
            </button>
          )}

          {step === 'confirm' && (
            <button
              type="button"
              onClick={handleArchive}
              disabled={!otuToken || isPending}
              className="rounded-lg border border-red-700 bg-red-900/50 px-4 py-2 text-sm font-medium text-red-300 hover:bg-red-800/50 hover:text-red-200 transition-colors disabled:opacity-40 disabled:cursor-not-allowed min-h-[44px]"
            >
              {isPending ? 'Archiving…' : 'Archive Cabinet'}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
