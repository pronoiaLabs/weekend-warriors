import { get } from '../client.ts'
import type { CapabilitiesPayload, HealthPayload } from './types.ts'

export function fetchHealth(signal?: AbortSignal): Promise<HealthPayload> {
  return get<HealthPayload>('/api/health', {}, signal)
}

export function fetchCapabilities(sport: string, signal?: AbortSignal): Promise<CapabilitiesPayload> {
  return get<CapabilitiesPayload>(`/api/${encodeURIComponent(sport)}/capabilities`, {}, signal)
}
