/** Two blurred, slowly drifting layers behind everything. Pure CSS motion; the
    stylesheet stops it under prefers-reduced-motion. */
export default function Aurora() {
  return (
    <>
      <div className="aurora" aria-hidden="true">
        <i />
        <i />
        <i />
      </div>
      <div className="aurora two" aria-hidden="true">
        <i />
        <i />
        <i />
      </div>
    </>
  )
}
