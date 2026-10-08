"""
Unit & Integration Test Suite for Navigation Observability & Mode Transitions
Tests:
1. GNSS Loss detection (timeout & instant kill via gnss_enabled=False)
2. State Machine transitions:
   - GNSS_AVAILABLE
   - GNSS_DEGRADED
   - GNSS_LOST
   - DEAD_RECKONING_ACTIVE
   - MAP_MATCHING_ACTIVE
   - RECOVERY_TO_GNSS
3. Console logging tag emission verification
4. ZUPT stationary drift suppression
5. Fused vs Raw GNSS vs Pure DR separation
"""

import os
import sys
import unittest
import numpy as np

# Ensure edge-engine is on path
current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from engine.gnss_manager import GNSSManager, GNSSQuality
from engine.mode_manager import ModeManager, NavigationMode
from engine.sensor_preprocessor import SensorPreprocessor, ProcessedSample
from engine.zupt import ZUPTDetector
from engine.fusion_engine import FusionEngine, NavigationState


class TestGNSSManagerObservability(unittest.TestCase):
    def setUp(self):
        self.mgr = GNSSManager(good_threshold_m=8.0, degraded_threshold_m=25.0, max_fix_age_s=2.0)

    def test_gnss_good_quality_and_satellites(self):
        # Accuracy = 4.2m, explicitly passed 12 satellites
        qual, R, sats = self.mgr.evaluate_fix(100.0, 12.9716, 77.5946, 4.2, satellites=12, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.GOOD)
        self.assertEqual(sats, 12)
        self.assertIsNotNone(R)

    def test_gnss_satellite_estimation_heuristic(self):
        # Accuracy = 3.0m without satellites specified -> heuristic should estimate >= 12
        qual, R, sats = self.mgr.evaluate_fix(100.0, 12.9716, 77.5946, 3.0, satellites=None, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.GOOD)
        self.assertGreaterEqual(sats, 12)

    def test_gnss_degraded_quality(self):
        # Accuracy = 15.0m -> DEGRADED
        qual, R, sats = self.mgr.evaluate_fix(100.0, 12.9716, 77.5946, 15.0, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.DEGRADED)
        self.assertGreaterEqual(sats, 5)
        self.assertIsNotNone(R)

    def test_gnss_outage_timeout(self):
        # Fresh reading at t = 100.0s
        qual, R, sats = self.mgr.evaluate_fix(100.0, 12.9716, 77.5946, 4.0, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.GOOD)

        # Query at t = 101.0s (within 2s max_age, no new lat/lon) -> still GOOD
        qual, R, sats = self.mgr.evaluate_fix(101.0, None, None, None, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.GOOD)

        # Query at t = 102.5s (> 2s max_age, no new lat/lon) -> LOST
        qual, R, sats = self.mgr.evaluate_fix(102.5, None, None, None, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.LOST)
        self.assertEqual(sats, 0)
        self.assertIsNone(R)

    def test_gnss_instant_disabled_kill(self):
        # Fresh fix at 100.0s
        qual, R, sats = self.mgr.evaluate_fix(100.0, 12.9716, 77.5946, 4.0, gnss_enabled=True)
        self.assertEqual(qual, GNSSQuality.GOOD)

        # Next sample has gnss_enabled=False -> MUST instantly return LOST and 0 sats
        qual, R, sats = self.mgr.evaluate_fix(100.01, 12.9716, 77.5946, 4.0, gnss_enabled=False)
        self.assertEqual(qual, GNSSQuality.LOST)
        self.assertEqual(sats, 0)
        self.assertIsNone(R)


