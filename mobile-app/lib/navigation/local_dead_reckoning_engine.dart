import 'dart:math';
import 'phone_calibration_service.dart';
import 'gnss_quality_manager.dart';
import 'motion_classifier_manager.dart';
import 'zupt_detector.dart';
import 'pdr_detector.dart';
import 'map_matcher.dart';

class LocalNavigationOutput {
  final double timestampS;
  final double lat;
  final double lon;
  final double matchedLat;
  final double matchedLon;
  final bool isSnapped;
  final double posEastM;
  final double posNorthM;
  final double speedMps;
  final double speedKmh;
  final double headingDeg;
  final double gyroBiasRads;
  final double speedScaleFactor;
  final double confidenceRadiusM;
  final bool isStationary;
  final bool isOod;
  final double oodEntropy;
  final bool zuptActive;
  final MotionMode motionMode;
  final GnssState gnssState;
  final String navPipeline;
  final double drLat;
  final double drLon;
  final double modelSpeedMps;

  const LocalNavigationOutput({
    required this.timestampS,
    required this.lat,
    required this.lon,
    required this.matchedLat,
    required this.matchedLon,
    required this.isSnapped,
    required this.posEastM,
    required this.posNorthM,
    required this.speedMps,
    required this.speedKmh,
    required this.headingDeg,
    required this.gyroBiasRads,
    required this.speedScaleFactor,
    required this.confidenceRadiusM,
    required this.isStationary,
    required this.isOod,
    required this.oodEntropy,
    required this.zuptActive,
    required this.motionMode,
    required this.gnssState,
    required this.navPipeline,
    required this.drLat,
    required this.drLon,
    required this.modelSpeedMps,
  });
}

/// Full 5-State Extended Kalman Filter running 100% on-device.
///
/// State vector: x = [p_E, p_N, v, psi, b_g]^T
///   p_E : East position (m) in local tangent frame
///   p_N : North position (m) in local tangent frame
///   v   : Forward scalar velocity (m/s)
///   psi : Heading clockwise from North (rad)
///   b_g : Gyroscope yaw bias (rad/s)
///
/// Integrates: ZUPT/ZARU, PDR step detection, GNSS fusion with
/// graduated covariance, speed scale calibration, OOD inflation,
/// and map matching.
class LocalDeadReckoningEngine {
  static const double _rEarth = 6378137.0;
  static const int _n = 5;

  double? _originLat;
  double? _originLon;
  double _cosLat0 = 1.0;
  bool _headingInitialized = false;

  // State vector [p_E, p_N, v, psi, b_g]
  final List<double> _x = List.filled(_n, 0.0);

  // Full 5x5 covariance matrix (row-major flat array, length 25)
  final List<double> _P = List.filled(_n * _n, 0.0);

  // Process noise diagonal
  static const List<double> _qDiag = [0.02, 0.02, 0.25, 0.001, 1e-7];

  // Pure DR trajectory (no GNSS corrections)
  double _drEast = 0.0;
  double _drNorth = 0.0;

  double _lastTimestampS = 0.0;
  double speedScaleFactor = 1.0;

  // Sub-components
  final ZuptDetector _zupt = ZuptDetector();
  final PDRDetector _pdr = PDRDetector();
  final MapMatcher _mapMatcher = MapMatcher();

  bool _isOod = false;
  double _oodEntropy = 0.0;
  double _modelSpeedMps = 0.0;

  int _sampleCounter = 0;

  LocalDeadReckoningEngine() {
    _initCovariance();
  }

  ZuptDetector get zuptDetector => _zupt;
  PDRDetector get pdrDetector => _pdr;
  MapMatcher get mapMatcher => _mapMatcher;

  void _initCovariance() {
    for (int i = 0; i < _n * _n; i++) _P[i] = 0.0;
    _P[0 * _n + 0] = 5.0;  // p_E
    _P[1 * _n + 1] = 5.0;  // p_N
    _P[2 * _n + 2] = 1.0;  // v
    _P[3 * _n + 3] = 0.05; // psi
    _P[4 * _n + 4] = 1e-4; // b_g
  }

  void initializeOrigin(double lat, double lon, double initialHeadingDeg) {
    _originLat = lat;
    _originLon = lon;
    _cosLat0 = cos(lat * (pi / 180.0));
    _x[0] = 0.0; _x[1] = 0.0; _x[2] = 0.0;
    _x[3] = initialHeadingDeg * (pi / 180.0);
    _x[4] = 0.0;
    _drEast = 0.0;
    _drNorth = 0.0;
    _headingInitialized = initialHeadingDeg.abs() > 0.01;
    _initCovariance();
    _P[0 * _n + 0] = 3.0;
    _P[1 * _n + 1] = 3.0;
    _P[2 * _n + 2] = 0.5;
    _P[3 * _n + 3] = 0.02;
    _P[4 * _n + 4] = 1e-5;
  }

