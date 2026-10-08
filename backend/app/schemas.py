import uuid
from datetime import datetime
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field, ConfigDict


class TelemetryIn(BaseModel):
    timestamp_s: float
    ax: float
    ay: float
    az: float
    gx: float
    gy: float
    gz: float
    lat: Optional[float] = None
    lon: Optional[float] = None
    gnss_speed_mps: Optional[float] = None
    gnss_accuracy_m: Optional[float] = None
    gnss_bearing_deg: Optional[float] = None


class TelemetryBatchIn(BaseModel):
    ranger_id: uuid.UUID
    patrol_id: uuid.UUID
    samples: List[TelemetryIn]


class NavigationStateOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

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


class BreadcrumbOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    patrol_id: uuid.UUID
    timestamp_s: float
    lat: float
    lon: float
    speed_kmh: float
    heading_deg: float
    mode: str
    confidence_m: float
    is_outage: bool
    is_snapped: bool


class RangerCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    callsign: str = Field(..., min_length=1, max_length=32)
    badge_number: str = Field(..., min_length=1, max_length=32)
    password: str = Field(..., min_length=6)


class RangerOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    callsign: str
    badge_number: str
    created_at: datetime


class PatrolCreate(BaseModel):
    ranger_id: uuid.UUID


class PatrolOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    ranger_id: uuid.UUID
    start_time: datetime
    end_time: Optional[datetime] = None
    status: str
    total_distance_m: float
    coverage_km2: float
    breadcrumb_count: int


class PatrolSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    ranger_id: uuid.UUID
    start_time: datetime
    end_time: Optional[datetime] = None
    status: str
    total_distance_m: float
    coverage_km2: float
    breadcrumb_count: int
    duration_minutes: Optional[float] = None
    avg_speed_kmh: Optional[float] = None


class AlertCreate(BaseModel):
    ranger_id: uuid.UUID
    patrol_id: Optional[uuid.UUID] = None
    alert_type: str
    severity: str = "HIGH"
    lat: float
    lon: float
    heading_deg: float = 0.0
    message: str = ""
    battery_pct: Optional[float] = None
    path_geojson: Optional[str] = None


class AlertOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    ranger_id: uuid.UUID
    patrol_id: Optional[uuid.UUID] = None
    alert_type: str
    severity: str
    lat: float
    lon: float
    heading_deg: float
    message: str
    battery_pct: Optional[float] = None
    resolved: bool
    resolved_at: Optional[datetime] = None
    created_at: datetime


class SightingCreate(BaseModel):
    ranger_id: uuid.UUID
    patrol_id: Optional[uuid.UUID] = None
    species: str = Field(..., min_length=1, max_length=64)
    count: int = Field(default=1, ge=1)
    lat: float
    lon: float
    description: str = ""
    photo_url: Optional[str] = None


class SightingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    ranger_id: uuid.UUID
    patrol_id: Optional[uuid.UUID] = None
    species: str
    count: int
    lat: float
    lon: float
    description: str
    photo_url: Optional[str] = None
    created_at: datetime


class GeoFenceCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    zone_type: str = "CORE_PROTECTED"
    polygon_coords: List[List[float]] = Field(
        ..., description="List of [lon, lat] pairs forming the polygon boundary"
    )


class GeoFenceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    zone_type: str
    is_active: bool
    created_at: datetime


class GeoFenceCheckRequest(BaseModel):
    lat: float
    lon: float


class GeoFenceCheckResponse(BaseModel):
    inside: bool
    zones: List[GeoFenceOut] = []


class SyncPayload(BaseModel):
    ranger_id: uuid.UUID
    patrol_id: uuid.UUID
    breadcrumbs: Dict[str, Any] = Field(
        ..., description="GeoJSON FeatureCollection of offline breadcrumbs"
    )


class SyncStatusOut(BaseModel):
    patrol_id: uuid.UUID
    breadcrumb_count: int
    last_synced_timestamp: Optional[float] = None
    status: str = "OK"


class TokenRequest(BaseModel):
    callsign: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
