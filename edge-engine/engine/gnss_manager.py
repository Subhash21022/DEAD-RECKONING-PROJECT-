from enum import Enum
import numpy as np
from typing import Optional, Tuple

R_EARTH = 6378137.0

def haversine_dist(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = np.radians(lat1), np.radians(lat2)
    dphi = np.radians(lat2 - lat1)
    dlam = np.radians(lon2 - lon1)
    a = np.sin(dphi / 2.0) ** 2 + np.cos(phi1) * np.cos(phi2) * np.sin(dlam / 2.0) ** 2
    return float(2.0 * R_EARTH * np.arctan2(np.sqrt(a), np.sqrt(1.0 - a)))

class GNSSQuality(str, Enum):
    GOOD = "GOOD"
    DEGRADED = "DEGRADED"
    LOST = "LOST"

class GNSSManager:
    """
    Evaluates real-time satellite fix integrity and computes dynamic EKF covariance:
    - Rejects cold-start GPS teleportation jumps (>35 m/s jump)
    - GOOD (<= 10m): High-confidence GNSS correction
    - DEGRADED (10m - 30m): Inflated covariance (EKF trusts dead reckoning more)
    - LOST (> 30m or timeout): Pure autonomous Dead Reckoning
    """
    def __init__(
        self,
        good_threshold_m: float = 12.0,
        degraded_threshold_m: float = 100.0,
        max_fix_age_s: float = 2.0,
        base_speed_sigma_mps: float = 0.5,
    ):
        self.good_thresh = good_threshold_m
        self.degraded_thresh = degraded_threshold_m
        self.max_age = max_fix_age_s
        self.base_speed_sigma = base_speed_sigma_mps

        self.last_fix_time: Optional[float] = None
        self.last_lat: Optional[float] = None
        self.last_lon: Optional[float] = None
        self.last_speed: Optional[float] = None
        self.current_quality = GNSSQuality.LOST

    def evaluate_fix(
        self,
        timestamp_s: float,
        lat: Optional[float],
        lon: Optional[float],
        accuracy_m: Optional[float],
        speed_mps: Optional[float] = None,
        gnss_enabled: bool = True,
        satellites: Optional[int] = None,
    ) -> Tuple[GNSSQuality, Optional[np.ndarray], int]:
        """
        Evaluates GNSS health.
        Returns:
            quality: GNSSQuality (GOOD, DEGRADED, LOST)
            R_cov: (3, 3) measurement covariance matrix for [p_E, p_N, v], or None if LOST / no measurement.
            satellites_count: int
        """
        prev_quality = self.current_quality

        # Instant outage if user explicitly turned off location
        if not gnss_enabled:
            if prev_quality != GNSSQuality.LOST:
                print("[GNSS] Signal Lost (Location Services Disabled)")
            self.last_fix_time = None
            self.last_lat = None
            self.last_lon = None
            self.current_quality = GNSSQuality.LOST
            return GNSSQuality.LOST, None, 0

        # 1. Null / Missing check (No new GNSS fix in this sample)
        if lat is None or lon is None or accuracy_m is None or np.isnan(lat) or np.isnan(lon) or np.isnan(accuracy_m):
            if self.last_fix_time is not None and (timestamp_s - self.last_fix_time) <= self.max_age:
                # Still within valid fix window from previous fix, not an outage
                sat_count = satellites if satellites is not None else 8
                return self.current_quality, None, sat_count
            if prev_quality != GNSSQuality.LOST:
                print(f"[GNSS] Signal Lost (Timeout > {self.max_age}s)")
            self.current_quality = GNSSQuality.LOST
            return GNSSQuality.LOST, None, 0

        # Estimate satellite count if not provided directly by OS
        if satellites is not None:
            sat_count = satellites
        else:
            if accuracy_m <= 4.0:
                sat_count = 14
            elif accuracy_m <= 8.0:
                sat_count = 11
            elif accuracy_m <= 15.0:
                sat_count = 8
            elif accuracy_m <= 30.0:
                sat_count = 6
            elif accuracy_m <= 100.0:
                sat_count = 4
            else:
                sat_count = 2

        # 2. Teleportation speed check (>50 m/s ~ 180 km/h)
        if speed_mps is not None and speed_mps > 50.0:
            return self.current_quality, None, sat_count

        # 3. Position teleportation jump check (e.g. cold-start cell tower jump)
        if self.last_fix_time is not None and self.last_lat is not None and self.last_lon is not None:
            age = timestamp_s - self.last_fix_time
            if 0 < age < 10.0:
                jump_dist = haversine_dist(self.last_lat, self.last_lon, lat, lon)
                implied_speed = jump_dist / max(0.01, age)
                if jump_dist > 50.0 and implied_speed > 35.0: # >126 km/h unphysical jump
                    return self.current_quality, None, sat_count

        self.last_fix_time = timestamp_s
        self.last_lat = lat
        self.last_lon = lon
        self.last_speed = speed_mps

        # Structured Observability Logging
        print(f"[GNSS] Satellites: {sat_count}")
        print(f"[GNSS] Accuracy: {accuracy_m:.1f} m")

        # 4. Graduated quality categorization & covariance construction
        if accuracy_m <= self.good_thresh:
            self.current_quality = GNSSQuality.GOOD
            pos_sigma = max(1.5, float(accuracy_m))
            spd_sigma = self.base_speed_sigma
            R_cov = np.diag([pos_sigma ** 2, pos_sigma ** 2, spd_sigma ** 2]).astype(np.float32)
            return GNSSQuality.GOOD, R_cov, sat_count

        elif accuracy_m <= self.degraded_thresh:
            self.current_quality = GNSSQuality.DEGRADED
            pos_sigma = float(accuracy_m) * np.sqrt(8.0)
            spd_sigma = self.base_speed_sigma * 2.0
            R_cov = np.diag([pos_sigma ** 2, pos_sigma ** 2, spd_sigma ** 2]).astype(np.float32)
            return GNSSQuality.DEGRADED, R_cov, sat_count

        else:
            if prev_quality != GNSSQuality.LOST:
                print(f"[GNSS] Signal Lost (Accuracy {accuracy_m:.1f}m > threshold)")
            self.current_quality = GNSSQuality.LOST
            return GNSSQuality.LOST, None, sat_count
