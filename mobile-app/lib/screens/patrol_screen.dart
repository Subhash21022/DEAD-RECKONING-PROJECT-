import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:battery_plus/battery_plus.dart';
import '../core/database/breadcrumb_dao.dart';
import '../services/sensor_stream_service.dart';
import '../services/gnss_service.dart';
import '../services/dead_reckoning_service.dart';
import '../services/dead_ranger_service.dart';
import '../services/sync_service.dart';
import 'sighting_dialog.dart';
import 'sos_screen.dart';
import 'navigation_debug_screen.dart';

class PatrolScreen extends StatefulWidget {
  const PatrolScreen({super.key});

  @override
  State<PatrolScreen> createState() => _PatrolScreenState();
}

class _PatrolScreenState extends State<PatrolScreen> {
  final MapController _mapController = MapController();
  final Battery _battery = Battery();
  final BreadcrumbDao _dao = BreadcrumbDao();

  late SensorStreamService _sensorService;
  late GnssService _gnssService;
  late DeadReckoningService _drService;
  late DeadRangerService _watchdog;
  late SyncService _syncService;

  StreamSubscription<NavigationState>? _navSub;
  StreamSubscription<EdgeConnectionState>? _connSub;
  StreamSubscription<SyncStats>? _syncStatsSub;

  NavigationState? _currentNav;
  EdgeConnectionState _edgeConn = EdgeConnectionState.disconnected;
  SyncStats _syncStats = const SyncStats();
  int _batteryLevel = 100;
  bool _patrolActive = false;
  String? _patrolId;

  final List<LatLng> _breadcrumbTrail = [];
  static const int _maxTrailPoints = 2000;

  StreamSubscription<GnssReading>? _gnssInitSub;

  @override
  void initState() {
    super.initState();
    _sensorService = context.read<SensorStreamService>();
    _gnssService = context.read<GnssService>();
    _drService = context.read<DeadReckoningService>();
    _watchdog = context.read<DeadRangerService>();
    _syncService = context.read<SyncService>();
    _initBattery();

    // Fast Calibration: start GNSS immediately on app launch
    _gnssService.start();
    _gnssInitSub = _gnssService.gnssStream.listen((reading) {
      if (!_patrolActive && mounted) {
        setState(() {});
        if (!_mapAnchored) {
          _mapController.move(LatLng(reading.lat, reading.lon), 17.0);
          _mapAnchored = true;
        }
      }
    });
  }

  Future<void> _initBattery() async {
    _batteryLevel = await _battery.batteryLevel;
    _battery.onBatteryStateChanged.listen((_) async {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    });
  }

