import os
import asyncio
import time
import json
import logging
from pathlib import Path
from dataclasses import asdict
from typing import Optional, List
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, status
from pydantic import BaseModel, Field, field_validator
import numpy as np

from engine.fusion_engine import FusionEngine, NavigationState
from engine.patrol_analytics import SilentPatrolTracker, PatrolCoverageEstimator

logger = logging.getLogger("edge-engine")

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"


class IMUSample(BaseModel):
    timestamp_s: float = Field(..., description="Unix epoch seconds")
    ax: float = Field(..., description="Accelerometer X (m/s²)")
    ay: float = Field(..., description="Accelerometer Y (m/s²)")
    az: float = Field(..., description="Accelerometer Z (m/s²)")
    gx: float = Field(..., description="Gyroscope X (rad/s)")
    gy: float = Field(..., description="Gyroscope Y (rad/s)")
    gz: float = Field(..., description="Gyroscope Z (rad/s)")
    lat: Optional[float] = Field(None, ge=-90, le=90, description="WGS84 latitude")
    lon: Optional[float] = Field(None, ge=-180, le=180, description="WGS84 longitude")
    gnss_speed: Optional[float] = Field(None, ge=0, description="GNSS speed (m/s)")
    gnss_acc: Optional[float] = Field(None, ge=0, description="GNSS accuracy (m)")
    gnss_bearing: Optional[float] = Field(None, ge=0, le=360, description="GNSS bearing (deg)")
    gnss_enabled: Optional[bool] = Field(True, description="Whether location service is enabled on the device")
    satellites: Optional[int] = Field(None, ge=0, description="Satellite count")


class BatchIMURequest(BaseModel):
    samples: List[IMUSample] = Field(..., min_length=1, max_length=1000)


class TrailLoadRequest(BaseModel):
    lats: List[float] = Field(..., min_length=2)
    lons: List[float] = Field(..., min_length=2)

    @field_validator("lons")
    @classmethod
    def lats_lons_same_length(cls, v, info):
        if "lats" in info.data and len(v) != len(info.data["lats"]):
            raise ValueError("lats and lons must have the same length")
        return v


class NavigationStateResponse(BaseModel):
    timestamp_s: float
    lat: float
    lon: float
    matched_lat: float
    matched_lon: float
    is_snapped: bool
    pos_east_m: float
    pos_north_m: float
    speed_mps: float
    speed_kmh: float
    heading_deg: float
    gyro_bias_rads: float
    speed_scale_factor: float
    confidence_radius_m: float
    is_stationary: bool
    is_ood: bool
    ood_entropy: float
    mode: str
    gnss_quality: str
    is_outage: bool
    nav_system_state: str = "GNSS_LOST"
    last_transition: str = ""
    satellites_count: int = 0
    gnss_accuracy_m: float = 999.0
    model_running: bool = False
    model_speed_mps: float = 0.0
    zupt_active: bool = False
    dr_lat: float = 0.0
    dr_lon: float = 0.0
    raw_gnss_lat: Optional[float] = None
    raw_gnss_lon: Optional[float] = None


class EngineStateResponse(BaseModel):
    state_vector: List[float]
    covariance_diagonal: List[float]
    confidence_radius_m: float
    speed_scale_factor: float
    is_stationary: bool
    mode: str
    gnss_quality: str
    sample_count: int
    origin_lat: Optional[float]
    origin_lon: Optional[float]


class HealthResponse(BaseModel):
    status: str
    models_loaded: bool
    uptime_s: float
    samples_processed: int


engine: Optional[FusionEngine] = None
tracker: Optional[SilentPatrolTracker] = None
coverage: Optional[PatrolCoverageEstimator] = None
start_time: float = 0.0
ws_clients: set = set()


@asynccontextmanager
async def lifespan(app: FastAPI):
    global engine, tracker, coverage, start_time
    start_time = time.time()

    classifier_path = str(MODELS_DIR / "motion_classifier.onnx")
    speed_path = str(MODELS_DIR / "universal_speed_estimator.onnx")
    ped_path = str(MODELS_DIR / "pedestrian_speed_estimator.onnx")

    if not os.path.exists(classifier_path):
        raise RuntimeError(f"Motion classifier not found: {classifier_path}")
    if not os.path.exists(speed_path):
        raise RuntimeError(f"Speed estimator not found: {speed_path}")

    engine = FusionEngine(
        classifier_onnx_path=classifier_path,
        speed_onnx_path=speed_path,
        pedestrian_onnx_path=ped_path if os.path.exists(ped_path) else None,
    )
    tracker = SilentPatrolTracker()
    coverage = PatrolCoverageEstimator()
    logger.info("Edge engine initialized with all ONNX models")
    yield
    logger.info("Edge engine shutting down")


app = FastAPI(
    title="DeadReckon Edge Engine API",
    description="100Hz IMU ingestion, 10Hz ONNX inference, 5-State EKF fusion",
    version="1.0.0",
    lifespan=lifespan,
)


def _nav_to_response(nav: NavigationState) -> NavigationStateResponse:
    return NavigationStateResponse(**asdict(nav))


