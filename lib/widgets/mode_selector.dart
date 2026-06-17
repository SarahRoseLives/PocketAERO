import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../models/rf_mode.dart';
import '../models/app_theme.dart';

class ModeSelector extends StatelessWidget {
  const ModeSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();
    const modeIds = ['am', 'nfm', 'wfm', 'usb', 'lsb'];
    final modes = modeIds
        .map((id) => RfMode.builtInModes.firstWhere((m) => m.id == id))
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MODE', style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.grey[600], letterSpacing: 1.5, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: modes.map((mode) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _ModeChip(mode: mode, selected: mode.id == radio.selectedMode.id),
                )).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final RfMode mode;
  final bool selected;

  const _ModeChip({required this.mode, required this.selected});

  @override
  Widget build(BuildContext context) {
    final radio = context.read<RadioProvider>();

    return Tooltip(
      message: mode.description,
      child: ChoiceChip(
        label: Text(mode.name, style: TextStyle(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          fontSize: 14,
        )),
        selected: selected,
        onSelected: (_) => radio.selectMode(mode),
        selectedColor: AppTheme.primary,
        labelStyle: TextStyle(color: selected ? Colors.white : null),
        avatar: selected ? const Icon(Icons.radio_button_checked, size: 16, color: Colors.white) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
    );
  }
}
