import uuid
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func as sa_func
from geoalchemy2.functions import ST_Contains, ST_MakePoint, ST_SetSRID

from ..database import get_db
from ..models import GeoFence, ZoneType
from ..schemas import GeoFenceCreate, GeoFenceOut, GeoFenceCheckRequest, GeoFenceCheckResponse

router = APIRouter(prefix="/geofences", tags=["geofences"])


def _build_polygon_wkt(coords: List[List[float]]) -> str:
    ring = coords if coords[0] == coords[-1] else coords + [coords[0]]
    pairs = ", ".join(f"{c[0]} {c[1]}" for c in ring)
    return f"SRID=4326;POLYGON(({pairs}))"


@router.post("", response_model=GeoFenceOut, status_code=201)
async def create_geofence(
    body: GeoFenceCreate,
    db: AsyncSession = Depends(get_db),
):
    if len(body.polygon_coords) < 3:
        raise HTTPException(status_code=422, detail="Polygon requires at least 3 coordinate pairs")

    wkt = _build_polygon_wkt(body.polygon_coords)
    fence = GeoFence(
        name=body.name,
        zone_type=ZoneType(body.zone_type),
        boundary=wkt,
        is_active=True,
    )
    db.add(fence)
    await db.flush()
    await db.refresh(fence)
    return GeoFenceOut.model_validate(fence)


@router.get("", response_model=List[GeoFenceOut])
async def list_geofences(
    active_only: bool = Query(True),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(GeoFence).order_by(GeoFence.created_at.desc())
    if active_only:
        stmt = stmt.where(GeoFence.is_active == True)
    result = await db.execute(stmt)
    fences = result.scalars().all()
    return [GeoFenceOut.model_validate(f) for f in fences]


@router.get("/{fence_id}", response_model=GeoFenceOut)
async def get_geofence(
    fence_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    fence = await db.get(GeoFence, fence_id)
    if fence is None:
        raise HTTPException(status_code=404, detail="GeoFence not found")
    return GeoFenceOut.model_validate(fence)


@router.delete("/{fence_id}", status_code=204)
async def delete_geofence(
    fence_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    fence = await db.get(GeoFence, fence_id)
    if fence is None:
        raise HTTPException(status_code=404, detail="GeoFence not found")
    fence.is_active = False
    await db.flush()


@router.post("/check", response_model=GeoFenceCheckResponse)
async def check_geofence(
    body: GeoFenceCheckRequest,
    db: AsyncSession = Depends(get_db),
):
    point = sa_func.ST_SetSRID(sa_func.ST_MakePoint(body.lon, body.lat), 4326)

    stmt = select(GeoFence).where(
        GeoFence.is_active == True,
        sa_func.ST_Contains(GeoFence.boundary, point),
    )
    result = await db.execute(stmt)
    matching = result.scalars().all()

    return GeoFenceCheckResponse(
        inside=len(matching) > 0,
        zones=[GeoFenceOut.model_validate(f) for f in matching],
    )
