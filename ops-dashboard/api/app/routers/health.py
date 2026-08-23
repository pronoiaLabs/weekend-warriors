from fastapi import APIRouter

from app import config

router = APIRouter(tags=["health"])


@router.get("/api/health")
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "service": "ops-dashboard",
        "data": config.data_mode(),
        "backend": config.backend(),
        "role": config.role() or "connection default",
    }
