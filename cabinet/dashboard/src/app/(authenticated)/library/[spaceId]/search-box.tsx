'use client'

import { useState } from 'react'
import Link from 'next/link'

interface SearchResult {
  record_id: string
  space_id: string
  title: string
  similarity: number
  preview: string
  created_by_officer: string | null
  created_at: string
}

interface Props {
  spaceId: string
}

export default function SearchBox({ spaceId }: Props) {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult[] | null>(null)
  const [searching, setSearching] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSearch(e: React.FormEvent) {
    e.preventDefault()
    if (!query.trim()) return
    setSearching(true)
    setError(null)

    try {
      const res = await fetch('/api/library/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: query.trim(), space_id: spaceId }),
      })
      if (!res.ok) {
        const data = (await res.json()) as { error?: string }
        throw new Error(data.error ?? 'Search failed')
      }
      const data = (await res.json()) as { results: SearchResult[] }
      setResults(data.results)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setSearching(false)
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <form onSubmit={handleSearch} className="flex gap-2">
        <input
          type="text"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            if (results !== null && e.target.value === '') setResults(null)
          }}
          placeholder="Search records semantically…"
          className="flex-1 rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none"
        />
        <button
          type="submit"
          disabled={searching || !query.trim()}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 transition-colors hover:bg-zinc-700 disabled:opacity-50"
        >
          {searching ? '…' : 'Search'}
        </button>
        {results !== null && (
          <button
            type="button"
            onClick={() => { setResults(null); setQuery('') }}
            className="rounded-lg border border-zinc-700 px-3 py-2 text-sm text-zinc-500 transition-colors hover:bg-zinc-800"
          >
            Clear
          </button>
        )}
      </form>

      {error && (
        <p className="rounded bg-red-950/30 px-3 py-2 text-xs text-red-400">{error}</p>
      )}

      {results !== null && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
          <div className="border-b border-zinc-800 px-4 py-2.5 text-xs text-zinc-500">
            {results.length === 0
              ? 'No matching records'
              : `${results.length} result${results.length === 1 ? '' : 's'}`}
          </div>
          {results.map((result) => (
            <Link
              key={result.record_id}
              href={`/library/${spaceId}/${result.record_id}`}
              className="flex items-start justify-between gap-4 border-b border-zinc-800 px-4 py-3 last:border-0 hover:bg-zinc-800/50 transition-colors"
            >
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium text-white truncate">{result.title}</p>
                {result.preview && (
                  <p className="mt-0.5 text-xs text-zinc-600 line-clamp-1">{result.preview}</p>
                )}
              </div>
              <span className="shrink-0 text-xs text-zinc-600">
                {(result.similarity * 100).toFixed(0)}% match
              </span>
            </Link>
          ))}
        </div>
      )}
    </div>
  )
}
