from typing import Any

from fastapi import APIRouter

from app import datasource
from app.routers.common import traced

router = APIRouter(tags=["sports"])


@router.get("/api/sports")
def sports() -> dict[str, Any]:
    pipes = datasource.pipelines()
    return traced(
        {
            "sports": [
                {"sport": s, "pipelines": sum(1 for p in pipes if p["sport"] == s)}
                for s in sorted({p["sport"] for p in pipes})
            ]
        }
    )