  Future<void> _startPatrol() async {
    // 1. Station Calibration sequence before starting mission
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222B),
        title: const Row(
          children: [
            Icon(Icons.straighten, color: Colors.amberAccent),
            SizedBox(width: 8),
            Text('Sensor Calibration', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: StreamBuilder<double>(
          stream: _drService.calibrationService.progressStream,
          initialData: 0.0,
          builder: (context, snapshot) {
            final progress = snapshot.data ?? 0.0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Keep phone still on mount or hand to calibrate gravity vector and zero gyroscope bias.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: progress,
                  color: Colors.cyanAccent,
                  backgroundColor: Colors.white12,
                ),
                const SizedBox(height: 8),
                Text(
                  'Calibrating: ${(progress * 100).toInt()}%',
                  style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold),
                ),
              ],
            );
          },
        ),
      ),
    );

    _sensorService.start();
    await _drService.calibrationService.startStationaryCalibration(durationSeconds: 3);

    if (mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }

    _patrolId = const Uuid().v4();
    _breadcrumbTrail.clear();

    _gnssService.start();
    _drService.start();
    _watchdog.start();
    _syncService.start();

    _navSub = _drService.navigationStream.listen(_onNavUpdate);
    _connSub = _drService.connectionStream.listen((state) {
      if (mounted) setState(() => _edgeConn = state);
    });
    _syncStatsSub = _syncService.statsStream.listen((stats) {
      if (mounted) setState(() => _syncStats = stats);
    });

    setState(() => _patrolActive = true);
  }

  void _stopPatrol() {
    _navSub?.cancel();
    _connSub?.cancel();
    _syncStatsSub?.cancel();

    _sensorService.stop();
    _gnssService.stop();
    _drService.stop();
    _watchdog.stop();
    _syncService.stop();

    setState(() {
      _patrolActive = false;
      _patrolId = null;
      _mapAnchored = false;
    });
  }

  bool _mapAnchored = false;

  void _onNavUpdate(NavigationState state) {
    _watchdog.recordMotion(state.speedMps);

    final isValidCoord = state.matchedLat.abs() > 0.01 || state.matchedLon.abs() > 0.01;

    if (isValidCoord) {
      final pos = LatLng(state.matchedLat, state.matchedLon);
      _breadcrumbTrail.add(pos);
      if (_breadcrumbTrail.length > _maxTrailPoints) {
        _breadcrumbTrail.removeAt(0);
      }

      if (_patrolId != null) {
        _dao.insertBreadcrumb(BreadcrumbRecord(
          patrolId: _patrolId!,
          timestampS: state.timestampS,
          lat: state.matchedLat,
          lon: state.matchedLon,
          speedKmh: state.speedKmh,
          headingDeg: state.headingDeg,
          mode: state.mode,
          confidenceM: state.confidenceRadiusM,
          isOutage: state.isOutage,
          isSnapped: state.isSnapped,
        ));
      }
    }

    if (mounted) {
      setState(() => _currentNav = state);
      if (isValidCoord) {
        final pos = LatLng(state.matchedLat, state.matchedLon);
        if (!_mapAnchored) {
          _mapController.move(pos, 17.0);
          _mapAnchored = true;
        } else {
          _mapController.move(pos, _mapController.camera.zoom);
        }
      }
    }
  }

  void _openSosScreen() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SosScreen(),
    ));
  }

  void _openSightingDialog() {
    showDialog(
      context: context,
      builder: (_) => SightingDialog(
        lat: _currentNav?.matchedLat ?? 0.0,
        lon: _currentNav?.matchedLon ?? 0.0,
        patrolId: _patrolId,
      ),
    );
  }

  @override
  void dispose() {
    _gnssInitSub?.cancel();
    _navSub?.cancel();
    _connSub?.cancel();
    _syncStatsSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = _currentNav;
    final lastGnss = _gnssService.lastReading;
    final center = nav != null
        ? LatLng(nav.matchedLat, nav.matchedLon)
        : (lastGnss != null
            ? LatLng(lastGnss.lat, lastGnss.lon)
            : const LatLng(12.9716, 77.5946));

    return Scaffold(
      body: GestureDetector(
        onTapDown: (_) => _watchdog.recordActivity(),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: center, initialZoom: 16.0),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.forestnav.forest_ranger_nav',
                  tileProvider: NetworkTileProvider(
                    headers: {
                      'User-Agent': 'ForestRangerNav/1.0 (contact: admin@forestnav.org)',
                    },
                  ),
                  maxZoom: 19,
                ),
                if (_breadcrumbTrail.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: _breadcrumbTrail,
                      strokeWidth: 4.0,
                      color: Colors.amber.withValues(alpha: 0.85),
                    ),
                  ]),
                if (nav != null)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: LatLng(nav.matchedLat, nav.matchedLon),
                      radius: nav.confidenceRadiusM.clamp(3.0, 200.0),
                      useRadiusInMeter: true,
                      color: (nav.isOutage
                              ? Colors.red
                              : Colors.green)
                          .withValues(alpha: 0.15),
                      borderColor: nav.isOutage ? Colors.red : Colors.green,
                      borderStrokeWidth: 2.0,
                    ),
                  ])
                else if (lastGnss != null)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: LatLng(lastGnss.lat, lastGnss.lon),
                      radius: lastGnss.accuracyM.clamp(5.0, 150.0),
                      useRadiusInMeter: true,
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderColor: Colors.blue,
                      borderStrokeWidth: 1.5,
                    ),
                  ]),
                if (nav != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: LatLng(nav.matchedLat, nav.matchedLon),
                      width: 36,
                      height: 36,
                      child: Transform.rotate(
                        angle: nav.headingDeg * 3.14159265 / 180.0,
                        child: const Icon(
                          Icons.navigation,
                          color: Colors.amber,
                          size: 36,
                        ),
                      ),
                    ),
                  ])
                else if (lastGnss != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: LatLng(lastGnss.lat, lastGnss.lon),
                      width: 24,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Colors.black45, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ]),
              ],
            ),
            _buildHudOverlay(nav),
            _buildTopBar(),
            _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xDD1B2A1B),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.forest, color: Colors.green, size: 18),
              const SizedBox(width: 4),
              const Text('DeadReckon',
                  style: TextStyle(
                      color: Colors.amber,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
              const Spacer(),
              InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NavigationDebugScreen(),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.cyan.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.cyanAccent, width: 1),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.troubleshoot, color: Colors.cyanAccent, size: 13),
                      SizedBox(width: 3),
                      Text(
                        'DIAG',
                        style: TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 5),
              _connectionBadge(),
              const SizedBox(width: 5),
              Icon(
                _batteryLevel > 20
                    ? Icons.battery_full
                    : Icons.battery_alert,
                color: _batteryLevel > 20 ? Colors.green : Colors.red,
                size: 16,
              ),
              Text(' $_batteryLevel%',
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
              if (_syncStats.pendingCount > 0) ...[
                const SizedBox(width: 5),
                Text('${_syncStats.pendingCount}',
                    style:
                        const TextStyle(color: Colors.orange, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionBadge() {
    Color color;
    String label;
    switch (_edgeConn) {
      case EdgeConnectionState.connected:
        color = Colors.green;
        label = 'EDGE';
      case EdgeConnectionState.connecting:
        color = Colors.orange;
        label = 'CONN';
      case EdgeConnectionState.error:
        color = Colors.red;
        label = 'ERR';
      case EdgeConnectionState.disconnected:
        color = Colors.grey;
        label = 'OFF';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color, width: 1),
      ),
      child:
          Text(label, style: TextStyle(color: color, fontSize: 10)),
    );
  }

  Widget _buildHudOverlay(NavigationState? nav) {
    if (nav == null) return const SizedBox.shrink();

    return Positioned(
      left: 8,
      bottom: 100,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xDD1B2A1B),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _hudRow('SPD', '${nav.speedKmh.toStringAsFixed(1)} km/h', Colors.amber),
            _hudRow('HDG', '${nav.headingDeg.toStringAsFixed(0)}°', Colors.cyan),
            _hudRow('MOTION', nav.mode, _modeColor(nav.mode)),
            _hudRow(
              'GNSS',
              nav.gnssQuality,
              nav.gnssQuality == 'GOOD'
                  ? Colors.green
                  : nav.gnssQuality == 'DEGRADED'
                      ? Colors.orange
                      : nav.gnssQuality == 'RECOVERING'
                          ? Colors.tealAccent
                          : Colors.red,
            ),
            _hudRow(
              'NET',
              nav.networkState,
              nav.networkState == 'ONLINE' ? Colors.green : Colors.grey,
            ),
            _hudRow('PIPE', nav.navPipeline, Colors.lightBlueAccent),
            _hudRow(
              '±',
              '${nav.confidenceRadiusM.toStringAsFixed(1)} m',
              nav.confidenceRadiusM < 10
                  ? Colors.green
                  : nav.confidenceRadiusM < 30
                      ? Colors.orange
                      : Colors.red,
            ),
            if (nav.zuptActive)
              _hudRow('ZUPT', 'HOLD', Colors.purpleAccent),
            if (nav.isSnapped)
              _hudRow('SNAP', 'ON', Colors.cyan),
          ],
        ),
      ),
    );
  }

  Widget _hudRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            child: Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Color _modeColor(String mode) {
    switch (mode) {
      case 'STATIONARY':
        return Colors.grey;
      case 'VEHICLE':
        return Colors.green;
      case 'PEDESTRIAN':
      case 'WALKING':
        return Colors.cyan;
      default:
        return Colors.red;
    }
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xDD1B2A1B),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: _patrolActive
                    ? ElevatedButton.icon(
                        onPressed: _stopPatrol,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('END PATROL'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade900,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      )
                    : ElevatedButton.icon(
                        onPressed: _startPatrol,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('START PATROL'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade800,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              if (_patrolActive)
                IconButton(
                  onPressed: _openSightingDialog,
                  icon: const Icon(Icons.pets, color: Colors.cyan),
                  tooltip: 'Log Sighting',
                ),
              const SizedBox(width: 4),
              SizedBox(
                width: 64,
                height: 64,
                child: ElevatedButton(
                  onPressed: _openSosScreen,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade800,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    elevation: 6,
                  ),
                  child: const Text('SOS',
                      style: TextStyle(
                          fontWeight: FontWeight.w900, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