  void initializeFromCalibration(CalibrationProfile cal) {
    _zupt.initFromCalibration(cal);
  }

  void loadTrailNetwork(List<double> lats, List<double> lons) {
    _mapMatcher.loadTrajectoryAsTrail(lats, lons);
  }

  LocalNavigationOutput step({
    required double timestampS,
    required double ax,
    required double ay,
    required double az,
    required double gx,
    required double gy,
    required double gz,
    required CalibrationProfile calibration,
    required MotionClassificationResult motion,
    required GnssQualityReport gnssReport,
    double? neuralVehicleSpeedMps,
    bool isOod = false,
    double oodEntropy = 0.0,
  }) {
    _sampleCounter++;
    _isOod = isOod;
    _oodEntropy = oodEntropy;

    // Auto-anchor origin from first valid GNSS
    if (_originLat == null) {
      final initLat = gnssReport.latestReading?.lat ?? 12.9700;
      final initLon = gnssReport.latestReading?.lon ?? 77.5920;
      final initHdg = gnssReport.bearingDeg;
      initializeOrigin(initLat, initLon, initHdg);
    }

    // Fast heading initialization from GNSS bearing
    if (!_headingInitialized && gnssReport.bearingDeg > 0.01) {
      _x[3] = gnssReport.bearingDeg * (pi / 180.0);
      _x[3] = _wrapAngle(_x[3]);
      _headingInitialized = true;
    }

    double dt = _lastTimestampS > 0.0 ? (timestampS - _lastTimestampS) : 0.01;
    if (dt <= 0.001 || dt > 0.5) dt = 0.01;
    _lastTimestampS = timestampS;

    // --- 1. ZUPT / ZARU detection (runs every sample) ---
    final zuptResultOrNull = _zupt.addSample(
      ax, ay, az, gx, gy, gz,
      neuralSpeedMps: _x[2].abs(),
      neuralClass: motion.mode == MotionMode.stationary ? 0 : null,
    );
    final zuptStationary = zuptResultOrNull?.isStationary ?? false;

    // --- 2. PDR step detection (runs every sample) ---
    final stepEvent = _pdr.addSample(timestampS, ax, ay, az);
    final hasRecentSteps = _pdr.lastStepTime > 0 &&
        (timestampS - _pdr.lastStepTime) < 1.3;

    // --- 3. Tilt-invariant yaw rate ---
    final gDown = zuptResultOrNull?.gDown ?? calibration.gDown;
    final omegaYaw = -(gx * gDown[0] + gy * gDown[1] + gz * gDown[2]);
    final unbiasedYawRate = omegaYaw - _x[4];

    // --- 4. Mode-dependent prediction ---
    final psi = _x[3];
    bool zuptActive = false;
    String navPipeline = 'DEAD RECKONING';
    final effectiveMode = zuptStationary
        ? MotionMode.stationary
        : motion.mode;

    if (effectiveMode == MotionMode.stationary || motion.physicalStillness) {
      _x[2] = 0.0;
      zuptActive = true;
      navPipeline = 'ZUPT HOLD';
    } else if (effectiveMode == MotionMode.vehicle) {
      final vRaw = neuralVehicleSpeedMps ??
          (gnssReport.speedMps > 0.5 ? gnssReport.speedMps : _x[2]);
      final effective = (vRaw * speedScaleFactor);
      final vInput = effective < 0.75 ? 0.0 : effective;
      _x[2] = 0.85 * _x[2] + 0.15 * vInput;
      _modelSpeedMps = vInput;

      final dx = _x[2] * sin(psi) * dt;
      final dy = _x[2] * cos(psi) * dt;
      _x[0] += dx;
      _x[1] += dy;
      _drEast += dx;
      _drNorth += dy;
      _x[3] += unbiasedYawRate * dt;
      navPipeline = 'IDR ACTIVE';

      // Online speed scale calibration against GNSS
      if (gnssReport.state == GnssState.good &&
          gnssReport.speedMps > 3.0 &&
          vRaw > 3.0 &&
          neuralVehicleSpeedMps != null &&
          neuralVehicleSpeedMps > 3.0) {
        final instRatio = (gnssReport.speedMps / neuralVehicleSpeedMps)
            .clamp(0.70, 1.30);
        speedScaleFactor = 0.98 * speedScaleFactor + 0.02 * instRatio;
      }
    } else if (effectiveMode == MotionMode.walking) {
      if (!hasRecentSteps) {
        _x[2] = 0.0;
        navPipeline = 'ZUPT HOLD';
        zuptActive = true;
      } else if (stepEvent != null) {
        final stepLen = stepEvent.stepLengthM;
        final dx = stepLen * sin(psi);
        final dy = stepLen * cos(psi);
        _x[0] += dx;
        _x[1] += dy;
        _drEast += dx;
        _drNorth += dy;
        _x[2] = stepLen / 0.55;
        _x[3] += unbiasedYawRate * dt;
        _modelSpeedMps = _x[2];
      } else {
        _x[2] *= 0.85;
        _x[3] += unbiasedYawRate * dt;
      }
      if (!zuptActive) navPipeline = 'PDR ACTIVE';
    } else {
      // UNKNOWN: decay speed
      _x[2] *= 0.95;
      _x[3] += unbiasedYawRate * dt;
      navPipeline = 'HOLD (UNKNOWN)';
    }

    _x[3] = _wrapAngle(_x[3]);

    // --- 5. EKF Covariance Prediction: P = F * P * F^T + Q * dt ---
    final vCurr = _x[2];
    // Build Jacobian F (5x5 identity + partials)
    final f = _eye5();
    f[0 * _n + 2] = sin(psi) * dt;          // dp_E/dv
    f[0 * _n + 3] = vCurr * cos(psi) * dt;  // dp_E/dpsi
    f[1 * _n + 2] = cos(psi) * dt;          // dp_N/dv
    f[1 * _n + 3] = -vCurr * sin(psi) * dt; // dp_N/dpsi
    f[3 * _n + 4] = -dt;                     // dpsi/db_g

    // Q diagonal, scaled by dt; inflate 3x for OOD
    final q = List.filled(_n * _n, 0.0);
    for (int i = 0; i < _n; i++) {
      var qi = _qDiag[i] * dt;
      if (_isOod && i < 3) qi *= 3.0;
      q[i * _n + i] = qi;
    }

    // P = F * P * F^T + Q
    final fpft = _matMulAdd5(f, _P, q);
    for (int i = 0; i < _n * _n; i++) _P[i] = fpft[i];

    // --- 6. ZUPT/ZARU Measurement Update ---
    if (zuptActive) {
      // H = [[0,0,1,0,0],[0,0,0,0,1]], z=[0,0], h(x)=[v, b_g]
      // y = [0 - v, omega - b_g]
      final yV = 0.0 - _x[2];
      final yB = omegaYaw - _x[4];
      final rV = 1e-4;
      final rB = 5e-4;

      // Kalman gain for velocity (row 2 of state)
      final sV = _P[2 * _n + 2] + rV;
      if (sV > 1e-12) {
        final kCol = List<double>.generate(_n, (i) => _P[i * _n + 2] / sV);
        // Zero position nudge during ZUPT
        kCol[0] = 0.0;
        kCol[1] = 0.0;
        for (int i = 0; i < _n; i++) _x[i] += kCol[i] * yV;
        // Joseph form: P = (I - K*H) * P
        for (int i = 0; i < _n; i++) {
          for (int j = 0; j < _n; j++) {
            _P[i * _n + j] -= kCol[i] * _P[2 * _n + j];
          }
        }
      }

      // Kalman gain for gyro bias (row 4 of state)
      final sB = _P[4 * _n + 4] + rB;
      if (sB > 1e-12) {
        final kCol = List<double>.generate(_n, (i) => _P[i * _n + 4] / sB);
        kCol[0] = 0.0;
        kCol[1] = 0.0;
        for (int i = 0; i < _n; i++) _x[i] += kCol[i] * yB;
        for (int i = 0; i < _n; i++) {
          for (int j = 0; j < _n; j++) {
            _P[i * _n + j] -= kCol[i] * _P[4 * _n + j];
          }
        }
      }

      _x[2] = 0.0; // Hard clamp velocity
    }

    // --- 7. GNSS Measurement Update (graduated by quality) ---
    final gnssLat = gnssReport.latestReading?.lat;
    final gnssLon = gnssReport.latestReading?.lon;
    final gnssState = gnssReport.state;

    if (gnssState != GnssState.lost &&
        gnssLat != null && gnssLon != null &&
        _originLat != null) {
      final zE = (gnssLon - _originLon!) * (pi / 180.0) * _rEarth * _cosLat0;
      final zN = (gnssLat - _originLat!) * (pi / 180.0) * _rEarth;
      final zV = gnssReport.speedMps;
      final acc = gnssReport.accuracyM;

      // Compute measurement covariance based on quality
      double posSigma;
      double spdSigma;
      if (gnssState == GnssState.good) {
        posSigma = max(1.5, acc);
        spdSigma = 0.5;
        navPipeline = 'GNSS+INS';
      } else if (gnssState == GnssState.recovering) {
        posSigma = max(3.0, acc * 2.0);
        spdSigma = 1.5;
        navPipeline = 'GNSS RECOVERING';
      } else {
        // DEGRADED
        posSigma = acc * sqrt(8.0);
        spdSigma = 1.0;
        navPipeline = 'WEAK GNSS+DR';
      }

      final isStationaryOrSlow = zuptActive ||
          effectiveMode == MotionMode.stationary ||
          (zV < 1.5);

      if (isStationaryOrSlow) {
        // Direct anchor when stationary
        _x[0] = zE;
        _x[1] = zN;
        _x[2] = 0.0;
        _P[0 * _n + 0] = min(_P[0 * _n + 0], posSigma * posSigma);
        _P[1 * _n + 1] = min(_P[1 * _n + 1], posSigma * posSigma);
        _P[2 * _n + 2] = 0.01;
      } else {
        // Moving: check if we can fuse heading
        final canFuseHeading = gnssState == GnssState.good &&
            zV >= 2.0 &&
            gnssReport.bearingDeg > 0.01;

        if (canFuseHeading) {
          var gpsPsi = gnssReport.bearingDeg * (pi / 180.0);
          gpsPsi = _wrapAngle(gpsPsi);

          if (!_headingInitialized) {
            _x[3] = gpsPsi;
            _headingInitialized = true;
          }

          // 4-measurement update: [p_E, p_N, v, psi]
          _gnssUpdate4(zE, zN, zV, gpsPsi, posSigma, spdSigma);
        } else {
          // 3-measurement update: [p_E, p_N, v]
          _gnssUpdate3(zE, zN, zV, posSigma, spdSigma);
        }
      }

      _x[3] = _wrapAngle(_x[3]);
    }

    // --- 8. Convert to lat/lon ---
    final curLat = _originLat! + (_x[1] / _rEarth) * (180.0 / pi);
    final curLon = _originLon! + (_x[0] / (_rEarth * _cosLat0)) * (180.0 / pi);
    final drLat = _originLat! + (_drNorth / _rEarth) * (180.0 / pi);
    final drLon = _originLon! + (_drEast / (_rEarth * _cosLat0)) * (180.0 / pi);

    // --- 9. Confidence radius: 2-sigma from position covariance eigenvalues ---
    final confRadius = _confidence2Sigma();

    // --- 10. Map matching ---
    final headingDeg = (_x[3] * (180.0 / pi) + 360.0) % 360.0;
    final matchResult = _mapMatcher.match(curLat, curLon, headingDeg);

    return LocalNavigationOutput(
      timestampS: timestampS,
      lat: curLat,
      lon: curLon,
      matchedLat: matchResult.lat,
      matchedLon: matchResult.lon,
      isSnapped: matchResult.isSnapped,
      posEastM: _x[0],
      posNorthM: _x[1],
      speedMps: zuptActive ? 0.0 : _x[2],
      speedKmh: (zuptActive ? 0.0 : _x[2]) * 3.6,
      headingDeg: headingDeg,
      gyroBiasRads: _x[4],
      speedScaleFactor: speedScaleFactor,
      confidenceRadiusM: confRadius,
      isStationary: zuptActive,
      isOod: _isOod,
      oodEntropy: _oodEntropy,
      zuptActive: zuptActive,
      motionMode: effectiveMode,
      gnssState: gnssState,
      navPipeline: navPipeline,
      drLat: drLat,
      drLon: drLon,
      modelSpeedMps: _modelSpeedMps,
    );
  }

