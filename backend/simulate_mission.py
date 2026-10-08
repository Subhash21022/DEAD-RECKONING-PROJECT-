"""
Full-pipeline mission simulation for DeadReckon AGY.

Two parallel streams:
  1. Scripted navigation -> Backend -> Dashboard (visible real-time movement)
  2. Synthetic IMU -> Edge Engine EKF + ONNX (proves models process data)

Run:  python simulate_mission.py
Watch: http://localhost:3000/live-tracking
"""
import asyncio
import math
import time
import random
import httpx
from datetime import datetime, timezone

EDGE_URL = "http://localhost:8001"
BACKEND_URL = "http://localhost:8000"
GRAVITY = 9.80665

# ── Scripted mission route with realistic transitions ──────────────────
MISSION = [
    # Phase 1: Vehicle patrol with GNSS
    {"lat": 12.9700, "lon": 77.5920, "speed_kmh": 18.0, "heading": 40.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 3.0,
     "is_outage": False, "label": "Vehicle start - GPS lock"},
    {"lat": 12.9706, "lon": 77.5926, "speed_kmh": 22.0, "heading": 42.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 3.0,
     "is_outage": False, "label": "Vehicle cruising NE"},
    {"lat": 12.9712, "lon": 77.5932, "speed_kmh": 26.0, "heading": 44.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 2.8,
     "is_outage": False, "label": "Vehicle accelerating"},
    {"lat": 12.9718, "lon": 77.5938, "speed_kmh": 30.0, "heading": 46.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 2.5,
     "is_outage": False, "label": "Vehicle fast cruise"},
    {"lat": 12.9724, "lon": 77.5944, "speed_kmh": 28.0, "heading": 48.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 2.8,
     "is_outage": False, "label": "Approaching forest canopy"},

    # Phase 2: GNSS degrades then lost - dead reckoning
    {"lat": 12.9730, "lon": 77.5950, "speed_kmh": 24.0, "heading": 50.0,
     "mode": "VEHICLE", "gnss_quality": "DEGRADED", "confidence_m": 5.0,
     "is_outage": False, "label": "GNSS degrading under canopy"},
    {"lat": 12.9736, "lon": 77.5955, "speed_kmh": 20.0, "heading": 52.0,
     "mode": "VEHICLE", "gnss_quality": "LOST", "confidence_m": 8.0,
     "is_outage": True, "label": "GNSS LOST - Dead Reckoning active"},
    {"lat": 12.9742, "lon": 77.5960, "speed_kmh": 18.0, "heading": 54.0,
     "mode": "VEHICLE", "gnss_quality": "LOST", "confidence_m": 11.0,
     "is_outage": True, "label": "DR: covariance growing"},
    {"lat": 12.9747, "lon": 77.5964, "speed_kmh": 14.0, "heading": 56.0,
     "mode": "VEHICLE", "gnss_quality": "LOST", "confidence_m": 14.0,
     "is_outage": True, "label": "DR: approaching checkpoint"},

    # Phase 3: Vehicle stops - ZUPT fires
    {"lat": 12.9750, "lon": 77.5966, "speed_kmh": 5.0,  "heading": 56.0,
     "mode": "VEHICLE", "gnss_quality": "LOST", "confidence_m": 15.0,
     "is_outage": True, "label": "Braking at checkpoint"},
    {"lat": 12.9750, "lon": 77.5966, "speed_kmh": 0.0,  "heading": 56.0,
     "mode": "STATIONARY", "gnss_quality": "LOST", "confidence_m": 15.0,
     "is_outage": True, "label": "ZUPT: stopped at checkpoint"},
    {"lat": 12.9750, "lon": 77.5966, "speed_kmh": 0.0,  "heading": 56.0,
     "mode": "STATIONARY", "gnss_quality": "LOST", "confidence_m": 15.0,
     "is_outage": True, "label": "ZUPT: velocity zeroed"},

    # Phase 4: Dismounted foot patrol - PEDESTRIAN mode
    {"lat": 12.9752, "lon": 77.5968, "speed_kmh": 4.5,  "heading": 60.0,
     "mode": "PEDESTRIAN", "gnss_quality": "LOST", "confidence_m": 16.0,
     "is_outage": True, "label": "Walking: jungle trail"},
    {"lat": 12.9754, "lon": 77.5970, "speed_kmh": 5.0,  "heading": 65.0,
     "mode": "PEDESTRIAN", "gnss_quality": "LOST", "confidence_m": 17.0,
     "is_outage": True, "label": "Walking: tracking signs"},
    {"lat": 12.9756, "lon": 77.5971, "speed_kmh": 4.8,  "heading": 72.0,
     "mode": "PEDESTRIAN", "gnss_quality": "LOST", "confidence_m": 18.0,
     "is_outage": True, "label": "Walking: dense undergrowth"},
    {"lat": 12.9758, "lon": 77.5972, "speed_kmh": 3.5,  "heading": 80.0,
     "mode": "PEDESTRIAN", "gnss_quality": "LOST", "confidence_m": 20.0,
     "is_outage": True, "label": "Walking: steep terrain"},
    {"lat": 12.9760, "lon": 77.5972, "speed_kmh": 4.2,  "heading": 88.0,
     "mode": "PEDESTRIAN", "gnss_quality": "LOST", "confidence_m": 22.0,
     "is_outage": True, "label": "Walking: heading east"},

    # Phase 5: GNSS reacquired in clearing
    {"lat": 12.9762, "lon": 77.5973, "speed_kmh": 4.0,  "heading": 85.0,
     "mode": "PEDESTRIAN", "gnss_quality": "DEGRADED", "confidence_m": 12.0,
     "is_outage": False, "label": "GNSS reacquiring in clearing"},
    {"lat": 12.9764, "lon": 77.5974, "speed_kmh": 4.5,  "heading": 80.0,
     "mode": "PEDESTRIAN", "gnss_quality": "GOOD", "confidence_m": 4.0,
     "is_outage": False, "label": "GPS lock restored"},
    {"lat": 12.9766, "lon": 77.5975, "speed_kmh": 4.0,  "heading": 78.0,
     "mode": "PEDESTRIAN", "gnss_quality": "GOOD", "confidence_m": 3.0,
     "is_outage": False, "label": "Walking with GPS - surveying"},

    # Phase 6: Stop to survey
    {"lat": 12.9766, "lon": 77.5975, "speed_kmh": 0.0,  "heading": 78.0,
     "mode": "STATIONARY", "gnss_quality": "GOOD", "confidence_m": 3.0,
     "is_outage": False, "label": "Stopped: surveying wildlife signs"},

    # Phase 7: Return drive
    {"lat": 12.9762, "lon": 77.5972, "speed_kmh": 15.0, "heading": 220.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 3.0,
     "is_outage": False, "label": "Vehicle return: heading SW"},
    {"lat": 12.9756, "lon": 77.5966, "speed_kmh": 25.0, "heading": 225.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 2.5,
     "is_outage": False, "label": "Vehicle return: cruising"},
    {"lat": 12.9748, "lon": 77.5958, "speed_kmh": 30.0, "heading": 228.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 2.5,
     "is_outage": False, "label": "Vehicle return: fast"},
    {"lat": 12.9740, "lon": 77.5950, "speed_kmh": 22.0, "heading": 230.0,
     "mode": "VEHICLE", "gnss_quality": "GOOD", "confidence_m": 2.8,
     "is_outage": False, "label": "Vehicle return: approaching base"},
]


