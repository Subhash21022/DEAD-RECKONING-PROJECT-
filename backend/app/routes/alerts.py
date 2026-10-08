import uuid
import json
from datetime import datetime, timezone
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func as sa_func, and_
from geoalchemy2.functions import ST_X, ST_Y

from ..database import get_db
from ..models import Alert, AlertType, AlertSeverity
from ..schemas import AlertCreate, AlertOut
from ..websocket_manager import ConnectionManager

router = APIRouter(prefix="/alerts", tags=["alerts"])


def _alert_to_out(a: Alert, lat: float, lon: float) -> AlertOut:
    return AlertOut(
        id=a.id,
        ranger_id=a.ranger_id,
        patrol_id=a.patrol_id,
        alert_type=a.alert_type.value,
        severity=a.severity.value,
        lat=lat,
        lon=lon,
        heading_deg=a.heading_deg,
        message=a.message,
        battery_pct=a.battery_pct,
        resolved=a.resolved,
        resolved_at=a.resolved_at,
        created_at=a.created_at,
    )


async def _create_alert(
    db: AsyncSession,
    body: AlertCreate,
    alert_type: AlertType,
    severity: AlertSeverity,
    mgr: Optional[ConnectionManager] = None,
) -> AlertOut:
    alert = Alert(
        ranger_id=body.ranger_id,
        patrol_id=body.patrol_id,
        alert_type=alert_type,
        severity=severity,
        position=sa_func.ST_SetSRID(sa_func.ST_MakePoint(body.lon, body.lat), 4326),
        heading_deg=body.heading_deg,
        message=body.message,
        battery_pct=body.battery_pct,
        path_geojson=body.path_geojson,
    )
    db.add(alert)
    await db.flush()
    await db.refresh(alert)

    out = AlertOut(
        id=alert.id,
        ranger_id=alert.ranger_id,
        patrol_id=alert.patrol_id,
        alert_type=alert.alert_type.value,
        severity=alert.severity.value,
        lat=body.lat,
        lon=body.lon,
        heading_deg=alert.heading_deg,
        message=alert.message,
        battery_pct=alert.battery_pct,
        resolved=alert.resolved,
        resolved_at=alert.resolved_at,
        created_at=alert.created_at,
    )

    if mgr is not None:
        await mgr.broadcast_alert(out.model_dump(mode="json"))

    return out


@router.post("/sos", response_model=AlertOut, status_code=201)
async def sos_alert(
    body: AlertCreate,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    mgr: ConnectionManager = request.app.state.ws_manager
    body.alert_type = "SOS"
    body.severity = "CRITICAL"
    return await _create_alert(db, body, AlertType.SOS, AlertSeverity.CRITICAL, mgr)


@router.post("/dead-ranger", response_model=AlertOut, status_code=201)
async def dead_ranger_alert(
    body: AlertCreate,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    mgr: ConnectionManager = request.app.state.ws_manager
    return await _create_alert(db, body, AlertType.DEAD_RANGER, AlertSeverity.CRITICAL, mgr)


@router.post("/geofence-breach", response_model=AlertOut, status_code=201)
async def geofence_breach_alert(
    body: AlertCreate,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    mgr: ConnectionManager = request.app.state.ws_manager
    return await _create_alert(db, body, AlertType.GEOFENCE_BREACH, AlertSeverity.HIGH, mgr)


@router.get("", response_model=List[AlertOut])
async def list_alerts(
    alert_type: Optional[str] = Query(None),
    severity: Optional[str] = Query(None),
    resolved: Optional[bool] = Query(None),
    ranger_id: Optional[uuid.UUID] = Query(None),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(
        Alert,
        ST_Y(Alert.position).label("lat"),
        ST_X(Alert.position).label("lon"),
    ).order_by(Alert.created_at.desc())

    if alert_type is not None:
        stmt = stmt.where(Alert.alert_type == AlertType(alert_type))
    if severity is not None:
        stmt = stmt.where(Alert.severity == AlertSeverity(severity))
    if resolved is not None:
        stmt = stmt.where(Alert.resolved == resolved)
    if ranger_id is not None:
        stmt = stmt.where(Alert.ranger_id == ranger_id)

    stmt = stmt.offset(offset).limit(limit)
    result = await db.execute(stmt)
    rows = result.all()
    return [_alert_to_out(r.Alert, r.lat, r.lon) for r in rows]


@router.patch("/{alert_id}/resolve", response_model=AlertOut)
async def resolve_alert(
    alert_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(
            Alert,
            ST_Y(Alert.position).label("lat"),
            ST_X(Alert.position).label("lon"),
        ).where(Alert.id == alert_id)
    )
    row = result.one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Alert not found")

    alert = row.Alert
    alert.resolved = True
    alert.resolved_at = datetime.now(timezone.utc)
    await db.flush()

    return _alert_to_out(alert, row.lat, row.lon)