  // --- GNSS 3-obs update: [p_E, p_N, v] ---
  void _gnssUpdate3(double zE, double zN, double zV,
      double posSigma, double spdSigma) {
    // H is 3x5: rows select states 0,1,2
    // R = diag([posSigma^2, posSigma^2, spdSigma^2])
    // y = z - H*x
    final y = [zE - _x[0], zN - _x[1], zV - _x[2]];
    final r = [posSigma * posSigma, posSigma * posSigma, spdSigma * spdSigma];
    final hRows = [0, 1, 2]; // H selects these state indices
    _scalarSequentialUpdate(hRows, y, r);
  }

  // --- GNSS 4-obs update: [p_E, p_N, v, psi] ---
  void _gnssUpdate4(double zE, double zN, double zV, double zPsi,
      double posSigma, double spdSigma) {
    final headingSigma = 3.0 * (pi / 180.0); // 3 degrees
    var yPsi = zPsi - _x[3];
    yPsi = _wrapAngle(yPsi);

    final y = [zE - _x[0], zN - _x[1], zV - _x[2], yPsi];
    final r = [
      posSigma * posSigma,
      posSigma * posSigma,
      spdSigma * spdSigma,
      headingSigma * headingSigma,
    ];
    final hRows = [0, 1, 2, 3];
    _scalarSequentialUpdate(hRows, y, r);
  }

