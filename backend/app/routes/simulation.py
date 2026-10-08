import uuid
import asyncio
import time
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Request, Query
from pydantic import BaseModel, Field


router = APIRouter(tags=["simulation"])

# ---------------------------------------------------------------------------
# In-memory stores (no PostgreSQL required)
# ---------------------------------------------------------------------------
_rangers: Dict[str, Dict[str, Any]] = {}
_patrols: Dict[str, Dict[str, Any]] = {}
_breadcrumbs: Dict[str, List[Dict[str, Any]]] = {}
_alerts: List[Dict[str, Any]] = []
_geofences: List[Dict[str, Any]] = []
_ws_clients: set = set()


# ---------------------------------------------------------------------------
# Pydantic schemas for simulation payloads
# ---------------------------------------------------------------------------
class SyncPoint(BaseModel):
    recorded_at: str
    latitude: float
    longitude: float
    speed_kmh: float = 0.0
    heading_deg: float = 0.0
    mode: str = "VEHICLE"
    gnss_quality: str = "GOOD"
    confidence_radius_m: float = 5.0
    is_outage: bool = False
    battery_level: float = 100.0


class SyncBatchPayload(BaseModel):
    mission_uid: str
    callsign: str
    points: List[SyncPoint]


class SOSBeaconPayload(BaseModel):
    mission_uid: str
    callsign: str
    latitude: float
    longitude: float
    heading_deg: float = 0.0
    speed_kmh: float = 0.0
    battery_level: float = 100.0
    reason: str = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _mode_color(mode: str) -> str:
    return {"VEHICLE": "forest", "PEDESTRIAN": "blue", "STATIONARY": "tactical"}.get(mode, "tactical")


async def _broadcast(payload: dict):
    stale = set()
    for ws in _ws_clients:
        try:
            await ws.send_json(payload)
        except Exception:
            stale.add(ws)
    _ws_clients.difference_update(stale)


# ---------------------------------------------------------------------------
# Simulation data ingestion
# ---------------------------------------------------------------------------
@router.post("/api/v1/patrol/sync-batch")
async def sync_batch(body: SyncBatchPayload):
    patrol_id = body.mission_uid
    callsign = body.callsign
    ranger_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, callsign))

    if patrol_id not in _patrols:
        _patrols[patrol_id] = {
            "id": patrol_id,
            "ranger_id": ranger_id,
            "ranger_callsign": callsign,
            "start_time": datetime.now(timezone.utc).isoformat(),
            "end_time": None,
            "status": "ACTIVE",
            "distance_km": 0.0,
            "coverage_km2": 0.0,
            "breadcrumb_count": 0,
        }
        _breadcrumbs[patrol_id] = []

    patrol = _patrols[patrol_id]
    results = []

    for pt in body.points:
        crumb = {
            "timestamp_s": datetime.fromisoformat(pt.recorded_at).timestamp(),
            "lat": pt.latitude,
            "lon": pt.longitude,
            "speed_kmh": pt.speed_kmh,
            "heading_deg": pt.heading_deg,
            "mode": pt.mode,
            "confidence_m": pt.confidence_radius_m,
            "is_outage": pt.is_outage,
        }
        _breadcrumbs[patrol_id].append(crumb)
        patrol["breadcrumb_count"] = len(_breadcrumbs[patrol_id])

        _rangers[ranger_id] = {
            "id": ranger_id,
            "callsign": callsign,
            "lat": pt.latitude,
            "lon": pt.longitude,
            "heading_deg": pt.heading_deg,
            "speed_kmh": pt.speed_kmh,
            "mode": pt.mode,
            "gnss_quality": pt.gnss_quality,
            "confidence_radius_m": pt.confidence_radius_m,
            "battery_pct": pt.battery_level,
            "is_sos": False,
            "last_update": datetime.now(timezone.utc).isoformat(),
        }

        await _broadcast({
            "type": "ranger_update",
            "payload": _rangers[ranger_id],
        })

        results.append(crumb)

    return {"status": "ok", "points_ingested": len(results)}


