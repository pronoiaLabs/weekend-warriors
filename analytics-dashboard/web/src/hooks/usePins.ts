import { useCallback, useState } from 'react'

/** A pinned play: enough to list it on the rail and link back to its game. */
export interface Pin {
  key: string
  game_key: string
  player_name: string
  team_label: string
  prop_label: string
  line_value: number | null
  vendor: string
}

const storageKey = (sport: string) => `ww.analytics.pins.${sport}`

function read(sport: string): Pin[] {
  try {
    const raw = localStorage.getItem(storageKey(sport))
    return raw ? (JSON.parse(raw) as Pin[]) : []
  } catch {
    return []
  }
}

function write(sport: string, pins: Pin[]): void {
  try {
    localStorage.setItem(storageKey(sport), JSON.stringify(pins))
  } catch {
    // private mode or a blocked store: pins live for the session only
  }
}

/** Pins live in localStorage per sport, so a board built on the game page is
    still there after a reload and across games in the same week. Nothing is
    sent to the API. */
export function usePins(sport: string) {
  const [pins, setPins] = useState<Pin[]>(() => read(sport))

  const toggle = useCallback(
    (pin: Pin) => {
      setPins((current) => {
        const next = current.some((p) => p.key === pin.key)
          ? current.filter((p) => p.key !== pin.key)
          : [...current, pin]
        write(sport, next)
        return next
      })
    },
    [sport],
  )

  const remove = useCallback(
    (key: string) => {
      setPins((current) => {
        const next = current.filter((p) => p.key !== key)
        write(sport, next)
        return next
      })
    },
    [sport],
  )

  const has = useCallback((key: string) => pins.some((p) => p.key === key), [pins])

  return { pins, toggle, remove, has }
}
