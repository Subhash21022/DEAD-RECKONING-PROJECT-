import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func as sa_func

from ..database import get_db
from ..models import Breadcrumb, Patrol, NavigationMode as DBNavMode
from ..schemas import SyncPayload, SyncStatusOut

router = APIRouter(prefix="/sync", tags=["sync"])


def _parse_mode(mode_str: str) -> DBNavMode:
    mapping = {
        "STATIONARY": DBNavMode.STATIONARY,
        "VEHICLE": DBNavMode.VEHICLE,
        "PEDESTRIAN": DBNavMode.PEDESTRIAN,
    }
    return mapping.get(mode_str, DBNavMode.STATIONARY)


@router.post("/upload", response_model=SyncStatusOut)
async def upload_offline_breadcrumbs(
    body: SyncPayload,
    db: AsyncSession = Depends(get_db),
):
    patrol = await db.get(Patrol, body.patrol_id)
    if patrol is None:
        raise HTTPException(status_code=404, detail="Patrol not found")

    geojson = body.breadcrumbs
    if geojson.get("type") != "FeatureCollection":
        raise HTTPException(status_code=422, detail="Expected GeoJSON FeatureCollection")

    features = geojson.get("features", [])
    inserted = 0
    last_ts: Optional[float] = None

    for feature in features:
        geom = feature.get("geometry", {})
        props = feature.get("properties", {})
        geom_type = geom.get("type")

        if geom_type == "LineString":
            coords = geom.get("coordinates", [])
            for coord in coords:
                if len(coord) < 2:
                    continue
                lon, lat = coord[0], coord[1]
                speed = coord[2] if len(coord) > 2 else 0.0
                ts = props.get("start_time", 0.0) + inserted * 0.1

                crumb = Breadcrumb(
                    patrol_id=body.patrol_id,
                    timestamp_s=ts,
                    position=sa_func.ST_SetSRID(sa_func.ST_MakePoint(lon, lat), 4326),
                    speed_kmh=speed,
                    heading_deg=props.get("heading_deg", 0.0),
                    mode=_parse_mode(props.get("mode", "VEHICLE")),
                    confidence_m=props.get("confidence_m", 10.0),
                    is_outage=True,
                    is_snapped=False,
                )
                db.add(crumb)
                inserted += 1
                last_ts = ts

        elif geom_type == "Point":
            coords = geom.get("coordinates", [])
            if len(coords) >= 2:
                lon, lat = coords[0], coords[1]
                ts = props.get("timestamp_s", 0.0)
                crumb = Breadcrumb(
                    patrol_id=body.patrol_id,
                    timestamp_s=ts,
                    position=sa_func.ST_SetSRID(sa_func.ST_MakePoint(lon, lat), 4326),
                    speed_kmh=props.get("speed_kmh", 0.0),
                    heading_deg=props.get("heading_deg", 0.0),
                    mode=_parse_mode(props.get("mode", "STATIONARY")),
                    confidence_m=props.get("confidence_m", 10.0),
                    is_outage=props.get("is_outage", True),
                    is_snapped=False,
                )
                db.add(crumb)
                inserted += 1
                last_ts = ts

    await db.flush()

    patrol.breadcrumb_count = (patrol.breadcrumb_count or 0) + inserted
    await db.flush()

    return SyncStatusOut(
        patrol_id=body.patrol_id,
        breadcrumb_count=patrol.breadcrumb_count,
        last_synced_timestamp=last_ts,
        status="OK",
    )


@router.get("/status/{patrol_id}", response_model=SyncStatusOut)
async def sync_status(
    patrol_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    patrol = await db.get(Patrol, patrol_id)
    if patrol is None:
        raise HTTPException(status_code=404, detail="Patrol not found")

    result = await db.execute(
        select(sa_func.max(Breadcrumb.timestamp_s))
        .where(Breadcrumb.patrol_id == patrol_id)
    )
    last_ts = result.scalar_one_or_none()

    return SyncStatusOut(
        patrol_id=patrol_id,
        breadcrumb_count=patrol.breadcrumb_count or 0,
        last_synced_timestamp=last_ts,
        status="OK",
    )
