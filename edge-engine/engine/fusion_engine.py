import os
import numpy as np
import onnxruntime as ort
from dataclasses import dataclass
from typing import Optional, Dict, Any, Tuple, List

from .sensor_preprocessor import SensorPreprocessor, ProcessedSample
from .pdr_detector import PDRDetector
from .mode_manager import ModeManager, NavigationMode
from .gnss_manager import GNSSManager, GNSSQuality
from .map_matcher import MapMatcher
from .zupt import ZUPTDetector

R_EARTH = 6378137.0

@dataclass
class NavigationState:
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
    confidence_radius_m: float     # 2-sigma 95% error ellipse semi-major axis (meters)
    is_stationary: bool            # True if zero-velocity update active
    is_ood: bool                   # Out-of-Distribution motion/terrain flag
    ood_entropy: float             # Softmax entropy (0.0 to 1.0)
    mode: str
    gnss_quality: str
    is_outage: bool
    # Observability & Debugging Framework:
    nav_system_state: str          # GNSS_AVAILABLE, GNSS_DEGRADED, GNSS_LOST, DEAD_RECKONING_ACTIVE, MAP_MATCHING_ACTIVE, RECOVERY_TO_GNSS
    last_transition: str           # e.g., "GNSS_AVAILABLE -> DEAD_RECKONING_ACTIVE"
    satellites_count: int
    gnss_accuracy_m: float
    model_running: bool
    model_speed_mps: float
    zupt_active: bool
    dr_lat: float
    dr_lon: float
    raw_gnss_lat: Optional[float]
    raw_gnss_lon: Optional[float]

