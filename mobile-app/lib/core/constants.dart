class AppConstants {
  AppConstants._();

  static const String appName = 'Forest Ranger Nav';
  static const String appVersion = '1.0.0';

  // Networking (Default 127.0.0.1 for USB reverse tunnel, fallback to 192.168.1.8 over Wi-Fi)
  static const String serverHost = '127.0.0.1';
  static const String apiBaseUrl = 'http://$serverHost:8000/api/v1';
  static const String wsBaseUrl = 'ws://$serverHost:8000/ws';
  static const String edgeApiUrl = 'http://$serverHost:8001';
  static const String edgeWsUrl = 'ws://$serverHost:8001/ws/stream';

  // IMU Sampling
  static const int imuSampleRateHz = 100;
  static const double imuSampleIntervalMs = 1000.0 / imuSampleRateHz;
  static const int inferenceRateHz = 10;
  static const int samplesPerInference = imuSampleRateHz ~/ inferenceRateHz;
  static const int imuWindowSize = 100;

  // ZUPT Thresholds
  static const double speedDeadbandMps = 0.75;
  static const double lpAccStdThreshold = 0.35;
  static const double lpGyroNormThreshold = 0.045;
  static const double lpAlpha = 0.15;

  // GNSS Thresholds (used by GnssQualityManager with hysteresis)
  static const double gnssGoodAccuracyM = 15.0;
  static const double gnssDegradedAccuracyM = 40.0;
  static const double gnssMaxFixAgeS = 4.5;
  static const double gnssMaxJumpSpeedMps = 60.0;
  static const int gnssRecoveryFixesRequired = 4;
  static const double gnssGoodToDegradedHysteresisS = 1.2;
  static const double gnssDegradedToLostHysteresisS = 2.5;

  // EKF Initial Covariance
  static const List<double> ekfInitP = [5.0, 5.0, 1.0, 0.05, 1e-4];
  static const List<double> ekfProcessNoise = [0.02, 0.02, 0.25, 0.001, 1e-7];

  // Mode Transition Hysteresis
  static const double modeVehicleThreshold = 0.78;
  static const double modeWalkingThreshold = 0.75;
  static const double modeStationaryThreshold = 0.75;
  static const double modeUnknownThreshold = 0.55;
  static const double modeStatToVehicleHoldS = 1.5;
  static const double modeStatToWalkingHoldS = 1.2;
  static const double modeWalkToStatHoldS = 1.0;

  // Calibration
  static const int calibrationDurationSeconds = 4;

  // Sync
  static const int syncIntervalSeconds = 30;
  static const int syncBatchSize = 500;
  static const int maxOfflineBreadcrumbs = 50000;

  // Dead Ranger Watchdog
  static const int watchdogWarningMinutes = 10;
  static const int watchdogCriticalMinutes = 15;

  // Map Matching
  static const double maxSnapDistanceM = 30.0;
  static const double maxHeadingDiffDeg = 55.0;

  // Coverage Grid
  static const double coverageCellSizeM = 50.0;

  // Database
  static const String dbName = 'forest_ranger_nav.db';
  static const int dbVersion = 1;
}
