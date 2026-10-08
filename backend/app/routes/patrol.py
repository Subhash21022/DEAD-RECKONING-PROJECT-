import uuid
import math
from datetime import datetime, timezone
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func as sa_func, and_
from geoalchemy2.functions import ST_X, ST_Y

from ..database import get_db
from ..models import Patrol, Breadcrumb, PatrolStatus
from ..schemas import PatrolCreate, PatrolOut, PatrolSummary, BreadcrumbOut

router = APIRouter(prefix="/patrols", tags=["patrols"])

R_EARTH = 6378137.0
CELL_SIZE_M = 50.0


def _haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2.0 * R_EARTH * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


@router.post("", response_model=PatrolOut, status_code=201)
async def start_patrol(
    body: PatrolCreate,
    db: AsyncSession = Depends(get_db),
):
    patrol = Patrol(
        ranger_id=body.ranger_id,
        status=PatrolStatus.ACTIVE,
    )
    db.add(patrol)
    await db.flush()
    await db.refresh(patrol)
    return PatrolOut.model_validate(patrol)


@router.patch("/{patrol_id}/end", response_model=PatrolSummary)
async def end_patrol(
    patrol_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    patrol = await db.get(Patrol, patrol_id)
    if patrol is None:
        raise HTTPException(status_code=404, detail="Patrol not found")
    if patrol.status != PatrolStatus.ACTIVE:
        raise HTTPException(status_code=400, detail="Patrol is not active")

    patrol.end_time = datetime.now(timezone.utc)
    patrol.status = PatrolStatus.COMPLETED

    rows = await db.execute(
        select(
            ST_Y(Breadcrumb.position).label("lat"),
            ST_X(Breadcrumb.position).label("lon"),
        )
        .where(Breadcrumb.patrol_id == patrol_id)
        .order_by(Breadcrumb.timestamp_s)
    )
    points = rows.all()

    total_dist = 0.0
    visited_cells: set = set()
    for i, pt in enumerate(points):
        lat_m = math.radians(pt.lat) * R_EARTH
        lon_m = math.radians(pt.lon) * R_EARTH * math.cos(math.radians(pt.lat))
        visited_cells.add((int(lon_m // CELL_SIZE_M), int(lat_m // CELL_SIZE_M)))
        if i > 0:
            total_dist += _haversine(points[i - 1].lat, points[i - 1].lon, pt.lat, pt.lon)

    patrol.total_distance_m = total_dist
    patrol.coverage_km2 = len(visited_cells) * (CELL_SIZE_M ** 2) / 1e6
    patrol.breadcrumb_count = len(points)
    await db.flush()

    duration_min = None
    avg_speed = None
    if patrol.end_time and patrol.start_time:
        dur_s = (patrol.end_time - patrol.start_time).total_seconds()
        duration_min = dur_s / 60.0
        if dur_s > 0:
            avg_speed = (total_dist / dur_s) * 3.6

    return PatrolSummary(
        id=patrol.id,
        ranger_id=patrol.ranger_id,
        start_time=patrol.start_time,
        end_time=patrol.end_time,
        status=patrol.status.value,
        total_distance_m=patrol.total_distance_m,
        coverage_km2=patrol.coverage_km2,
        breadcrumb_count=patrol.breadcrumb_count,
        duration_minutes=duration_min,
        avg_speed_kmh=avg_speed,
    )


@router.get("/{patrol_id}", response_model=PatrolOut)
async def get_patrol(
    patrol_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    patrol = await db.get(Patrol, patrol_id)
    if patrol is None:
        raise HTTPException(status_code=404, detail="Patrol not found")
    return PatrolOut.model_validate(patrol)


@router.get("", response_model=List[PatrolOut])
async def list_patrols(
    ranger_id: Optional[uuid.UUID] = Query(None),
    status: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(Patrol).order_by(Patrol.start_time.desc())
    if ranger_id is not None:
        stmt = stmt.where(Patrol.ranger_id == ranger_id)
    if status is not None:
        stmt = stmt.where(Patrol.status == PatrolStatus(status))
    stmt = stmt.offset(offset).limit(limit)

    result = await db.execute(stmt)
    patrols = result.scalars().all()
    return [PatrolOut.model_validate(p) for p in patrols]


@router.get("/{patrol_id}/coverage")
async def patrol_coverage(
    patrol_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    patrol = await db.get(Patrol, patrol_id)
    if patrol is None:
        raise HTTPException(status_code=404, detail="Patrol not found")

    rows = await db.execute(
        select(
            ST_Y(Breadcrumb.position).label("lat"),
            ST_X(Breadcrumb.position).label("lon"),
        )
        .where(Breadcrumb.patrol_id == patrol_id)
    )
    points = rows.all()

    visited: set = set()
    for pt in points:
        lat_m = math.radians(pt.lat) * R_EARTH
        lon_m = math.radians(pt.lon) * R_EARTH * math.cos(math.radians(pt.lat))
        visited.add((int(lon_m // CELL_SIZE_M), int(lat_m // CELL_SIZE_M)))

    return {
        "patrol_id": str(patrol_id),
        "cell_size_m": CELL_SIZE_M,
        "cells_visited": len(visited),
        "coverage_km2": len(visited) * (CELL_SIZE_M ** 2) / 1e6,
        "cells": [{"x": c[0], "y": c[1]} for c in visited],
    }


@router.get("/{patrol_id}/replay", response_model=List[BreadcrumbOut])
async def patrol_replay(
    patrol_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(
            Breadcrumb.id,
            Breadcrumb.patrol_id,
            Breadcrumb.timestamp_s,
            ST_Y(Breadcrumb.position).label("lat"),
            ST_X(Breadcrumb.position).label("lon"),
            Breadcrumb.speed_kmh,
            Breadcrumb.heading_deg,
            Breadcrumb.mode,
            Breadcrumb.confidence_m,
            Breadcrumb.is_outage,
            Breadcrumb.is_snapped,
        )
        .where(Breadcrumb.patrol_id == patrol_id)
        .order_by(Breadcrumb.timestamp_s)
    )
    rows = result.all()
    return [
        BreadcrumbOut(
            id=r.id,
            patrol_id=r.patrol_id,
            timestamp_s=r.timestamp_s,
            lat=r.lat,
            lon=r.lon,
            speed_kmh=r.speed_kmh,
            heading_deg=r.heading_deg,
            mode=r.mode.value if hasattr(r.mode, "value") else r.mode,
            confidence_m=r.confidence_m,
            is_outage=r.is_outage,
            is_snapped=r.is_snapped,
        )
        for r in rows
    ]
