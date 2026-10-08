import uuid
import json
from typing import List

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import func as sa_func
from geoalchemy2.functions import ST_MakePoint, ST_SetSRID
import httpx

from ..database import get_db
from ..config import settings
from ..models import Breadcrumb, Patrol, NavigationMode as DBNavMode, PatrolStatus
from ..schemas import TelemetryIn, TelemetryBatchIn, NavigationStateOut, BreadcrumbOut
from ..auth import get_current_ranger
from ..websocket_manager import ConnectionManager

router = APIRouter(prefix="/telemetry", tags=["telemetry"])


def _mode_to_db(mode_str: str) -> DBNavMode:
    mapping = {
        "STATIONARY": DBNavMode.STATIONARY,
        "VEHICLE": DBNavMode.VEHICLE,
        "PEDESTRIAN": DBNavMode.PEDESTRIAN,
    }
    return mapping.get(mode_str, DBNavMode.STATIONARY)


async def _forward_to_edge(sample: TelemetryIn) -> dict:
    async with httpx.AsyncClient(timeout=2.0) as client:
        resp = await client.post(
            f"{settings.EDGE_ENGINE_URL}/ingest",
            json={
                "timestamp_s": sample.timestamp_s,
                "ax": sample.ax,
                "ay": sample.ay,
                "az": sample.az,
                "gx": sample.gx,
                "gy": sample.gy,
                "gz": sample.gz,
                "lat": sample.lat,
                "lon": sample.lon,
                "gnss_speed": sample.gnss_speed_mps,
                "gnss_acc": sample.gnss_accuracy_m,
                "gnss_bearing": sample.gnss_bearing_deg,
            },
        )
        resp.raise_for_status()
        return resp.json()


async def _store_breadcrumb(
    db: AsyncSession,
    patrol_id: uuid.UUID,
    nav: dict,
) -> Breadcrumb:
    lat = nav.get("matched_lat", nav.get("lat", 0.0))
    lon = nav.get("matched_lon", nav.get("lon", 0.0))
    crumb = Breadcrumb(
        patrol_id=patrol_id,
        timestamp_s=nav["timestamp_s"],
        position=sa_func.ST_SetSRID(sa_func.ST_MakePoint(lon, lat), 4326),
        speed_kmh=nav.get("speed_kmh", 0.0),
        heading_deg=nav.get("heading_deg", 0.0),
        mode=_mode_to_db(nav.get("mode", "STATIONARY")),
        confidence_m=nav.get("confidence_radius_m", 5.0),
        is_outage=nav.get("is_outage", False),
        is_snapped=nav.get("is_snapped", False),
    )
    db.add(crumb)
    await db.flush()
    return crumb


@router.post("/ingest", response_model=NavigationStateOut)
async def ingest_single(
    body: TelemetryIn,
    patrol_id: uuid.UUID,
    ranger_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    request: Request = None,
):
    try:
        nav = await _forward_to_edge(body)
    except Exception:
        raise HTTPException(status_code=502, detail="Edge engine unreachable")

    await _store_breadcrumb(db, patrol_id, nav)

    mgr: ConnectionManager = request.app.state.ws_manager
    await mgr.broadcast_to_all({
        "type": "NAV_UPDATE",
        "ranger_id": str(ranger_id),
        "payload": nav,
    })

    return NavigationStateOut(**nav)


@router.post("/batch", response_model=List[NavigationStateOut])
async def ingest_batch(
    body: TelemetryBatchIn,
    db: AsyncSession = Depends(get_db),
    request: Request = None,
):
    results: List[dict] = []
    for sample in body.samples:
        try:
            nav = await _forward_to_edge(sample)
        except Exception:
            continue
        await _store_breadcrumb(db, body.patrol_id, nav)
        results.append(nav)

    if results:
        mgr: ConnectionManager = request.app.state.ws_manager
        await mgr.broadcast_to_all({
            "type": "NAV_BATCH",
            "ranger_id": str(body.ranger_id),
            "payload": results[-1],
        })

    return [NavigationStateOut(**r) for r in results]


@router.websocket("/ws/{ranger_id}")
async def telemetry_ws(
    websocket: WebSocket,
    ranger_id: uuid.UUID,
):
    mgr: ConnectionManager = websocket.app.state.ws_manager
    await mgr.connect(websocket, ranger_id)
    try:
        while True:
            data = await websocket.receive_json()
            action = data.get("action")

            if action == "step":
                sample = TelemetryIn(**data["sample"])
                patrol_id = uuid.UUID(data["patrol_id"])
                try:
                    nav = await _forward_to_edge(sample)
                except Exception:
                    await websocket.send_json({"error": "edge_unreachable"})
                    continue

                async with websocket.app.state.db_session() as db:
                    await _store_breadcrumb(db, patrol_id, nav)
                    await db.commit()

                await websocket.send_json({"type": "NAV_UPDATE", "payload": nav})
                await mgr.broadcast_to_all({
                    "type": "NAV_UPDATE",
                    "ranger_id": str(ranger_id),
                    "payload": nav,
                })

            elif action == "ping":
                await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        pass
    finally:
        await mgr.disconnect(ranger_id)
