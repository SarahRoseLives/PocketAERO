import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../models/rf_mode.dart';
import '../models/app_theme.dart';

class ModesScreen extends StatelessWidget {
  const ModesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Built-in Modes', style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          )),
          const SizedBox(height: 8),
          ...RfMode.builtInModes.map((mode) => _ModeListTile(
            mode: mode,
            isSelected: radio.selectedMode.id == mode.id,
            isCustom: false,
          )),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Custom Modes', style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              )),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _showAddModeDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Add Mode'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (radio.allModes.length == RfMode.builtInModes.length)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('No custom modes yet. Tap Add Mode to create one.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            ...radio.allModes
                .where((m) => !RfMode.builtInModes.any((b) => b.id == m.id))
                .map((mode) => _ModeListTile(
                      mode: mode,
                      isSelected: radio.selectedMode.id == mode.id,
                      isCustom: true,
                    )),
        ],
      ),
    );
  }

  void _showAddModeDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => const _AddModeDialog(),
    );
  }
}

class _ModeListTile extends StatelessWidget {
  final RfMode mode;
  final bool isSelected;
  final bool isCustom;

  const _ModeListTile({required this.mode, required this.isSelected, required this.isCustom});

  @override
  Widget build(BuildContext context) {
    final radio = context.read<RadioProvider>();

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: isSelected ? AppTheme.primary.withValues(alpha: 0.06) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected ? BorderSide(color: AppTheme.primary, width: 1.5) : BorderSide.none,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: isSelected ? AppTheme.primary : Colors.grey[200],
          child: Text(mode.name[0], style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[700],
            fontWeight: FontWeight.w700,
          )),
        ),
        title: Text(mode.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(mode.description),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mode.supportsTransmit)
              Chip(
                label: const Text('RX only', style: TextStyle(fontSize: 11)),
                backgroundColor: Colors.orange[50],
                side: BorderSide(color: Colors.orange[300]!),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            const SizedBox(width: 8),
            Text(
              _fmtBw(mode.defaultBandwidthHz),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            if (isCustom) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () => radio.removeCustomMode(mode.id),
                tooltip: 'Remove',
              ),
            ],
            if (isSelected)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.check_circle, color: AppTheme.primary),
              ),
          ],
        ),
        onTap: () => radio.selectMode(mode),
      ),
    );
  }

  String _fmtBw(double hz) {
    if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(1)} kHz';
    return '${hz.toStringAsFixed(0)} Hz';
  }
}

class _AddModeDialog extends StatefulWidget {
  const _AddModeDialog();

  @override
  State<_AddModeDialog> createState() => _AddModeDialogState();
}

class _AddModeDialogState extends State<_AddModeDialog> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  double _bandwidth = 10000;
  bool _canTx = true;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Custom Mode'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Mode Name', hintText: 'e.g. MY-MODE'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descController,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Bandwidth: '),
                Expanded(
                  child: Slider(
                    value: _bandwidth,
                    min: 50,
                    max: 500000,
                    divisions: 100,
                    onChanged: (v) => setState(() => _bandwidth = v),
                  ),
                ),
                Text(_fmtBw(_bandwidth), style: const TextStyle(fontSize: 12)),
              ],
            ),
            SwitchListTile(
              title: const Text('Supports Transmit'),
              value: _canTx,
              onChanged: (v) => setState(() => _canTx = v),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) return;
            final mode = RfMode(
              id: 'custom_${name.toLowerCase().replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}',
              name: name,
              description: _descController.text.trim().isEmpty ? 'Custom mode' : _descController.text.trim(),
              supportsTransmit: _canTx,
              defaultBandwidthHz: _bandwidth,
            );
            context.read<RadioProvider>().addCustomMode(mode);
            Navigator.pop(context);
          },
          child: const Text('Add'),
        ),
      ],
    );
  }

  String _fmtBw(double hz) {
    if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(1)} kHz';
    return '${hz.toStringAsFixed(0)} Hz';
  }
}
