import type { MouseEvent } from 'react'

interface Props {
  open: boolean
  onToggle: () => void
  label: string
}

export function Expander({ open, onToggle, label }: Props) {
  function handleClick(event: MouseEvent<HTMLButtonElement>) {
    // The panel header is itself clickable; a nested button must not fire twice.
    event.stopPropagation()
    onToggle()
  }

  return (
    <button
      type="button"
      className={open ? 'expander open' : 'expander'}
      aria-expanded={open}
      aria-label={label}
      title={label}
      onClick={handleClick}
    >
      <span className="caret">{'▶'}</span>
    </button>
  )
}
