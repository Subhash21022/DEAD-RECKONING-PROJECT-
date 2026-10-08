import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/dead_reckoning_service.dart';

class NavigationDebugScreen extends StatefulWidget {
  const NavigationDebugScreen({super.key});

  @override
  State<NavigationDebugScreen> createState() => _NavigationDebugScreenState();
}

class _NavigationDebugScreenState extends State<NavigationDebugScreen> {
  final List<String> _transitionHistory = [];
  String? _lastRecordedTransition;

  Color _getGnssColor(String gnssQuality) {
    switch (gnssQuality) {
      case 'GOOD':
        return const Color(0xFF388E3C); // Green
      case 'DEGRADED':
        return const Color(0xFFFBC02D); // Yellow
      case 'LOST':
        return const Color(0xFFD32F2F); // Red
      case 'RECOVERING':
        return const Color(0xFF00897B); // Teal
      default:
        return Colors.grey;
    }
  }

  Color _getNetworkColor(String networkState) {
    return networkState == 'ONLINE'
        ? const Color(0xFF2E7D32)
        : const Color(0xFF757575);
  }

  Color _getMotionColor(String mode) {
    switch (mode) {
      case 'VEHICLE':
        return const Color(0xFFE65100); // Orange
      case 'WALKING':
        return const Color(0xFF1976D2); // Blue
      case 'STATIONARY':
        return const Color(0xFF7B1FA2); // Purple
      default:
        return Colors.grey;
    }
  }

