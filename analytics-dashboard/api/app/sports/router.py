"""Every sport route hangs off /api/{sport}. Page routers are included here as
they land; each resolves its profile through a dependency and never imports a
sport by name."""

from fastapi import APIRouter

from app.sports.routers import capabilities

router = APIRouter(prefix="/api/{sport}")
router.include_router(capabilities.router)
