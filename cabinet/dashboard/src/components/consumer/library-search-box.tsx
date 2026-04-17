'use client'

/**
 * LibrarySearchBox — client component for Card 4 search.
 *
 * Debounced search against /api/library/search. Client-only, no server
 * roundtrip refinements for PR 2. Results shown inline beneath the input.
 */

import { useCallback, useRef, useState } from 'react'

interface SearchResult {
  space_id: string
  record_id: string
  title: string
  similarity: number
  preview: string
  created_by_officer: string | null
  created_at: string
}

export default function LibrarySearchBox() {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult[]>([])
  const [searching, setSearching] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const search = useCallback(async (q: string) => {
    if (!q.trim()) {
      setResults([])
      setError(null)
      return
    }

    setSearching(true)
    setError(null)
    try {
      const res = await fetch('/api/library/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: q, limit: 5 }),
      })
      if (!res.ok) throw new Error('Search failed')
      const data = (await res.json()) as { results: SearchResult[] }
      setResults(data.results ?? [])
    } catch {
      setError('Search unavailable')
      setResults([])
    } finally {
      setSearching(false)
    }
  }, [])

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const val = e.target.value
    setQuery(val)
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => {
      search(val)
    }, 300)
  }

  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-zinc-500">
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z" />
          </svg>
        </span>
        <input
          type="search"
          value={query}
          onChange={handleChange}
          placeholder="Search your cabinet..."
          className="w-full rounded-lg border border-zinc-700 bg-zinc-800 py-2.5 pl-9 pr-4 text-sm text-zinc-200 placeholder-zinc-500 outline-none transition-colors focus:border-zinc-500 focus:ring-1 focus:ring-zinc-500"
          aria-label="Search library"
        />
        {searching && (
          <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center">
            <svg className="h-3.5 w-3.5 animate-spin text-zinc-500" viewBox="0 0 24 24" fill="none">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
            </svg>
          </span>
        )}
      </div>

      {/* Results */}
      {error && (
        <p className="mt-2 text-xs text-zinc-500">{error}</p>
      )}
      {!error && query.trim() && results.length === 0 && !searching && (
        <p className="mt-2 text-xs text-zinc-500">No results found.</p>
      )}
      {results.length > 0 && (
        <ul className="mt-2 space-y-1">
          {results.map((r) => (
            <li key={r.record_id}>
              <a
                href={`/library/${r.space_id}/${r.record_id}`}
                className="block rounded-lg border border-zinc-800 bg-zinc-800/50 p-2.5 text-sm transition-colors hover:border-zinc-700 hover:bg-zinc-800"
              >
                <p className="font-medium text-zinc-200 truncate">{r.title}</p>
                {r.preview && (
                  <p className="mt-0.5 text-xs text-zinc-500 line-clamp-2">{r.preview}</p>
                )}
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
