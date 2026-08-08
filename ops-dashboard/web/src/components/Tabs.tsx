import { useState } from 'react'
import type { ReactNode } from 'react'

export interface TabSpec {
  id: string
  label: ReactNode
  render: () => ReactNode
}

interface Props {
  tabs: TabSpec[]
  /** Which tab opens first. A failed run leads with Error, a healthy one with
      Logs, so the default is per instance rather than always the first tab. */
  defaultTab?: string
  /** Distinguishes the many instances a run history renders, so their panel ids
      and aria-controls stay unique on the page. */
  scope: string
}

export function Tabs({ tabs, defaultTab, scope }: Props) {
  const first = defaultTab && tabs.some((tab) => tab.id === defaultTab) ? defaultTab : tabs[0]?.id
  const [active, setActive] = useState(first)
  // Panels stay mounted once opened and are hidden rather than unmounted, so a
  // tab that fetched its own data does not refetch on every switch.
  const [opened, setOpened] = useState<string[]>(first ? [first] : [])

  function select(id: string) {
    setActive(id)
    setOpened((current) => (current.includes(id) ? current : [...current, id]))
  }

  return (
    <div className="tabset">
      <div className="tabs" role="tablist">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            id={`${scope}-tab-${tab.id}`}
            aria-selected={tab.id === active}
            aria-controls={`${scope}-panel-${tab.id}`}
            className={tab.id === active ? 'tab on' : 'tab'}
            onClick={() => select(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>
      {tabs
        .filter((tab) => opened.includes(tab.id))
        .map((tab) => (
          <div
            key={tab.id}
            role="tabpanel"
            id={`${scope}-panel-${tab.id}`}
            aria-labelledby={`${scope}-tab-${tab.id}`}
            className="tabpane"
            hidden={tab.id !== active}
          >
            {tab.render()}
          </div>
        ))}
    </div>
  )
}