def _process_sample(sample: IMUSample) -> NavigationStateResponse:
    nav = engine.step(
        timestamp_s=sample.timestamp_s,
        ax=sample.ax,
        ay=sample.ay,
        az=sample.az,
        gx=sample.gx,
        gy=sample.gy,
        gz=sample.gz,
        lat=sample.lat,
        lon=sample.lon,
        gnss_speed_mps=sample.gnss_speed,
        gnss_accuracy_m=sample.gnss_acc,
        gnss_bearing_deg=sample.gnss_bearing,
        gnss_enabled=sample.gnss_enabled if sample.gnss_enabled is not None else True,
        satellites=sample.satellites,
    )
    tracker.record_step(
        timestamp_s=nav.timestamp_s,
        lat=nav.lat,
        lon=nav.lon,
        speed_kmh=nav.speed_kmh,
        heading_deg=nav.heading_deg,
        mode=nav.mode,
        confidence_m=nav.confidence_radius_m,
        is_outage=nav.is_outage,
    )
    coverage.update_position(nav.lat, nav.lon)
    return _nav_to_response(nav)


@app.get("/health", response_model=HealthResponse)
async def health_check():
    return HealthResponse(
        status="ok" if engine is not None else "initializing",
        models_loaded=engine is not None,
        uptime_s=round(time.time() - start_time, 2),
        samples_processed=engine.sample_counter if engine else 0,
    )


@app.post("/ingest", response_model=NavigationStateResponse)
async def ingest_sample(sample: IMUSample):
    if engine is None:
        raise HTTPException(status_code=503, detail="Engine not initialized")
    result = await asyncio.get_event_loop().run_in_executor(None, _process_sample, sample)
    await _broadcast_ws(result)
    return result


@app.post("/ingest/batch", response_model=List[NavigationStateResponse])
async def ingest_batch(batch: BatchIMURequest):
    if engine is None:
        raise HTTPException(status_code=503, detail="Engine not initialized")

    def _run_batch():
        results = []
        for sample in batch.samples:
            results.append(_process_sample(sample))
        return results

    results = await asyncio.get_event_loop().run_in_executor(None, _run_batch)
    if results:
        await _broadcast_ws(results[-1])
    return results


@app.post("/trails/load", status_code=status.HTTP_204_NO_CONTENT)
async def load_trails(req: TrailLoadRequest):
    if engine is None:
        raise HTTPException(status_code=503, detail="Engine not initialized")
    engine.load_trail_network(req.lats, req.lons)


@app.get("/state", response_model=EngineStateResponse)
async def get_engine_state():
    if engine is None:
        raise HTTPException(status_code=503, detail="Engine not initialized")
    eigvals = np.linalg.eigvalsh(engine.P[0:2, 0:2])
    conf_r = float(2.0 * np.sqrt(max(1e-4, np.max(eigvals))))
    return EngineStateResponse(
        state_vector=engine.x.tolist(),
        covariance_diagonal=np.diag(engine.P).tolist(),
        confidence_radius_m=round(conf_r, 3),
        speed_scale_factor=round(engine.speed_scale_factor, 4),
        is_stationary=engine.is_stationary,
        mode=engine.mode_mgr.current_mode.value,
        gnss_quality=engine.gnss_mgr.current_quality.value,
        sample_count=engine.sample_counter,
        origin_lat=engine.origin_lat,
        origin_lon=engine.origin_lon,
    )


@app.get("/coverage")
async def get_coverage():
    if coverage is None:
        raise HTTPException(status_code=503, detail="Engine not initialized")
    return {
        "area_km2": round(len(coverage.visited_cells) * (coverage.cell_size_m ** 2) / 1e6, 4),
        "cells_visited": len(coverage.visited_cells),
        "total_distance_m": round(coverage.total_distance_m, 1),
    }


@app.get("/breadcrumbs/geojson")
async def get_breadcrumbs():
    if tracker is None:
        raise HTTPException(status_code=503, detail="Engine not initialized")
    return tracker.export_geojson()


async def _broadcast_ws(state: NavigationStateResponse):
    if not ws_clients:
        return
    payload = state.model_dump_json()
    stale = set()
    for ws in ws_clients:
        try:
            await ws.send_text(payload)
        except Exception:
            stale.add(ws)
    ws_clients.difference_update(stale)


@app.websocket("/ws/stream")
async def websocket_stream(ws: WebSocket):
    await ws.accept()
    ws_clients.add(ws)
    logger.info(f"WebSocket client connected ({len(ws_clients)} total)")
    try:
        while True:
            raw = await ws.receive_text()
            try:
                data = json.loads(raw)
                sample = IMUSample(**data)
                result = _process_sample(sample)
                await ws.send_text(result.model_dump_json())
            except Exception as e:
                await ws.send_text(json.dumps({"error": str(e)}))
    except WebSocketDisconnect:
        pass
    finally:
        ws_clients.discard(ws)
        logger.info(f"WebSocket client disconnected ({len(ws_clients)} remaining)")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("api.inference_api:app", host="0.0.0.0", port=8001, reload=False, log_level="info")
