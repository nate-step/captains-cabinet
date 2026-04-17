'use client'

/**
 * Thin client wrapper for the cabinets list page.
 *
 * Receives initialCabinets from the Server Component and passes them
 * to CabinetList. Provides router.refresh() as the onAction callback
 * so that after suspend/resume/archive the server data re-fetches.
 *
 * Separated from page.tsx to keep the server component pure.
 */

import { useRouter } from 'next/navigation'
import { useCallback, useTransition } from 'react'
import CabinetList from '@/components/cabinets/cabinet-list'
import type { CabinetRow } from '@/components/cabinets/cabinet-list'

interface CabinetListClientProps {
  initialCabinets: CabinetRow[]
}

export default function CabinetListClient({ initialCabinets }: CabinetListClientProps) {
  const router = useRouter()
  const [, startTransition] = useTransition()

  const handleAction = useCallback(() => {
    startTransition(() => {
      router.refresh()
    })
  }, [router])

  return <CabinetList cabinets={initialCabinets} onAction={handleAction} />
}