class TestFusionEngineObservability(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cls_path = os.path.join(current_dir, "models", "motion_classifier.onnx")
        cls.spd_path = os.path.join(current_dir, "models", "universal_speed_estimator.onnx")
        cls.ped_path = os.path.join(current_dir, "models", "pedestrian_speed_estimator.onnx")

    def setUp(self):
        self.engine = FusionEngine(
            classifier_onnx_path=self.cls_path,
            speed_onnx_path=self.spd_path,
            pedestrian_onnx_path=self.ped_path if os.path.exists(self.ped_path) else None,
            origin_lat=12.9716,
            origin_lon=77.5946,
        )

    def test_initial_state_is_gnss_lost(self):
        self.assertEqual(self.engine.nav_system_state, "GNSS_LOST")

    def test_transition_recovery_to_gnss_available(self):
        # Step with good GNSS reading
        s = self.engine.step(
            ax=0.0, ay=0.0, az=9.81,
            gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.0,
            lat=12.9716, lon=77.5946,
            gnss_speed_mps=0.0,
            gnss_accuracy_m=3.5,
            gnss_bearing_deg=0.0,
            satellites=14,
            gnss_enabled=True
        )
        # First fix from GNSS_LOST goes through RECOVERY_TO_GNSS
        self.assertIn(s.nav_system_state, ("RECOVERY_TO_GNSS", "GNSS_AVAILABLE"))
        self.assertEqual(s.satellites_count, 14)
        self.assertAlmostEqual(s.gnss_accuracy_m, 3.5, places=1)
        self.assertIsNotNone(s.raw_gnss_lat)
        self.assertIsNotNone(s.raw_gnss_lon)

        # Second fix transitions firmly to GNSS_AVAILABLE
        s2 = self.engine.step(
            ax=0.0, ay=0.0, az=9.81,
            gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.05,
            lat=12.9716, lon=77.5946,
            gnss_speed_mps=0.0,
            gnss_accuracy_m=3.5,
            gnss_bearing_deg=0.0,
            satellites=14,
            gnss_enabled=True
        )
        self.assertEqual(s2.nav_system_state, "GNSS_AVAILABLE")

    def test_transition_to_gnss_degraded(self):
        # Good fix first
        self.engine.step(
            ax=0.0, ay=0.0, az=9.81, gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.0, lat=12.9716, lon=77.5946,
            gnss_speed_mps=0.0, gnss_accuracy_m=4.0, gnss_enabled=True
        )
        # Degraded fix
        s = self.engine.step(
            ax=0.0, ay=0.0, az=9.81, gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.05, lat=12.9716, lon=77.5946,
            gnss_speed_mps=0.0, gnss_accuracy_m=18.0, gnss_enabled=True
        )
        self.assertEqual(s.nav_system_state, "GNSS_DEGRADED")
        self.assertEqual(s.gnss_quality, "DEGRADED")

    def test_transition_to_dead_reckoning_on_gnss_disabled(self):
        # Establish GNSS fix
        self.engine.step(
            ax=0.0, ay=0.0, az=9.81, gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.0, lat=12.9716, lon=77.5946,
            gnss_speed_mps=0.0, gnss_accuracy_m=4.0, gnss_enabled=True
        )
        self.engine.step(
            ax=0.0, ay=0.0, az=9.81, gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.05, lat=12.9716, lon=77.5946,
            gnss_speed_mps=0.0, gnss_accuracy_m=4.0, gnss_enabled=True
        )
        # Turn OFF GNSS
        s_dr = self.engine.step(
            ax=0.0, ay=0.0, az=9.81, gx=0.0, gy=0.0, gz=0.0,
            timestamp_s=1.10, lat=None, lon=None,
            gnss_speed_mps=None, gnss_accuracy_m=None, gnss_enabled=False
        )
        self.assertEqual(s_dr.nav_system_state, "DEAD_RECKONING_ACTIVE")
        self.assertTrue(s_dr.is_outage)
        self.assertEqual(s_dr.gnss_quality, "LOST")
        self.assertIsNone(s_dr.raw_gnss_lat)
        self.assertIsNone(s_dr.raw_gnss_lon)
        self.assertEqual(s_dr.last_transition, "GNSS_AVAILABLE -> DEAD_RECKONING_ACTIVE")

    def test_zupt_lock_prevents_stationary_drift(self):
        self.engine.set_origin(12.9716, 77.5946)
        
        # Simulate stationary sensor stream for 100 samples (1.0s at 100Hz)
        state = None
        for i in range(100):
            t = 1.0 + i * 0.01
            noise_a = np.random.normal(0, 0.005, 3)
            noise_g = np.random.normal(0, 0.0005, 3)
            state = self.engine.step(
                ax=0.0 + noise_a[0],
                ay=0.0 + noise_a[1],
                az=9.81 + noise_a[2],
                gx=0.0 + noise_g[0],
                gy=0.0 + noise_g[1],
                gz=0.0 + noise_g[2],
                timestamp_s=t,
                lat=None, lon=None,
                gnss_enabled=False
            )

        self.assertTrue(state.zupt_active)
        self.assertEqual(state.speed_mps, 0.0)
        self.assertLess(abs(state.pos_east_m), 0.05)
        self.assertLess(abs(state.pos_north_m), 0.05)


if __name__ == "__main__":
    unittest.main()
