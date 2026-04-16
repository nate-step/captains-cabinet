'use client'

// ============================================================
// SchemaFields — renders typed form controls for a Space's
// schema_json.fields array, replacing the raw JSON textarea.
//
// Relation fields show a plain text input for now — autocomplete
// (record picker with cross-Space search) is deferred to Sprint C.
// ============================================================

export interface SchemaField {
  name: string
  type:
    | 'text'
    | 'markdown'
    | 'number'
    | 'date'
    | 'datetime'
    | 'select'
    | 'multi_select'
    | 'boolean'
    | 'relation'
    | string // allow unknown future types gracefully
  options?: string[]
  default?: unknown
  description?: string
}

export interface SchemaJson {
  fields?: SchemaField[]
  [key: string]: unknown
}

interface Props {
  schemaJson: SchemaJson
  schemaData: Record<string, unknown>
  onChange: (updated: Record<string, unknown>) => void
  disabled?: boolean
}

// Helper: safely read a string value from schemaData with fallback to field.default
function strVal(
  schemaData: Record<string, unknown>,
  field: SchemaField
): string {
  const raw = schemaData[field.name]
  if (raw !== undefined && raw !== null) return String(raw)
  if (field.default !== undefined && field.default !== null)
    return String(field.default)
  return ''
}

// Helper: read array value for multi_select
function arrVal(
  schemaData: Record<string, unknown>,
  field: SchemaField
): string[] {
  const raw = schemaData[field.name]
  if (Array.isArray(raw)) return raw.map(String)
  if (field.default !== undefined && Array.isArray(field.default))
    return (field.default as unknown[]).map(String)
  return []
}

// Helper: read boolean value
function boolVal(
  schemaData: Record<string, unknown>,
  field: SchemaField
): boolean {
  const raw = schemaData[field.name]
  if (raw !== undefined && raw !== null) return Boolean(raw)
  if (field.default !== undefined) return Boolean(field.default)
  return false
}

// Shared input class
const inputCls =
  'w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-50'

const selectCls =
  'w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white focus:border-zinc-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-50'

export default function SchemaFields({
  schemaJson,
  schemaData,
  onChange,
  disabled = false,
}: Props) {
  const fields = schemaJson.fields ?? []

  if (fields.length === 0) return null

  function set(name: string, value: unknown) {
    onChange({ ...schemaData, [name]: value })
  }

  return (
    <div className="flex flex-col gap-4">
      {fields.map((field) => {
        const labelId = `schema-field-${field.name}`
        return (
          <div key={field.name}>
            <label
              htmlFor={labelId}
              className="mb-1.5 block text-xs font-medium text-zinc-400 capitalize"
            >
              {field.name.replace(/_/g, ' ')}
            </label>

            {/* ── text ──────────────────────────────────────── */}
            {(field.type === 'text' || field.type === 'relation') && (
              <>
                <input
                  id={labelId}
                  type="text"
                  value={strVal(schemaData, field)}
                  onChange={(e) => set(field.name, e.target.value)}
                  disabled={disabled}
                  className={inputCls}
                  // Relation: autocomplete (record picker) deferred to Sprint C
                  placeholder={field.type === 'relation' ? 'record ID or identifier…' : undefined}
                />
                {field.type === 'relation' && (
                  <p className="mt-1 text-[10px] text-zinc-700">
                    Cross-Space record picker coming in Sprint C — enter ID manually for now.
                  </p>
                )}
              </>
            )}

            {/* ── markdown ──────────────────────────────────── */}
            {field.type === 'markdown' && (
              <textarea
                id={labelId}
                value={strVal(schemaData, field)}
                onChange={(e) => set(field.name, e.target.value)}
                disabled={disabled}
                rows={4}
                className={`${inputCls} font-mono resize-y`}
                placeholder="Markdown…"
              />
            )}

            {/* ── number ────────────────────────────────────── */}
            {field.type === 'number' && (
              <input
                id={labelId}
                type="number"
                value={strVal(schemaData, field)}
                onChange={(e) =>
                  set(field.name, e.target.value === '' ? '' : Number(e.target.value))
                }
                disabled={disabled}
                className={inputCls}
              />
            )}

            {/* ── date ──────────────────────────────────────── */}
            {field.type === 'date' && (
              <input
                id={labelId}
                type="date"
                value={strVal(schemaData, field)}
                onChange={(e) => set(field.name, e.target.value || null)}
                disabled={disabled}
                className={inputCls}
              />
            )}

            {/* ── datetime ──────────────────────────────────── */}
            {field.type === 'datetime' && (
              <input
                id={labelId}
                type="datetime-local"
                value={strVal(schemaData, field)}
                onChange={(e) => set(field.name, e.target.value || null)}
                disabled={disabled}
                className={inputCls}
              />
            )}

            {/* ── select ────────────────────────────────────── */}
            {field.type === 'select' && (
              <select
                id={labelId}
                value={strVal(schemaData, field)}
                onChange={(e) => set(field.name, e.target.value)}
                disabled={disabled}
                className={selectCls}
              >
                <option value="">— select —</option>
                {(field.options ?? []).map((opt) => (
                  <option key={opt} value={opt}>
                    {opt}
                  </option>
                ))}
              </select>
            )}

            {/* ── multi_select ──────────────────────────────── */}
            {field.type === 'multi_select' && (
              <div className="flex flex-wrap gap-x-4 gap-y-2 rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2.5">
                {(field.options ?? []).map((opt) => {
                  const checked = arrVal(schemaData, field).includes(opt)
                  return (
                    <label
                      key={opt}
                      className="flex cursor-pointer items-center gap-1.5 text-sm text-zinc-300"
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        disabled={disabled}
                        onChange={() => {
                          const current = arrVal(schemaData, field)
                          const next = checked
                            ? current.filter((v) => v !== opt)
                            : [...current, opt]
                          set(field.name, next)
                        }}
                        className="accent-white disabled:cursor-not-allowed"
                      />
                      {opt}
                    </label>
                  )
                })}
              </div>
            )}

            {/* ── boolean ───────────────────────────────────── */}
            {field.type === 'boolean' && (
              <div className="flex items-center gap-2 pt-0.5">
                <input
                  id={labelId}
                  type="checkbox"
                  checked={boolVal(schemaData, field)}
                  onChange={(e) => set(field.name, e.target.checked)}
                  disabled={disabled}
                  className="h-4 w-4 accent-white disabled:cursor-not-allowed"
                />
                <span className="text-sm text-zinc-400">
                  {boolVal(schemaData, field) ? 'Yes' : 'No'}
                </span>
              </div>
            )}

            {/* ── unknown type fallback ─────────────────────── */}
            {!['text', 'markdown', 'number', 'date', 'datetime', 'select', 'multi_select', 'boolean', 'relation'].includes(
              field.type
            ) && (
              <input
                id={labelId}
                type="text"
                value={strVal(schemaData, field)}
                onChange={(e) => set(field.name, e.target.value)}
                disabled={disabled}
                className={inputCls}
                placeholder={`(${field.type})`}
              />
            )}

            {/* Help text */}
            {field.description && (
              <p className="mt-1 text-xs text-zinc-600">{field.description}</p>
            )}
          </div>
        )
      })}
    </div>
  )
}
