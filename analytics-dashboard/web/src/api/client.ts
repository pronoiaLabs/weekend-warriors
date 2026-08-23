/** One fetch wrapper for the whole app. FastAPI puts the reason in `detail`;
    fall back to the status line. Undefined params are dropped so the API applies
    its own defaults (defaults belong to the API, not to TypeScript). */
export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

export type Param = string | number | boolean | undefined | string[]

export async function get<T>(path: string, params: Record<string, Param> = {}, signal?: AbortSignal): Promise<T> {
  const query = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) {
    if (Array.isArray(v)) for (const item of v) query.append(k, item)
    else if (v !== undefined && v !== '') query.set(k, String(v))
  }
  const qs = query.toString()
  const response = await fetch(qs ? `${path}?${qs}` : path, {
    headers: { accept: 'application/json' },
    signal,
  })
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { detail?: string } | null
    throw new ApiError(response.status, body?.detail ?? `${response.status} ${response.statusText}`)
  }
  return (await response.json()) as T
}
