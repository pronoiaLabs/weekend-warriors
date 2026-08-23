import { Link } from 'react-router-dom'
import { useSportParam } from '../../hooks/useSportParam.ts'

/** Stands in for a page whose phase has not landed. Deleted as each page ships. */
export default function Placeholder({ title, phase }: { title: string; phase: string }) {
  const sport = useSportParam()
  return (
    <div className="page">
      <div className="page-head">
        <h1>{title}</h1>
        <p className="lede">
          {phase ? `Arrives in ${phase}.` : 'No such page.'} Back to <Link to={`/${sport}`}>home</Link>.
        </p>
      </div>
    </div>
  )
}
