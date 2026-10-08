import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, Float, Boolean, Integer, BigInteger, DateTime,
    ForeignKey, Enum as SAEnum, Index, text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from geoalchemy2 import Geometry
import enum

from .database import Base


class PatrolStatus(str, enum.Enum):
    ACTIVE = "ACTIVE"
    COMPLETED = "COMPLETED"
    ABORTED = "ABORTED"


class AlertType(str, enum.Enum):
    SOS = "SOS"
    DEAD_RANGER = "DEAD_RANGER"
    GEOFENCE_BREACH = "GEOFENCE_BREACH"
    POACHING_SUSPECTED = "POACHING_SUSPECTED"


class AlertSeverity(str, enum.Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"


class NavigationMode(str, enum.Enum):
    STATIONARY = "STATIONARY"
    VEHICLE = "VEHICLE"
    PEDESTRIAN = "PEDESTRIAN"


class ZoneType(str, enum.Enum):
    CORE_PROTECTED = "CORE_PROTECTED"
    BUFFER_ZONE = "BUFFER_ZONE"
    POACHING_RISK = "POACHING_RISK"


class Ranger(Base):
    __tablename__ = "rangers"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(128), nullable=False)
    callsign = Column(String(32), unique=True, nullable=False)
    badge_number = Column(String(32), unique=True, nullable=False)
    password_hash = Column(String(256), nullable=False, default="")
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    patrols = relationship("Patrol", back_populates="ranger", lazy="selectin")
    alerts = relationship("Alert", back_populates="ranger", lazy="selectin")
    sightings = relationship("WildlifeSighting", back_populates="ranger", lazy="selectin")


class Patrol(Base):
    __tablename__ = "patrols"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    ranger_id = Column(UUID(as_uuid=True), ForeignKey("rangers.id"), nullable=False)
    start_time = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    end_time = Column(DateTime(timezone=True), nullable=True)
    status = Column(SAEnum(PatrolStatus), default=PatrolStatus.ACTIVE, nullable=False)
    total_distance_m = Column(Float, default=0.0)
    coverage_km2 = Column(Float, default=0.0)
    breadcrumb_count = Column(Integer, default=0)

    ranger = relationship("Ranger", back_populates="patrols")
    breadcrumbs = relationship("Breadcrumb", back_populates="patrol", lazy="selectin", order_by="Breadcrumb.timestamp_s")
    alerts = relationship("Alert", back_populates="patrol", lazy="selectin")


class Breadcrumb(Base):
    __tablename__ = "breadcrumbs"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    patrol_id = Column(UUID(as_uuid=True), ForeignKey("patrols.id"), nullable=False, index=True)
    timestamp_s = Column(Float, nullable=False)
    position = Column(Geometry("POINT", srid=4326), nullable=False)
    speed_kmh = Column(Float, default=0.0)
    heading_deg = Column(Float, default=0.0)
    mode = Column(SAEnum(NavigationMode), default=NavigationMode.STATIONARY)
    confidence_m = Column(Float, default=5.0)
    is_outage = Column(Boolean, default=False)
    is_snapped = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    patrol = relationship("Patrol", back_populates="breadcrumbs")

    __table_args__ = (
        Index("idx_breadcrumb_position", position, postgresql_using="gist"),
        Index("idx_breadcrumb_patrol_ts", patrol_id, timestamp_s),
    )


class GeoFence(Base):
    __tablename__ = "geofences"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(128), nullable=False)
    zone_type = Column(SAEnum(ZoneType), default=ZoneType.CORE_PROTECTED, nullable=False)
    boundary = Column(Geometry("POLYGON", srid=4326), nullable=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    __table_args__ = (
        Index("idx_geofence_boundary", boundary, postgresql_using="gist"),
    )


class Alert(Base):
    __tablename__ = "alerts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    ranger_id = Column(UUID(as_uuid=True), ForeignKey("rangers.id"), nullable=False)
    patrol_id = Column(UUID(as_uuid=True), ForeignKey("patrols.id"), nullable=True)
    alert_type = Column(SAEnum(AlertType), nullable=False)
    severity = Column(SAEnum(AlertSeverity), default=AlertSeverity.HIGH, nullable=False)
    position = Column(Geometry("POINT", srid=4326), nullable=False)
    heading_deg = Column(Float, default=0.0)
    message = Column(String(512), default="")
    battery_pct = Column(Float, nullable=True)
    path_geojson = Column(String, nullable=True)
    resolved = Column(Boolean, default=False)
    resolved_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    ranger = relationship("Ranger", back_populates="alerts")
    patrol = relationship("Patrol", back_populates="alerts")


class WildlifeSighting(Base):
    __tablename__ = "wildlife_sightings"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    ranger_id = Column(UUID(as_uuid=True), ForeignKey("rangers.id"), nullable=False)
    patrol_id = Column(UUID(as_uuid=True), ForeignKey("patrols.id"), nullable=True)
    species = Column(String(64), nullable=False)
    count = Column(Integer, default=1)
    position = Column(Geometry("POINT", srid=4326), nullable=False)
    description = Column(String(512), default="")
    photo_url = Column(String(512), nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    ranger = relationship("Ranger", back_populates="sightings")

    __table_args__ = (
        Index("idx_sighting_position", position, postgresql_using="gist"),
    )
