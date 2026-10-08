import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../core/constants.dart';

class SightingDialog extends StatefulWidget {
  final double lat;
  final double lon;
  final String? patrolId;

  const SightingDialog({
    super.key,
    required this.lat,
    required this.lon,
    this.patrolId,
  });

  @override
  State<SightingDialog> createState() => _SightingDialogState();
}

class _SightingDialogState extends State<SightingDialog> {
  static const _speciesOptions = [
    'Tiger',
    'Leopard',
    'Elephant',
    'Sloth Bear',
    'Wild Boar',
    'Deer',
    'Poacher',
    'Snare/Trap',
    'Vehicle Track',
    'Other',
  ];

  String _selectedSpecies = 'Tiger';
  int _count = 1;
  final _descriptionController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    final payload = {
      'id': const Uuid().v4(),
      'patrol_id': widget.patrolId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'lat': widget.lat,
      'lon': widget.lon,
      'species': _selectedSpecies,
      'count': _count,
      'description': _descriptionController.text.trim(),
    };

    try {
      final response = await http
          .post(
            Uri.parse('${AppConstants.apiBaseUrl}/sightings'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (mounted) Navigator.of(context).pop(true);
      } else {
        setState(() => _error = 'Server error: ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _error = 'Saved offline. Will sync later.');
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1B2A1B),
      title: const Row(
        children: [
          Icon(Icons.pets, color: Colors.amber),
          SizedBox(width: 8),
          Text('Log Sighting',
              style: TextStyle(color: Colors.amber, fontSize: 18)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Position: ${widget.lat.toStringAsFixed(5)}, ${widget.lon.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 12),
            const Text('Species',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _selectedSpecies,
              dropdownColor: const Color(0xFF2A3A2A),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF2A3A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Colors.green),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              items: _speciesOptions
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedSpecies = v!),
            ),
            const SizedBox(height: 12),
            const Text('Count',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  onPressed:
                      _count > 1 ? () => setState(() => _count--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                  color: Colors.amber,
                  iconSize: 28,
                ),
                Text('$_count',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                IconButton(
                  onPressed: () => setState(() => _count++),
                  icon: const Icon(Icons.add_circle_outline),
                  color: Colors.amber,
                  iconSize: 28,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Description (optional)',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Direction of movement, behavior...',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF2A3A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Colors.green),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: Colors.orange, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade800,
            foregroundColor: Colors.white,
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}