@router.post("/api/v1/patrol/sos-beacon")
async def sos_beacon(body: SOSBeaconPayload):
    ranger_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, body.callsign))
    alert_id = str(uuid.uuid4())

    alert = {
        "id": alert_id,
        "ranger_id": ranger_id,
        "ranger_callsign": body.callsign,
        "alert_type": "SOS",
        "severity": "CRITICAL",
        "message": body.reason or "SOS EMERGENCY BEACON",
        "lat": body.latitude,
        "lon": body.longitude,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "resolved_at": None,
        "is_resolved": False,
    }
    _alerts.insert(0, alert)

    if ranger_id in _rangers:
        _rangers[ranger_id]["is_sos"] = True
        _rangers[ranger_id]["speed_kmh"] = body.speed_kmh
        _rangers[ranger_id]["lat"] = body.latitude
        _rangers[ranger_id]["lon"] = body.longitude
        _rangers[ranger_id]["battery_pct"] = body.battery_level
        _rangers[ranger_id]["last_update"] = datetime.now(timezone.utc).isoformat()

    await _broadcast({"type": "alert", "payload": alert})
    if ranger_id in _rangers:
        await _broadcast({"type": "ranger_update", "payload": _rangers[ranger_id]})

    return {"status": "ok", "alert_id": alert_id}


# ---------------------------------------------------------------------------
# Dashboard API endpoints (used by web-dashboard)
# ---------------------------------------------------------------------------
@router.get("/api/v1/patrol/dashboard")
async def dashboard_stats():
    active_patrols = [p for p in _patrols.values() if p["status"] == "ACTIVE"]
    unresolved_alerts = [a for a in _alerts if not a["is_resolved"]]
    return {
        "active_rangers": len(_rangers),
        "active_patrols": len(active_patrols),
        "total_coverage_km2": sum(p.get("coverage_km2", 0) for p in _patrols.values()),
        "active_alerts": len(unresolved_alerts),
        "recent_alerts": _alerts[:10],
        "recent_patrols": list(_patrols.values())[:10],
    }


@router.get("/api/v1/telemetry/rangers")
async def list_rangers():
    return list(_rangers.values())


@router.get("/api/v1/patrol/list")
async def list_patrols():
    return list(_patrols.values())


@router.get("/api/v1/patrol/{patrol_id}/breadcrumbs")
async def patrol_breadcrumbs(patrol_id: str):
    return _breadcrumbs.get(patrol_id, [])


@router.get("/api/v1/alerts/list")
async def list_alerts(resolved: Optional[bool] = Query(None)):
    if resolved is not None:
        return [a for a in _alerts if a["is_resolved"] == resolved]
    return _alerts


@router.patch("/api/v1/alerts/{alert_id}/resolve")
async def resolve_alert(alert_id: str):
    for a in _alerts:
        if a["id"] == alert_id:
            a["is_resolved"] = True
            a["resolved_at"] = datetime.now(timezone.utc).isoformat()
            await _broadcast({"type": "alert", "payload": a})
            return a
    return {"error": "not found"}


@router.get("/api/v1/geofence/list")
async def list_geofences():
    if not _geofences:
        return [
            {
                "id": str(uuid.uuid4()),
                "name": "Bandipur Tiger Reserve Core",
                "zone_type": "CORE_PROTECTED",
                "polygon": {
                    "type": "Polygon",
                    "coordinates": [[
                        [77.590, 12.968], [77.600, 12.968],
                        [77.600, 12.978], [77.590, 12.978],
                        [77.590, 12.968],
                    ]],
                },
            },
            {
                "id": str(uuid.uuid4()),
                "name": "Northern Buffer Zone",
                "zone_type": "BUFFER_ZONE",
                "polygon": {
                    "type": "Polygon",
                    "coordinates": [[
                        [77.592, 12.978], [77.598, 12.978],
                        [77.598, 12.983], [77.592, 12.983],
                        [77.592, 12.978],
                    ]],
                },
            },
        ]
    return _geofences