  /// Sequential scalar Kalman updates — numerically stable, avoids matrix inversion.
  /// Each observation updates state independently. For H where each row selects
  /// exactly one state, this is equivalent to the full matrix update.
  void _scalarSequentialUpdate(
      List<int> stateIndices, List<double> innovations, List<double> rValues) {
    for (int k = 0; k < stateIndices.length; k++) {
      final j = stateIndices[k]; // which state this observation maps to
      final yk = innovations[k];
      final rk = rValues[k];

      // S = P[j,j] + R_k
      final s = _P[j * _n + j] + rk;
      if (s < 1e-12) continue;

      // K = P[:,j] / S (column j of P, divided by S)
      final kGain = List<double>.generate(_n, (i) => _P[i * _n + j] / s);

      // x += K * y_k
      for (int i = 0; i < _n; i++) _x[i] += kGain[i] * yk;

      // P = (I - K * H_row) * P, where H_row selects column j
      // P[i,l] -= K[i] * P[j,l] for all i,l
      // Must snapshot P[j,:] first since it's being modified
      final pjRow = List<double>.generate(_n, (l) => _P[j * _n + l]);
      for (int i = 0; i < _n; i++) {
        for (int l = 0; l < _n; l++) {
          _P[i * _n + l] -= kGain[i] * pjRow[l];
        }
      }
    }
  }