def generate_imu_batch(mode: str, speed_kmh: float, heading: float, n: int = 100):
    """Generate a batch of synthetic IMU samples for edge engine processing."""
    speed_mps = speed_kmh / 3.6
    heading_rad = math.radians(heading)
    g_x, g_y, g_z = -0.0602 * GRAVITY, 0.9098 * GRAVITY, 0.4106 * GRAVITY
    t0 = time.time()
    samples = []

    for i in range(n):
        ts = t0 + i * 0.01
        if mode == "VEHICLE":
            vib = 1.5 + speed_mps * 0.08
            ax = g_x + random.gauss(0, vib * 0.3) + speed_mps * 0.02 * math.sin(heading_rad)
            ay = g_y + random.gauss(0, vib * 0.5)
            az = g_z + random.gauss(0, vib * 0.4)
            gx, gy, gz = random.gauss(0, 0.03), random.gauss(0, 0.03), random.gauss(0, 0.05)
        elif mode == "PEDESTRIAN":
            step = 2.5 * abs(math.sin(2 * math.pi * 1.8 * i * 0.01))
            ax = g_x + random.gauss(0, 0.5) + step * 0.2
            ay = g_y + random.gauss(0, 0.8) + step
            az = g_z + random.gauss(0, 0.6) + step * 0.3
            gx, gy, gz = random.gauss(0, 0.05), random.gauss(0, 0.04), random.gauss(0, 0.08)
        else:
            ax = g_x + random.gauss(0, 0.15)
            ay = g_y + random.gauss(0, 0.15)
            az = g_z + random.gauss(0, 0.15)
            gx, gy, gz = random.gauss(0, 0.008), random.gauss(0, 0.008), random.gauss(0, 0.008)

        samples.append({
            "timestamp_s": ts,
            "ax": round(ax, 4), "ay": round(ay, 4), "az": round(az, 4),
            "gx": round(gx, 5), "gy": round(gy, 5), "gz": round(gz, 5),
        })
    return samples


