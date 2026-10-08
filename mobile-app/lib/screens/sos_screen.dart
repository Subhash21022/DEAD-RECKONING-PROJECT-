import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/emergency_sos_service.dart';
import '../services/dead_reckoning_service.dart';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen>
    with SingleTickerProviderStateMixin {
  late EmergencySosService _sosService;
  late AnimationController _pulseController;
  StreamSubscription<SosStatus>? _statusSub;
  Timer? _elapsedTimer;

  SosStatus _status = SosStatus.idle;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _sosService = context.read<EmergencySosService>();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _statusSub = _sosService.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
    });

    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _elapsed = _sosService.elapsedSinceActivation);
      }
    });

    WakelockPlus.enable();
    _triggerSos();
  }

  void _triggerSos() {
    final drService = context.read<DeadReckoningService>();
    final lastNav = drService.lastState;
    if (lastNav != null) {
      _sosService.updateNavState(lastNav);
    }
    _sosService.triggerSos();
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A1010),
        title: const Text('Cancel SOS?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to cancel the emergency alert? '
          'Base camp will be notified of cancellation.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Active',
                style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey.shade800,
            ),
            child: const Text('Cancel SOS',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _sosService.cancelSos();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _elapsedTimer?.cancel();
    _pulseController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours.toString().padLeft(2, '0')}:$mins:$secs';
  }

  @override
  Widget build(BuildContext context) {
    final drService = context.read<DeadReckoningService>();
    final nav = drService.lastState;

    return Scaffold(
      backgroundColor: const Color(0xFF1A0000),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            AnimatedBuilder(
              animation: _pulseController,
              builder: (_, __) {
                final scale = 1.0 + _pulseController.value * 0.15;
                final opacity = 0.6 + _pulseController.value * 0.4;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red.withValues(alpha: opacity),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withValues(alpha: opacity * 0.5),
                          blurRadius: 40,
                          spreadRadius: 20,
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        'SOS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 30),
            Text(
              _statusLabel(),
              style: TextStyle(
                color: _statusColor(),
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _formatDuration(_elapsed),
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 36,
                fontWeight: FontWeight.w300,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 40),
            if (nav != null) ...[
              _infoTile('Latitude', nav.lat.toStringAsFixed(6)),
              _infoTile('Longitude', nav.lon.toStringAsFixed(6)),
              _infoTile('Heading', '${nav.headingDeg.toStringAsFixed(0)}°'),
              _infoTile('Confidence', '${nav.confidenceRadiusM.toStringAsFixed(1)} m'),
              _infoTile('GNSS', nav.gnssQuality),
            ] else
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Acquiring position...',
                    style: TextStyle(color: Colors.white38)),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _confirmCancel,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade900,
                    foregroundColor: Colors.white70,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                  child: const Text('CANCEL SOS',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ),
          Text(value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              )),
        ],
      ),
    );
  }

  String _statusLabel() {
    switch (_status) {
      case SosStatus.idle:
        return 'INITIALIZING...';
      case SosStatus.sending:
        return 'TRANSMITTING...';
      case SosStatus.active:
        return 'ALERT CONFIRMED';
      case SosStatus.failed:
        return 'TRANSMISSION FAILED - RETRYING';
      case SosStatus.cancelled:
        return 'CANCELLED';
    }
  }

  Color _statusColor() {
    switch (_status) {
      case SosStatus.idle:
        return Colors.white54;
      case SosStatus.sending:
        return Colors.orange;
      case SosStatus.active:
        return Colors.green;
      case SosStatus.failed:
        return Colors.red;
      case SosStatus.cancelled:
        return Colors.grey;
    }
  }
}
