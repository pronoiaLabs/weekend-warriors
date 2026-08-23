from fastapi import APIRouter

from app import config
from app.sports.payloads import CapabilitiesPayload
from app.sports.registry import Profile

router = APIRouter(tags=["sports"])


@router.get("/capabilities", response_model=CapabilitiesPayload)
def capabilities(profile: Profile) -> CapabilitiesPayload:
    """What this sport can show. The frontend builds its nav from this payload."""
    return profile.describe(as_of=config.now(), data=config.data_mode())