class FusionEngine:
    """
    Universal 5-State Extended Kalman Filter (EKF) Fusion Engine:
    State: x = [p_E, p_N, v, psi, b_g]^T
      p_E: Local East position (m)
      p_N: Local North position (m)
      v  : Forward scalar velocity (m/s)
      psi: Heading clockwise from North (rad)
      b_g: Gyro yaw bias (rad/s)

    Integrated Capabilities:
    - ZUPT & ZARU: Velocity & Heading drift locking via engine/zupt.py
    - Confidence Radius: Dynamic 2-sigma error bounds extracted from EKF covariance P
    - OOD Detection: Softmax entropy gating for unmodeled vehicles / terrains
    - Multi-Modal: Seamless Vehicle TCN <-> Pedestrian Deep PDR transition
    """
    def __init__(
        self,
        classifier_onnx_path: str,
        speed_onnx_path: str,
        pedestrian_onnx_path: Optional[str] = None,
        origin_lat: Optional[float] = None,
        origin_lon: Optional[float] = None,
        initial_heading_rad: float = 0.0,
    ):
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

        self.sess_cls = ort.InferenceSession(classifier_onnx_path, opts)
        self.sess_spd = ort.InferenceSession(speed_onnx_path, opts)

        self.sess_ped = None
        if pedestrian_onnx_path and os.path.exists(pedestrian_onnx_path):
            self.sess_ped = ort.InferenceSession(pedestrian_onnx_path, opts)

        self.preprocessor = SensorPreprocessor(target_freq_hz=100.0)
        self.pdr = PDRDetector(sample_rate_hz=100.0)
        self.mode_mgr = ModeManager()
        self.gnss_mgr = GNSSManager()
        self.map_matcher = MapMatcher()
        self.zupt_detector = ZUPTDetector(sample_rate_hz=100.0)

        self.origin_lat = origin_lat
        self.origin_lon = origin_lon
        self.cos_lat0 = 1.0 if origin_lat is None else float(np.cos(np.radians(origin_lat)))
        self.heading_initialized = False

        # Phone Handlebar mounting default: g_down ≈ [-0.06, 0.91, 0.41]
        self.g_down = np.array([-0.0602, 0.9098, 0.4106], dtype=np.float64)
        self.g_down /= np.linalg.norm(self.g_down)

        # Online speed scale factor calibrated against pre-outage GNSS
        self.speed_scale_factor = 1.0

        # EKF State Vector [p_E, p_N, v, psi, b_g]
        self.x = np.array([0.0, 0.0, 0.0, initial_heading_rad, 0.0], dtype=np.float64)

        # Covariance Matrix P
        self.P = np.diag([
            5.0,     # p_E (m^2)
            5.0,     # p_N (m^2)
            1.0,     # v ((m/s)^2)
            0.05,    # psi (rad^2)
            1e-4,    # b_g ((rad/s)^2)
        ]).astype(np.float64)

        # Process Noise Q_base
        self.Q_base = np.diag([
            0.02,    # p_E
            0.02,    # p_N
            0.25,    # speed
            0.001,   # heading
            1e-7,    # gyro bias random walk
        ]).astype(np.float64)

        self.inference_step = 10
        self.sample_counter = 0
        self.current_tcn_speed = 0.0
        self.current_ped_speed = 0.0
        self.current_raw_class = 0

        # OOD states
        self.is_ood = False
        self.ood_entropy = 0.0
        self.is_stationary = False

        # State Machine & Observability Framework
        self.nav_system_state = "GNSS_LOST"
        self.last_transition = "INITIALIZATION -> GNSS_LOST"
        self.prev_is_stationary = False
        self.prev_is_snapped = False
        self.prev_gnss_qual = GNSSQuality.LOST
        self.x_dr = np.array([0.0, 0.0], dtype=np.float64) # Pure DR position [p_E, p_N] in local meters
        self.satellites_count = 0
        self.gnss_accuracy_m = 999.0
        self.model_running = False
        self.model_speed_mps = 0.0
        self.raw_gnss_lat: Optional[float] = None
        self.raw_gnss_lon: Optional[float] = None

    def load_trail_network(self, lats: List[float], lons: List[float]):
        self.map_matcher.load_trajectory_as_trail(lats, lons)

    def set_origin(self, lat: float, lon: float):
        self.origin_lat = lat
        self.origin_lon = lon
        self.cos_lat0 = float(np.cos(np.radians(lat)))

    def latlon_to_local(self, lat: float, lon: float) -> Tuple[float, float]:
        if self.origin_lat is None or self.origin_lon is None:
            self.set_origin(lat, lon)
            return 0.0, 0.0
        p_N = np.radians(lat - self.origin_lat) * R_EARTH
        p_E = np.radians(lon - self.origin_lon) * R_EARTH * self.cos_lat0
        return float(p_E), float(p_N)

    def local_to_latlon(self, p_E: float, p_N: float) -> Tuple[float, float]:
        if self.origin_lat is None or self.origin_lon is None:
            return 0.0, 0.0
        lat = self.origin_lat + np.degrees(p_N / R_EARTH)
        lon = self.origin_lon + np.degrees(p_E / (R_EARTH * self.cos_lat0))
        return float(lat), float(lon)

    def step(
        self,
        timestamp_s: float,
        ax: float,
        ay: float,
        az: float,
        gx: float,
        gy: float,
        gz: float,
        lat: Optional[float] = None,
        lon: Optional[float] = None,
        gnss_speed_mps: Optional[float] = None,
        gnss_accuracy_m: Optional[float] = None,
        gnss_bearing_deg: Optional[float] = None,
        gnss_enabled: bool = True,
        satellites: Optional[int] = None,
    ) -> NavigationState:
        # Fast heading initialization from compass / bearing
        if not self.heading_initialized and gnss_bearing_deg is not None and not np.isnan(gnss_bearing_deg) and gnss_bearing_deg >= 0:
            self.x[3] = (np.radians(gnss_bearing_deg) + np.pi) % (2 * np.pi) - np.pi
            self.heading_initialized = True

        # 1. Preprocess IMU
        sample = self.preprocessor.add_sample(
            timestamp_s, ax, ay, az, gx, gy, gz,
            lat, lon, gnss_speed_mps, gnss_accuracy_m, gnss_bearing_deg
        )
        dt = sample.dt
        self.sample_counter += 1

        # 2. GNSS Fix Evaluation with satellite tracking
        gnss_qual, R_gnss_pos, sat_count = self.gnss_mgr.evaluate_fix(
            timestamp_s, lat, lon, gnss_accuracy_m, gnss_speed_mps,
            gnss_enabled=gnss_enabled, satellites=satellites
        )
        is_outage = (gnss_qual == GNSSQuality.LOST)
        self.satellites_count = sat_count
        self.gnss_accuracy_m = float(gnss_accuracy_m) if gnss_accuracy_m is not None else (999.0 if is_outage else 15.0)
        self.raw_gnss_lat = lat
        self.raw_gnss_lon = lon

        # Immediate Origin Anchoring: Anchor to any valid satellite coordinate without delay
        if self.origin_lat is None and lat is not None and lon is not None:
            if abs(lat) > 0.01 or abs(lon) > 0.01:
                self.set_origin(lat, lon)
                self.x_dr = np.array([0.0, 0.0], dtype=np.float64)

        # 3. ZUPT / ZARU Stationary Detection
        self.is_stationary, stat_conf, g_down_refined, zaru_bias = self.zupt_detector.add_sample(
            sample.ax, sample.ay, sample.az,
            sample.gx, sample.gy, sample.gz,
            neural_speed_mps=self.x[2],
            neural_class=self.current_raw_class
        )
        self.g_down = g_down_refined
        if self.is_stationary and not self.prev_is_stationary:
            print("[ZUPT] Triggered")
        self.prev_is_stationary = self.is_stationary

        # 4. Neural Network Inference Cadence (10 Hz)
        self.model_running = False
        if self.is_stationary:
            self.current_raw_class = 0
            self.current_tcn_speed = 0.0
            self.current_ped_speed = 0.0
            self.model_speed_mps = 0.0
            self.is_ood = False
            self.ood_entropy = 0.0
        elif self.preprocessor.is_ready() and (self.sample_counter % self.inference_step == 0):
            self.model_running = True
            print("[MODEL] Inference Started")
            cls_window = self.preprocessor.get_classifier_window()
            raw_logits = self.sess_cls.run(None, {"imu_sequence": cls_window})[0]

            # Softmax & OOD Entropy calculation
            shifted = raw_logits[0] - np.max(raw_logits[0])
            exp_l = np.exp(shifted)
            probs = exp_l / np.sum(exp_l)

            # Normalized Shannon Entropy: H in [0, 1] for 4 classes
            entropy = -float(np.sum(probs * np.log(np.maximum(1e-9, probs)))) / np.log(4.0)
            max_prob = float(np.max(probs))
            self.ood_entropy = entropy
            self.is_ood = (max_prob < 0.60 or entropy > 0.85)

            self.current_raw_class = int(np.argmax(probs))

            # Predict Speed based on classified mode
            if self.current_raw_class in (1, 2): # Vehicle (Scooter / Car)
                tcn_window = self.preprocessor.get_tcn_window()
                tcn_pred = self.sess_spd.run(None, {"imu_window": tcn_window})[0][0, 0]
                raw_spd = max(0.0, float(tcn_pred))

                # Pre-outage Online Scale Factor Calibration against GNSS
                if gnss_qual == GNSSQuality.GOOD and gnss_speed_mps is not None and gnss_speed_mps > 3.0 and raw_spd > 3.0:
                    inst_ratio = float(np.clip(gnss_speed_mps / raw_spd, 0.70, 1.30))
                    self.speed_scale_factor = 0.98 * self.speed_scale_factor + 0.02 * inst_ratio

                # Speed Deadband Noise-Gate: clamp residual idle vibrations (< 2.7 km/h) to 0.0
                effective_spd = raw_spd * self.speed_scale_factor
                if effective_spd < 0.75:
                    effective_spd = 0.0
                self.current_tcn_speed = effective_spd
                self.model_speed_mps = effective_spd
                print(f"[MODEL] Speed Estimate = {effective_spd:.2f} m/s ({effective_spd * 3.6:.1f} km/h)")

            elif self.current_raw_class == 3 and self.sess_ped is not None: # Walking
                tcn_window = self.preprocessor.get_tcn_window()
                ped_pred = self.sess_ped.run(None, {"imu_window": tcn_window})[0][0, 0]
                raw_ped = max(0.0, float(ped_pred))
                self.current_ped_speed = raw_ped if raw_ped >= 0.40 else 0.0
                self.model_speed_mps = self.current_ped_speed
                print(f"[MODEL] Speed Estimate = {self.current_ped_speed:.2f} m/s ({self.current_ped_speed * 3.6:.1f} km/h)")

            elif self.current_raw_class == 0: # Stationary
                self.current_tcn_speed = 0.0
                self.current_ped_speed = 0.0
                self.model_speed_mps = 0.0

        # 5. Mode Management with Hysteresis
        if self.is_stationary:
            mode, mode_conf = self.mode_mgr.update(0)
            mode = NavigationMode.STATIONARY
            self.mode_mgr.current_mode = NavigationMode.STATIONARY
        else:
            mode, mode_conf = self.mode_mgr.update(self.current_raw_class)

        # Invariant Vertical Turn Rate projected on gravity vector
        raw_gyro = np.array([sample.gx, sample.gy, sample.gz], dtype=np.float64)
        omega_yaw = -float(np.dot(raw_gyro, self.g_down))

        # 6. EKF Time Update (Prediction)
        psi = self.x[3]
        bg = self.x[4]
        unbiased_yaw_rate = omega_yaw - bg

        # Always run PDR step detector on streaming accelerometer
        step_event = self.pdr.add_sample(sample.timestamp_s, sample.ax, sample.ay, sample.az)
        has_recent_steps = (self.pdr.last_step_time > 0 and (sample.timestamp_s - self.pdr.last_step_time) < 1.3)

        if self.is_stationary or mode == NavigationMode.STATIONARY:
            self.x[2] = 0.0
            v_input = 0.0
        elif mode == NavigationMode.VEHICLE:
            v_input = self.current_tcn_speed
            self.x[2] = 0.85 * self.x[2] + 0.15 * v_input
            dx = self.x[2] * np.sin(psi) * dt
            dy = self.x[2] * np.cos(psi) * dt
            self.x[0] += dx
            self.x[1] += dy
            self.x_dr[0] += dx
            self.x_dr[1] += dy
            self.x[3] += unbiased_yaw_rate * dt
        elif mode == NavigationMode.PEDESTRIAN:
            if not has_recent_steps:
                # No footstep taken in the last 1.3 seconds: PERSON IS STANDING STILL!
                self.x[2] = 0.0
                v_input = 0.0
                mode = NavigationMode.STATIONARY
                self.mode_mgr.current_mode = NavigationMode.STATIONARY
            elif step_event is not None:
                step_len, _ = step_event
                dx = step_len * np.sin(psi)
                dy = step_len * np.cos(psi)
                self.x[0] += dx
                self.x[1] += dy
                self.x_dr[0] += dx
                self.x_dr[1] += dy
                self.x[2] = step_len / 0.55  # ~ 1.2 m/s instantaneous speed
                self.x[3] += unbiased_yaw_rate * dt
            else:
                # Between footsteps: do NOT accumulate position. Heading only.
                self.x[2] = 0.85 * self.x[2]  # Decay speed smoothly toward 0
                self.x[3] += unbiased_yaw_rate * dt

        self.x[3] = (self.x[3] + np.pi) % (2 * np.pi) - np.pi

        # Jacobian F
        v_curr = self.x[2]
        F = np.eye(5, dtype=np.float64)
        F[0, 2] = np.sin(psi) * dt
        F[0, 3] = v_curr * np.cos(psi) * dt
        F[1, 2] = np.cos(psi) * dt
        F[1, 3] = -v_curr * np.sin(psi) * dt
        F[3, 4] = -dt

        # Scale Q if Out-of-Distribution to widen confidence radius
        Q = self.Q_base.copy()
        if self.is_ood:
            Q[0:3, 0:3] *= 3.0

        self.P = F @ self.P @ F.T + (Q * dt)

        # 7. ZUPT & ZARU EKF Measurement Updates
        if self.is_stationary:
            H_zupt = np.array([
                [0.0, 0.0, 1.0, 0.0, 0.0],
                [0.0, 0.0, 0.0, 0.0, 1.0],
            ], dtype=np.float64)
            R_zupt = np.diag([1e-4, 5e-4]) # Tight covariance for physical rest
            y_zupt = np.array([0.0 - self.x[2], omega_yaw - self.x[4]])

            S_z = H_zupt @ self.P @ H_zupt.T + R_zupt
            K_z = self.P @ H_zupt.T @ np.linalg.inv(S_z)
            K_z[0:2, :] = 0.0 # Strict invariant: zero position nudge during ZUPT/ZARU
            self.x += (K_z @ y_zupt)
            self.P = (np.eye(5) - K_z @ H_zupt) @ self.P
            self.x[2] = 0.0

        # 8. GNSS EKF Measurement Updates (When Not in Outage and fresh fix arrived)
        if not is_outage and lat is not None and lon is not None and R_gnss_pos is not None:
            z_E, z_N = self.latlon_to_local(lat, lon)
            z_v = gnss_speed_mps if gnss_speed_mps is not None else self.x[2]

            # Direct stationary anchor: when physically still or GNSS speed < 1.5 m/s
            if self.is_stationary or mode == NavigationMode.STATIONARY or (gnss_speed_mps is not None and gnss_speed_mps < 1.5):
                self.x[0] = z_E
                self.x[1] = z_N
                self.x[2] = 0.0
                self.P[0, 0] = min(self.P[0, 0], float(R_gnss_pos[0, 0]))
                self.P[1, 1] = min(self.P[1, 1], float(R_gnss_pos[1, 1]))
                self.P[2, 2] = 0.01
            else:
                can_fuse_heading = (
                    gnss_qual == GNSSQuality.GOOD
                    and z_v >= 2.0
                    and gnss_bearing_deg is not None
                    and not np.isnan(gnss_bearing_deg)
                )

                if can_fuse_heading:
                    gps_psi = np.radians(gnss_bearing_deg)
                    gps_psi = (gps_psi + np.pi) % (2 * np.pi) - np.pi

                    if not self.heading_initialized:
                        self.x[3] = gps_psi
                        self.heading_initialized = True

                    z = np.array([z_E, z_N, z_v, gps_psi], dtype=np.float64)
                    H = np.array([
                        [1.0, 0.0, 0.0, 0.0, 0.0],
                        [0.0, 1.0, 0.0, 0.0, 0.0],
                        [0.0, 0.0, 1.0, 0.0, 0.0],
                        [0.0, 0.0, 0.0, 1.0, 0.0],
                    ], dtype=np.float64)

                    R = np.zeros((4, 4), dtype=np.float64)
                    R[0:3, 0:3] = R_gnss_pos
                    R[3, 3] = (np.radians(3.0)) ** 2

                    y = z - (H @ self.x)
                    y[3] = (y[3] + np.pi) % (2 * np.pi) - np.pi

                    S = H @ self.P @ H.T + R
                    K = self.P @ H.T @ np.linalg.inv(S)
                    self.x += (K @ y)
                    self.P = (np.eye(5) - K @ H) @ self.P
                else:
                    z = np.array([z_E, z_N, z_v], dtype=np.float64)
                    H = np.array([
                        [1.0, 0.0, 0.0, 0.0, 0.0],
                        [0.0, 1.0, 0.0, 0.0, 0.0],
                        [0.0, 0.0, 1.0, 0.0, 0.0],
                    ], dtype=np.float64)
                    y = z - (H @ self.x)
                    S = H @ self.P @ H.T + R_gnss_pos
                    K = self.P @ H.T @ np.linalg.inv(S)
                    self.x += (K @ y)
                    self.P = (np.eye(5) - K @ H) @ self.P

            self.x[3] = (self.x[3] + np.pi) % (2 * np.pi) - np.pi

        # 9. Dynamic Confidence Radius (2-sigma 95% Error Ellipse Semi-Major Axis)
        eigvals = np.linalg.eigvalsh(self.P[0:2, 0:2])
        confidence_radius_m = float(2.0 * np.sqrt(max(1e-4, np.max(eigvals))))

        # 10. Coordinate Extraction & Map Matching
        cur_lat, cur_lon = self.local_to_latlon(self.x[0], self.x[1])
        heading_deg = float(np.degrees(self.x[3]) % 360.0)
        matched_lat, matched_lon, is_snapped = self.map_matcher.match(cur_lat, cur_lon, heading_deg)

        if is_snapped and not self.prev_is_snapped:
            print(f"[MAP] Road Matched: snapped to ({matched_lat:.6f}, {matched_lon:.6f})")
        self.prev_is_snapped = is_snapped

        # 11. State Machine Transitions
        prev_state = self.nav_system_state
        if gnss_qual == GNSSQuality.GOOD:
            if prev_state in ("DEAD_RECKONING_ACTIVE", "MAP_MATCHING_ACTIVE", "GNSS_LOST"):
                self.nav_system_state = "RECOVERY_TO_GNSS"
                self.last_transition = f"{prev_state} -> RECOVERY_TO_GNSS"
                print(f"[STATE] {self.last_transition}")
            else:
                if prev_state != "GNSS_AVAILABLE":
                    self.last_transition = f"{prev_state} -> GNSS_AVAILABLE"
                    print(f"[STATE] {self.last_transition}")
                self.nav_system_state = "GNSS_AVAILABLE"
        elif gnss_qual == GNSSQuality.DEGRADED:
            if prev_state != "GNSS_DEGRADED":
                self.last_transition = f"{prev_state} -> GNSS_DEGRADED"
                print(f"[STATE] {self.last_transition}")
            self.nav_system_state = "GNSS_DEGRADED"
        else: # GNSSQuality.LOST
            target_state = "MAP_MATCHING_ACTIVE" if is_snapped else "DEAD_RECKONING_ACTIVE"
            if prev_state != target_state:
                self.last_transition = f"{prev_state} -> {target_state}"
                print(f"[STATE] {self.last_transition}")
                if "DEAD_RECKONING" in target_state or prev_state in ("GNSS_AVAILABLE", "GNSS_DEGRADED", "RECOVERY_TO_GNSS"):
                    print("[MODE] Switching to DR")
            self.nav_system_state = target_state

        is_stat = self.is_stationary or mode == NavigationMode.STATIONARY
        mode_str = NavigationMode.STATIONARY.value if is_stat else ("UNKNOWN_OOD" if self.is_ood else mode.value)
        out_spd = 0.0 if is_stat else float(self.x[2])

        # Observability: Pure DR Lat/Lon
        dr_lat, dr_lon = self.local_to_latlon(self.x_dr[0], self.x_dr[1])

        # Fused position log cadence
        if self.sample_counter % 20 == 0:
            print(f"[FUSION] Position Updated: lat={cur_lat:.6f}, lon={cur_lon:.6f}, state={self.nav_system_state}")

        return NavigationState(
            timestamp_s=timestamp_s,
            lat=cur_lat,
            lon=cur_lon,
            matched_lat=matched_lat,
            matched_lon=matched_lon,
            is_snapped=is_snapped,
            pos_east_m=float(self.x[0]),
            pos_north_m=float(self.x[1]),
            speed_mps=out_spd,
            speed_kmh=float(out_spd * 3.6),
            heading_deg=heading_deg,
            gyro_bias_rads=float(self.x[4]),
            speed_scale_factor=float(self.speed_scale_factor),
            confidence_radius_m=confidence_radius_m,
            is_stationary=self.is_stationary,
            is_ood=self.is_ood,
            ood_entropy=float(self.ood_entropy),
            mode=mode_str,
            gnss_quality=gnss_qual.value,
            is_outage=is_outage,
            nav_system_state=self.nav_system_state,
            last_transition=self.last_transition,
            satellites_count=self.satellites_count,
            gnss_accuracy_m=self.gnss_accuracy_m,
            model_running=self.model_running,
            model_speed_mps=self.model_speed_mps,
            zupt_active=self.is_stationary,
            dr_lat=dr_lat,
            dr_lon=dr_lon,
            raw_gnss_lat=self.raw_gnss_lat,
            raw_gnss_lon=self.raw_gnss_lon,
        )