# ---------------------------------------------------------------------------
# Live WebSocket for dashboard
# ---------------------------------------------------------------------------
@router.websocket("/ws/live")
async def live_ws(ws: WebSocket):
    await ws.accept()
    _ws_clients.add(ws)
    try:
        if _rangers:
            for r in _rangers.values():
                await ws.send_json({"type": "ranger_update", "payload": r})
        for a in _alerts:
            if not a["is_resolved"]:
                await ws.send_json({"type": "alert", "payload": a})

        while True:
            data = await ws.receive_text()
            if data == "ping":
                await ws.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        _ws_clients.discard(ws)


# ---------------------------------------------------------------------------
# Background Simulation Runner (Stream to Live Dashboard)
# ---------------------------------------------------------------------------
WAYPOINTS_SIM = [
    {"lat": 12.9700, "lon": 77.5920, "speed_kmh": 20.0, "heading": 40.0,  "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.2},
    {"lat": 12.9708, "lon": 77.5928, "speed_kmh": 25.0, "heading": 42.0,  "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.5},
    {"lat": 12.9716, "lon": 77.5935, "speed_kmh": 28.0, "heading": 45.0,  "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.4},
    {"lat": 12.9724, "lon": 77.5943, "speed_kmh": 30.0, "heading": 47.0,  "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.6},
    {"lat": 12.9731, "lon": 77.5950, "speed_kmh": 26.0, "heading": 50.0,  "mode": "VEHICLE",    "gnss": "GOOD", "conf": 4.1},
    {"lat": 12.9738, "lon": 77.5956, "speed_kmh": 22.0, "heading": 52.0,  "mode": "VEHICLE",    "gnss": "LOST", "conf": 8.5},
    {"lat": 12.9744, "lon": 77.5962, "speed_kmh": 18.0, "heading": 55.0,  "mode": "VEHICLE",    "gnss": "LOST", "conf": 12.1},
    {"lat": 12.9750, "lon": 77.5967, "speed_kmh": 15.0, "heading": 58.0,  "mode": "VEHICLE",    "gnss": "LOST", "conf": 14.8},
    {"lat": 12.9752, "lon": 77.5968, "speed_kmh": 5.0,  "heading": 58.0,  "mode": "VEHICLE",    "gnss": "LOST", "conf": 15.2},
    {"lat": 12.9753, "lon": 77.5968, "speed_kmh": 0.0,  "heading": 58.0,  "mode": "STATIONARY", "gnss": "LOST", "conf": 15.3},
    {"lat": 12.9753, "lon": 77.5968, "speed_kmh": 0.0,  "heading": 58.0,  "mode": "STATIONARY", "gnss": "LOST", "conf": 15.3},
    {"lat": 12.9755, "lon": 77.5970, "speed_kmh": 4.5,  "heading": 60.0,  "mode": "PEDESTRIAN", "gnss": "LOST", "conf": 16.4},
    {"lat": 12.9757, "lon": 77.5972, "speed_kmh": 4.8,  "heading": 65.0,  "mode": "PEDESTRIAN", "gnss": "LOST", "conf": 17.1},
    {"lat": 12.9760, "lon": 77.5973, "speed_kmh": 5.0,  "heading": 70.0,  "mode": "PEDESTRIAN", "gnss": "LOST", "conf": 18.2},
    {"lat": 12.9763, "lon": 77.5974, "speed_kmh": 3.5,  "heading": 80.0,  "mode": "PEDESTRIAN", "gnss": "LOST", "conf": 19.0},
    {"lat": 12.9765, "lon": 77.5974, "speed_kmh": 4.2,  "heading": 90.0,  "mode": "PEDESTRIAN", "gnss": "LOST", "conf": 19.5},
    {"lat": 12.9767, "lon": 77.5975, "speed_kmh": 4.0,  "heading": 85.0,  "mode": "PEDESTRIAN", "gnss": "GOOD", "conf": 4.2},
    {"lat": 12.9770, "lon": 77.5976, "speed_kmh": 4.5,  "heading": 80.0,  "mode": "PEDESTRIAN", "gnss": "GOOD", "conf": 3.8},
    {"lat": 12.9770, "lon": 77.5976, "speed_kmh": 0.0,  "heading": 80.0,  "mode": "STATIONARY", "gnss": "GOOD", "conf": 3.5},
    {"lat": 12.9768, "lon": 77.5974, "speed_kmh": 20.0, "heading": 220.0, "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.2},
    {"lat": 12.9762, "lon": 77.5968, "speed_kmh": 25.0, "heading": 225.0, "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.4},
    {"lat": 12.9755, "lon": 77.5960, "speed_kmh": 28.0, "heading": 230.0, "mode": "VEHICLE",    "gnss": "GOOD", "conf": 3.5},
]

_active_sim_task: Optional[asyncio.Task] = None

async def _simulation_worker():
    callsign = "RANGER-TIGER-04"
    ranger_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, callsign))
    patrol_id = "MISSION-PATROL-LIVE"

    _patrols[patrol_id] = {
        "id": patrol_id,
        "ranger_id": ranger_id,
        "ranger_callsign": callsign,
        "start_time": datetime.now(timezone.utc).isoformat(),
        "end_time": None,
        "status": "ACTIVE",
        "distance_km": 0.0,
        "coverage_km2": 0.0,
        "breadcrumb_count": 0,
    }
    _breadcrumbs[patrol_id] = []

    # Reset any existing alerts
    for a in _alerts:
        a["is_resolved"] = True

    for i, wp in enumerate(WAYPOINTS_SIM):
        crumb = {
            "timestamp_s": time.time(),
            "lat": wp["lat"],
            "lon": wp["lon"],
            "speed_kmh": wp["speed_kmh"],
            "heading_deg": wp["heading"],
            "mode": wp["mode"],
            "confidence_m": wp["conf"],
            "is_outage": wp["gnss"] == "LOST",
        }
        _breadcrumbs[patrol_id].append(crumb)
        _patrols[patrol_id]["breadcrumb_count"] = len(_breadcrumbs[patrol_id])

        _rangers[ranger_id] = {
            "id": ranger_id,
            "callsign": callsign,
            "lat": wp["lat"],
            "lon": wp["lon"],
            "heading_deg": wp["heading"],
            "speed_kmh": wp["speed_kmh"],
            "mode": wp["mode"],
            "gnss_quality": wp["gnss"],
            "confidence_radius_m": wp["conf"],
            "battery_pct": max(45.0, 95.0 - i * 2.0),
            "is_sos": False,
            "last_update": datetime.now(timezone.utc).isoformat(),
        }

        await _broadcast({"type": "ranger_update", "payload": _rangers[ranger_id]})
        await asyncio.sleep(1.5)

    # Trigger SOS at end of mission
    alert_id = str(uuid.uuid4())
    alert = {
        "id": alert_id,
        "ranger_id": ranger_id,
        "ranger_callsign": callsign,
        "alert_type": "SOS",
        "severity": "CRITICAL",
        "message": "EMERGENCY - Poacher activity detected",
        "lat": WAYPOINTS_SIM[-1]["lat"],
        "lon": WAYPOINTS_SIM[-1]["lon"],
        "created_at": datetime.now(timezone.utc).isoformat(),
        "resolved_at": None,
        "is_resolved": False,
    }
    _alerts.insert(0, alert)
    _rangers[ranger_id]["is_sos"] = True
    _rangers[ranger_id]["speed_kmh"] = 0.0

    await _broadcast({"type": "alert", "payload": alert})
    await _broadcast({"type": "ranger_update", "payload": _rangers[ranger_id]})


@router.post("/api/v1/simulation/start")
async def start_simulation():
    global _active_sim_task
    if _active_sim_task and not _active_sim_task.done():
        _active_sim_task.cancel()
    _active_sim_task = asyncio.create_task(_simulation_worker())
    return {"status": "started", "waypoints_count": len(WAYPOINTS_SIM)}


@router.post("/api/v1/simulation/reset")
async def reset_simulation():
    _rangers.clear()
    _patrols.clear()
    _breadcrumbs.clear()
    _alerts.clear()
    return {"status": "reset", "message": "All simulation data cleared"}

