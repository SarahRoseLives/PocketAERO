import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/aero_provider.dart';
import '../services/aero_service.dart';

class AcarsTab extends StatelessWidget {
  const AcarsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final aero = context.watch<AeroProvider>();
    final acarsMsgs = aero.acarsMessages;

    return Column(children: [
      _buildHeader(context, aero),
      const Divider(height: 1),
      Expanded(child: acarsMsgs.isEmpty
        ? Center(child: Text('No ACARS messages',
            style: const TextStyle(fontSize: 12, color: Colors.white38)))
        : ListView.builder(
            reverse: true,
            itemCount: acarsMsgs.length,
            itemBuilder: (ctx, i) => _buildAcarsCard(ctx, acarsMsgs[i]),
            cacheExtent: 500,
          )),
    ]);
  }

  static String _bodyText(AeroMessage msg) {
    final idx = msg.hexBytes.indexOf('\n');
    if (idx < 0) return msg.hexBytes.trim();
    return msg.hexBytes.substring(idx + 1).trim();
  }

  Widget _buildHeader(BuildContext context, AeroProvider aero) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: cs.surfaceContainerHighest,
      child: Row(children: [
        const Icon(Icons.text_snippet, size: 18),
        const SizedBox(width: 8),
        Text('ACARS Messages', style: TextStyle(
          fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurface)),
        const Spacer(),
        Text('${aero.acarsMessages.length} / ${aero.totalAcars}', style: TextStyle(
          fontSize: 11, color: cs.onSurface.withValues(alpha: 0.6))),
      ]),
    );
  }

  Widget _buildAcarsCard(BuildContext context, AeroMessage msg) {
    final cs = Theme.of(context).colorScheme;
    final body = _bodyText(msg);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.green.shade900.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.3), width: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (msg.aesId.isNotEmpty)
            Text('AES=${msg.aesId}', style: TextStyle(
              fontSize: 11, color: cs.onSurface.withValues(alpha: 0.8),
              fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          if (msg.gesId > 0) ...[
            const SizedBox(width: 8),
            Text('GES=${msg.gesId}', style: TextStyle(
              fontSize: 11, color: cs.onSurface.withValues(alpha: 0.7),
              fontFamily: 'monospace')),
          ],
          if (msg.length > 0) ...[
            const SizedBox(width: 8),
            Text('LEN=${msg.length}', style: TextStyle(
              fontSize: 11, color: Colors.cyanAccent.withValues(alpha: 0.7),
              fontFamily: 'monospace')),
          ],
          const Spacer(),
          Text(msg.timestamp.toString().substring(11, 19),
            style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4))),
        ]),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(body.trimRight(), style: TextStyle(
              fontSize: 11, fontFamily: 'monospace',
              color: cs.onSurface.withValues(alpha: 0.85),
              height: 1.4)),
          ),
        ],
      ]),
    );
  }
}