  void _recordTransition(String transition) {
    if (transition.isNotEmpty && transition != _lastRecordedTransition) {
      _lastRecordedTransition = transition;
      final timeStr = DateTime.now().toIso8601String().substring(11, 19);
      _transitionHistory.insert(0, '[$timeStr] $transition');
      if (_transitionHistory.length > 25) {
        _transitionHistory.removeLast();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final drService = Provider.of<DeadReckoningService>(context, listen: false);

    return Scaffold(
      backgroundColor: const Color(0xFF121418),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.troubleshoot, color: Colors.cyanAccent, size: 20),
            SizedBox(width: 8),
            Text(
              'Navigation Diagnostics',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E222B),
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.straighten, color: Colors.amberAccent),
            tooltip: 'Stationary Calibrate',
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Hold phone still for 4 seconds...'),
                  duration: Duration(seconds: 4),
                ),
              );
              await drService.calibrationService.startStationaryCalibration(durationSeconds: 4);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Calibration Complete! Gravity & Gyro Bias stored.')),
                );
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<NavigationState>(
        stream: drService.navigationStream,
        initialData: drService.lastState,
        builder: (context, snapshot) {
          final state = snapshot.data;

          if (state == null) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.cyanAccent),
                  SizedBox(height: 16),
                  Text(
                    'Awaiting navigation telemetry stream...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            );
          }

          if (state.lastTransition.isNotEmpty) {
            _recordTransition(state.lastTransition);
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Independent 4-State Architecture Card
                _buildIndependentStatesCard(state),
                const SizedBox(height: 12),

                // 2. Hardware Sensor Rates & Physical Calibration Card
                _buildSensorAndCalibrationCard(drService, state),
                const SizedBox(height: 12),

                // 3. Multimodal Motion Probabilities & Physical Gating
                _buildMotionClassifierCard(state),
                const SizedBox(height: 12),

                // 4. Coordinates Verification (GNSS vs DR vs EKF Fusion)
                _buildPositionVerificationCard(state),
                const SizedBox(height: 12),

                // 5. State Machine Transition History
                _buildTransitionLogCard(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildIndependentStatesCard(NavigationState state) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'INDEPENDENT SUBSYSTEM STATES',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.cyanAccent,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildStateBadge(
                  title: 'GNSS',
                  value: state.gnssQuality,
                  color: _getGnssColor(state.gnssQuality),
                  icon: Icons.satellite_alt,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStateBadge(
                  title: 'NETWORK',
                  value: state.networkState,
                  color: _getNetworkColor(state.networkState),
                  icon: state.networkState == 'ONLINE'
                      ? Icons.wifi
                      : Icons.wifi_off,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildStateBadge(
                  title: 'MOTION',
                  value: state.mode,
                  color: _getMotionColor(state.mode),
                  icon: state.mode == 'VEHICLE'
                      ? Icons.directions_car
                      : state.mode == 'WALKING'
                          ? Icons.directions_walk
                          : Icons.pan_tool,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStateBadge(
                  title: 'NAVIGATION',
                  value: state.navPipeline,
                  color: Colors.blueAccent,
                  icon: Icons.navigation,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStateBadge({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1.2),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: color.withValues(alpha: 0.7),
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSensorAndCalibrationCard(DeadReckoningService drService, NavigationState state) {
    final cal = drService.calibrationService.profile;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'MEASURED HARDWARE SENSORS & CALIBRATION',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.amberAccent,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _metricBox(
                  'ACCEL RATE',
                  '${state.measuredAccelHz.toStringAsFixed(1)} Hz',
                  Colors.amber,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricBox(
                  'GYRO RATE',
                  '${state.measuredGyroHz.toStringAsFixed(1)} Hz',
                  Colors.amber,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricBox(
                  'GNSS ACCURACY',
                  '±${state.gnssAccuracyM.toStringAsFixed(1)} m',
                  state.gnssAccuracyM <= 15 ? Colors.green : Colors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _detailRow(
            'Gravity Vector (g_down)',
            '[${cal.gDown[0].toStringAsFixed(2)}, ${cal.gDown[1].toStringAsFixed(2)}, ${cal.gDown[2].toStringAsFixed(2)}]',
            Colors.white70,
          ),
          _detailRow(
            'Gyro Bias (rad/s)',
            '[${cal.gyroBias[0].toStringAsFixed(4)}, ${cal.gyroBias[1].toStringAsFixed(4)}, ${cal.gyroBias[2].toStringAsFixed(4)}]',
            Colors.white70,
          ),
          _detailRow(
            'Stationary Accel Variance',
            '${cal.accelVariance.toStringAsFixed(4)} m²/s⁴',
            cal.accelVariance < 0.35 ? Colors.green : Colors.orange,
          ),
        ],
      ),
    );
  }

  Widget _buildMotionClassifierCard(NavigationState state) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'MULTIMODAL MOTION CLASSIFIER & GATING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.lightGreenAccent,
            ),
          ),
          const SizedBox(height: 10),
          _probBar('Stationary', state.pStationary, Colors.purpleAccent),
          const SizedBox(height: 6),
          _probBar('Vehicle', state.pVehicle, Colors.orangeAccent),
          const SizedBox(height: 6),
          _probBar('Walking', state.pWalking, Colors.blueAccent),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _metricBox(
                  'ZUPT ACTIVE',
                  state.zuptActive ? 'TRUE' : 'FALSE',
                  state.zuptActive ? Colors.green : Colors.grey,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricBox(
                  'SPEED (EKF)',
                  '${state.speedKmh.toStringAsFixed(1)} km/h',
                  Colors.cyanAccent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricBox(
                  'HEADING',
                  '${state.headingDeg.toStringAsFixed(0)}°',
                  Colors.cyanAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _probBar(String label, double p, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            Text('${(p * 100).toStringAsFixed(1)}%',
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 3),
        LinearProgressIndicator(
          value: p.clamp(0.0, 1.0),
          backgroundColor: Colors.white10,
          color: color,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
      ],
    );
  }

  Widget _buildPositionVerificationCard(NavigationState state) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'POSITION VERIFICATION: GNSS vs DR vs EKF',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.cyanAccent,
            ),
          ),
          const SizedBox(height: 10),
          _coordRow('Fused (Active)', state.lat, state.lon, Colors.greenAccent),
          _coordRow('Dead Reckoning', state.drLat, state.drLon, Colors.blueAccent),
          _coordRow(
            'Raw GNSS',
            state.rawGnssLat ?? 0.0,
            state.rawGnssLon ?? 0.0,
            state.rawGnssLat != null ? Colors.amberAccent : Colors.grey,
          ),
          const Divider(color: Colors.white12, height: 16),
          _detailRow(
            'Confidence Ellipse (±)',
            '${state.confidenceRadiusM.toStringAsFixed(1)} m',
            state.confidenceRadiusM <= 15 ? Colors.green : Colors.orange,
          ),
        ],
      ),
    );
  }

  Widget _buildTransitionLogCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'STATE MACHINE TRANSITIONS',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          if (_transitionHistory.isEmpty)
            const Text(
              'No state transitions recorded yet.',
              style: TextStyle(color: Colors.grey, fontSize: 11),
            )
          else
            ..._transitionHistory.map(
              (t) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Text(
                  t,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.cyanAccent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _metricBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF14171E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 9, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, Color valColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
          Text(value, style: TextStyle(color: valColor, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _coordRow(String label, double lat, double lon, Color color) {
    final str = (lat == 0.0 && lon == 0.0)
        ? 'N/A'
        : '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 11)),
          Text(str, style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 11)),
        ],
      ),
    );
  }
}
