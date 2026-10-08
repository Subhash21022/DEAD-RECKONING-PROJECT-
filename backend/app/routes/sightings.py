import uuid
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func as sa_func, cast, Float
from geoalchemy2.functions import ST_X, ST_Y, ST_DWithin, ST_MakePoint, ST_SetSRID
from geoalchemy2 import Geography

from ..database import get_db
from ..models import WildlifeSighting
from ..schemas import SightingCreate, SightingOut

router = APIRouter(prefix="/sightings", tags=["sightings"])


def _sighting_to_out(s: WildlifeSighting, lat: float, lon: float) -> SightingOut:
    return SightingOut(
        id=s.id,
        ranger_id=s.ranger_id,
        patrol_id=s.patrol_id,
        species=s.species,
        count=s.count,
        lat=lat,
        lon=lon,
        description=s.description,
        photo_url=s.photo_url,
        created_at=s.created_at,
    )


@router.post("", response_model=SightingOut, status_code=201)
async def log_sighting(
    body: SightingCreate,
    db: AsyncSession = Depends(get_db),
):
    sighting = WildlifeSighting(
        ranger_id=body.ranger_id,
        patrol_id=body.patrol_id,
        species=body.species,
        count=body.count,
        position=sa_func.ST_SetSRID(sa_func.ST_MakePoint(body.lon, body.lat), 4326),
        description=body.description,
        photo_url=body.photo_url,
    )
    db.add(sighting)
    await db.flush()
    await db.refresh(sighting)

    return SightingOut(
        id=sighting.id,
        ranger_id=sighting.ranger_id,
        patrol_id=sighting.patrol_id,
        species=sighting.species,
        count=sighting.count,
        lat=body.lat,
        lon=body.lon,
        description=sighting.description,
        photo_url=sighting.photo_url,
        created_at=sighting.created_at,
    )


@router.get("", response_model=List[SightingOut])
async def list_sightings(
    species: Optional[str] = Query(None),
    ranger_id: Optional[uuid.UUID] = Query(None),
    lat: Optional[float] = Query(None),
    lon: Optional[float] = Query(None),
    radius_m: float = Query(5000.0, ge=0),
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(
        WildlifeSighting,
        ST_Y(WildlifeSighting.position).label("lat"),
        ST_X(WildlifeSighting.position).label("lon"),
    ).order_by(WildlifeSighting.created_at.desc())

    if species is not None:
        stmt = stmt.where(WildlifeSighting.species == species)
    if ranger_id is not None:
        stmt = stmt.where(WildlifeSighting.ranger_id == ranger_id)
    if lat is not None and lon is not None:
        ref_point = sa_func.ST_SetSRID(sa_func.ST_MakePoint(lon, lat), 4326)
        stmt = stmt.where(
            sa_func.ST_DWithin(
                sa_func.cast(WildlifeSighting.position, Geography),
                sa_func.cast(ref_point, Geography),
                radius_m,
            )
        )

    stmt = stmt.offset(offset).limit(limit)
    result = await db.execute(stmt)
    rows = result.all()
    return [_sighting_to_out(r.WildlifeSighting, r.lat, r.lon) for r in rows]


@router.get("/heatmap")
async def sighting_heatmap(
    species: Optional[str] = Query(None),
    cell_size_deg: float = Query(0.005, ge=0.001, le=1.0),
    db: AsyncSession = Depends(get_db),
):
    lat_col = ST_Y(WildlifeSighting.position)
    lon_col = ST_X(WildlifeSighting.position)

    lat_cell = sa_func.floor(lat_col / cell_size_deg).label("lat_cell")
    lon_cell = sa_func.floor(lon_col / cell_size_deg).label("lon_cell")

    stmt = (
        select(
            lat_cell,
            lon_cell,
            sa_func.count().label("sighting_count"),
            sa_func.sum(WildlifeSighting.count).label("animal_count"),
        )
        .group_by(lat_cell, lon_cell)
        .order_by(sa_func.count().desc())
    )
    if species is not None:
        stmt = stmt.where(WildlifeSighting.species == species)

    result = await db.execute(stmt)
    rows = result.all()

    cells = []
    for r in rows:
        center_lat = (r.lat_cell + 0.5) * cell_size_deg
        center_lon = (r.lon_cell + 0.5) * cell_size_deg
        cells.append({
            "lat": round(center_lat, 6),
            "lon": round(center_lon, 6),
            "sighting_count": r.sighting_count,
            "animal_count": r.animal_count,
        })

    return {"cell_size_deg": cell_size_deg, "cells": cells}