  /// 2-sigma confidence radius from position covariance sub-matrix eigenvalues.
  double _confidence2Sigma() {
    final pEE = _P[0 * _n + 0];
    final pEN = _P[0 * _n + 1];
    final pNE = _P[1 * _n + 0];
    final pNN = _P[1 * _n + 1];

    // Eigenvalues of 2x2 symmetric matrix [[a,b],[b,d]]:
    // lambda = (a+d)/2 ± sqrt(((a-d)/2)^2 + b*c)
    final trace = pEE + pNN;
    final det = pEE * pNN - pEN * pNE;
    final disc = max(0.0, trace * trace / 4.0 - det);
    final lambdaMax = trace / 2.0 + sqrt(disc);
    return 2.0 * sqrt(max(1e-4, lambdaMax));
  }

  // --- Matrix helpers for 5x5 (row-major flat arrays) ---

  static List<double> _eye5() {
    final m = List.filled(_n * _n, 0.0);
    for (int i = 0; i < _n; i++) m[i * _n + i] = 1.0;
    return m;
  }

  /// Computes F * P * F^T + Q where all are 5x5 row-major flat arrays.
  static List<double> _matMulAdd5(
      List<double> f, List<double> p, List<double> q) {
    // temp = F * P
    final fp = List.filled(_n * _n, 0.0);
    for (int i = 0; i < _n; i++) {
      for (int j = 0; j < _n; j++) {
        double sum = 0.0;
        for (int k = 0; k < _n; k++) {
          sum += f[i * _n + k] * p[k * _n + j];
        }
        fp[i * _n + j] = sum;
      }
    }
    // result = temp * F^T + Q
    final r = List.filled(_n * _n, 0.0);
    for (int i = 0; i < _n; i++) {
      for (int j = 0; j < _n; j++) {
        double sum = 0.0;
        for (int k = 0; k < _n; k++) {
          sum += fp[i * _n + k] * f[j * _n + k]; // F^T[k,j] = F[j,k]
        }
        r[i * _n + j] = sum + q[i * _n + j];
      }
    }
    return r;
  }

  static double _wrapAngle(double rad) {
    return ((rad + pi) % (2 * pi)) - pi;
  }

  void reset() {
    _originLat = null;
    _originLon = null;
    _lastTimestampS = 0.0;
    _headingInitialized = false;
    _drEast = 0.0;
    _drNorth = 0.0;
    speedScaleFactor = 1.0;
    _sampleCounter = 0;
    for (int i = 0; i < _n; i++) _x[i] = 0.0;
    _initCovariance();
  }
}
