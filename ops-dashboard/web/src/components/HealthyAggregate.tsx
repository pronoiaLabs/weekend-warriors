interface Props {
  count: number
}

/** Healthy pipelines never render a card; they collapse into this one tile, so
    card count reads as triage queue length rather than fleet size. */
export function HealthyAggregate({ count }: Props) {
  return (
    <div className="healthy-agg">
      <div className="big">{count} healthy</div>
      <div className="cap">no cards rendered · last runs all SUCCEEDED</div>
    </div>
  )
}