async def run_simulation():
    async with httpx.AsyncClient(timeout=10.0) as client:
        # ── Check services ──
        print("Checking services...")
        try:
            eh = (await client.get(f"{EDGE_URL}/health")).json()
            print(f"  Edge Engine : {eh['status']}  models_loaded={eh['models_loaded']}  samples={eh['samples_processed']}")
        except Exception as e:
            print(f"  Edge Engine : OFFLINE ({e})")
            eh = None

        bh = (await client.get(f"{BACKEND_URL}/health")).json()
        print(f"  Backend     : {bh['status']}  mode={bh['mode']}")

        total = len(MISSION)
        print(f"\n{'='*72}")
        print(f"  DEADRECKON AGY - LIVE MISSION SIMULATION ({total} waypoints)")
        print(f"  Dashboard: http://localhost:3000/live-tracking")
        print(f"{'='*72}")

        edge_samples = 0

        for i, wp in enumerate(MISSION, 1):
            mode_icon = {"VEHICLE": "[V]", "PEDESTRIAN": "[W]", "STATIONARY": "[S]"}.get(wp["mode"], "[?]")
            gnss_icon = {"GOOD": "GPS", "DEGRADED": "DEG", "LOST": "DR "}.get(wp["gnss_quality"], "???")

            print(f"\n  {i:2d}/{total}  {mode_icon} {wp['label']}")
            print(f"         {gnss_icon}  {wp['speed_kmh']:5.1f} km/h  hdg={wp['heading']:5.1f}  "
                  f"conf={wp['confidence_m']:5.1f}m  ({wp['lat']:.4f}, {wp['lon']:.4f})")

            # ── Stream 1: Send scripted nav to backend -> WebSocket -> Dashboard ──
            battery = max(50.0, 95.0 - i * 1.5)
            payload = {
                "mission_uid": "MISSION-PATROL-LIVE",
                "callsign": "RANGER-TIGER-04",
                "points": [{
                    "recorded_at": datetime.now(timezone.utc).isoformat(),
                    "latitude": wp["lat"],
                    "longitude": wp["lon"],
                    "speed_kmh": wp["speed_kmh"],
                    "heading_deg": wp["heading"],
                    "mode": wp["mode"],
                    "gnss_quality": wp["gnss_quality"],
                    "confidence_radius_m": wp["confidence_m"],
                    "is_outage": wp["is_outage"],
                    "battery_level": battery,
                }],
            }
            resp = await client.post(f"{BACKEND_URL}/api/v1/patrol/sync-batch", json=payload)
            if resp.status_code == 200:
                print(f"         -> Backend: OK (WebSocket broadcast)")
            else:
                print(f"         -> Backend: HTTP {resp.status_code}")

            # ── Stream 2: Send IMU batch to edge engine (proves ONNX models work) ──
            if eh:
                imu_batch = generate_imu_batch(wp["mode"], wp["speed_kmh"], wp["heading"])
                try:
                    er = await client.post(f"{EDGE_URL}/ingest/batch", json={"samples": imu_batch})
                    edge_results = er.json()
                    edge_samples += len(imu_batch)
                    if edge_results:
                        nav = edge_results[-1]
                        print(f"         -> Edge EKF: v={nav['speed_mps']:.2f} hdg={nav['heading_deg']:.1f} "
                              f"mode={nav['mode']} conf={nav['confidence_radius_m']:.1f}m")
                except Exception as e:
                    print(f"         -> Edge: error ({e})")

            # Pause for real-time viewing on dashboard
            await asyncio.sleep(2.0)

        # ── Final edge engine stats ──
        print(f"\n{'='*72}")
        print("  EDGE ENGINE ONNX MODEL PROOF")
        print(f"{'='*72}")

        if eh:
            final = (await client.get(f"{EDGE_URL}/health")).json()
            state = (await client.get(f"{EDGE_URL}/state")).json()
            cov = (await client.get(f"{EDGE_URL}/coverage")).json()
            print(f"  Samples processed  : {final['samples_processed']} (sent {edge_samples} this run)")
            print(f"  Models loaded      : {final['models_loaded']}")
            print(f"  EKF state vector   : {[round(x, 4) for x in state['state_vector']]}")
            print(f"  Covariance diag    : {[round(x, 6) for x in state['covariance_diagonal']]}")
            print(f"  Speed scale factor : {state['speed_scale_factor']}")
            print(f"  Coverage           : {cov['cells_visited']} cells, {cov['area_km2']} km2, {cov['total_distance_m']:.0f}m")
            print(f"  Current mode       : {state['mode']}")
            print(f"  GNSS quality       : {state['gnss_quality']}")

        # ── Trigger SOS ──
        print(f"\n{'='*72}")
        print("  TRIGGERING SOS EMERGENCY BEACON")
        print(f"{'='*72}")

        last_wp = MISSION[-1]
        sos = await client.post(f"{BACKEND_URL}/api/v1/patrol/sos-beacon", json={
            "mission_uid": "MISSION-PATROL-LIVE",
            "callsign": "RANGER-TIGER-04",
            "latitude": last_wp["lat"],
            "longitude": last_wp["lon"],
            "heading_deg": last_wp["heading"],
            "speed_kmh": 0.0,
            "battery_level": 52.0,
            "reason": "POACHER ACTIVITY DETECTED - Tiger corridor compromised",
        })
        sos_data = sos.json()
        print(f"  SOS alert ID: {sos_data.get('alert_id', 'N/A')}")
        print(f"  Location    : ({last_wp['lat']:.6f}, {last_wp['lon']:.6f})")
        print(f"  Status      : {sos_data.get('status', 'unknown')}")

        # Wait a moment for SOS to propagate to dashboard via WebSocket
        await asyncio.sleep(2.0)

        # ── Dashboard summary ──
        dash = (await client.get(f"{BACKEND_URL}/api/v1/patrol/dashboard")).json()
        rangers = (await client.get(f"{BACKEND_URL}/api/v1/telemetry/rangers")).json()
        alerts = (await client.get(f"{BACKEND_URL}/api/v1/alerts/list")).json()
        unresolved = [a for a in alerts if not a["is_resolved"]]

        print(f"\n{'='*72}")
        print("  DASHBOARD STATE")
        print(f"{'='*72}")
        print(f"  Active Rangers  : {dash['active_rangers']}")
        print(f"  Active Patrols  : {dash['active_patrols']}")
        print(f"  Active Alerts   : {len(unresolved)}")
        for r in rangers:
            print(f"  Ranger          : {r['callsign']} at ({r['lat']:.6f}, {r['lon']:.6f})")
            print(f"                    mode={r['mode']} speed={r['speed_kmh']}km/h gnss={r['gnss_quality']}")
            print(f"                    conf={r['confidence_radius_m']:.1f}m battery={r['battery_pct']}% sos={r['is_sos']}")
        for a in unresolved:
            print(f"  ACTIVE ALERT    : {a['alert_type']} - {a['message']}")

        print(f"\n{'='*72}")
        print("  SIMULATION COMPLETE")
        print("  Open http://localhost:3000/live-tracking  - see ranger + SOS banner")
        print("  Open http://localhost:3000/              - see overview stats")
        print("  Open http://localhost:3000/alerts        - see alert log")
        print("  Open http://localhost:3000/patrol-replay - replay patrol breadcrumbs")
        print(f"{'='*72}")


if __name__ == "__main__":
    asyncio.run(run_simulation())
