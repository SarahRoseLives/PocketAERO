import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/aero_provider.dart';
import '../services/aero_service.dart';

class AircraftTab extends StatelessWidget {
  const AircraftTab({super.key});

  @override
  Widget build(BuildContext context) {
    final aero = context.watch<AeroProvider>();
    final cs = Theme.of(context).colorScheme;
    final planes = aero.aircraft.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: cs.surfaceContainerHighest,
        child: Row(children: [
          const Icon(Icons.flight, size: 18),
          const SizedBox(width: 8),
          Text('Aircraft Seen', style: TextStyle(
            fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurface)),
          const Spacer(),
          Text('${planes.length}', style: TextStyle(
            fontSize: 12, color: cs.onSurface.withValues(alpha: 0.6))),
        ]),
      ),
      const Divider(height: 1),
      Expanded(child: planes.isEmpty
        ? Center(child: Text('No aircraft seen yet',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4))))
        : ListView.builder(
            itemCount: planes.length,
            itemBuilder: (ctx, i) => _buildCard(ctx, planes[i], cs),
          ),
      ),
    ]);
  }

  Widget _buildCard(BuildContext context, AircraftEntry ac, ColorScheme cs) {
    final ago = DateTime.now().difference(ac.lastSeen);
    final agoStr = ago.inSeconds < 60
        ? '${ago.inSeconds}s ago'
        : ago.inMinutes < 60
            ? '${ago.inMinutes}m ago'
            : '${ago.inHours}h ago';
    final gesStr = ac.gesIds.map((g) => g.toString()).join(', ');

    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _AircraftDetailPage(aesId: ac.aesId),
      )),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.15))),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.flight, size: 16,
            color: ago.inSeconds < 30 ? Colors.greenAccent : Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(ac.aesId, style: TextStyle(
                  fontFamily: 'monospace', fontWeight: FontWeight.w700,
                  fontSize: 14, color: cs.onSurface, letterSpacing: 1)),
                const Spacer(),
                Text(agoStr, style: TextStyle(
                  fontSize: 10, color: cs.onSurface.withValues(alpha: 0.5))),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 14,
                  color: cs.onSurface.withValues(alpha: 0.3)),
              ]),
              const SizedBox(height: 3),
              Row(children: [
                Text('GES: ${gesStr.isEmpty ? "—" : gesStr}', style: TextStyle(
                  fontSize: 10, color: cs.onSurface.withValues(alpha: 0.6))),
                const SizedBox(width: 12),
                Text('msgs: ${ac.messageCount}', style: TextStyle(
                  fontSize: 10, color: cs.onSurface.withValues(alpha: 0.6))),
              ]),
              const SizedBox(height: 2),
              Text(ac.messageTypes.join(' · '), style: TextStyle(
                fontSize: 9, color: cs.onSurface.withValues(alpha: 0.4)),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          )),
        ]),
      ),
    );
  }
}

class _AircraftDetailPage extends StatelessWidget {
  final String aesId;
  const _AircraftDetailPage({required this.aesId});

  @override
  Widget build(BuildContext context) {
    final aero = context.watch<AeroProvider>();
    final cs = Theme.of(context).colorScheme;
    final msgs = aero.messages
        .where((m) => m.aesId == aesId)
        .toList()
        .reversed
        .toList();
    final ac = aero.aircraft[aesId];

    return Scaffold(
      appBar: AppBar(
        title: Text(aesId, style: const TextStyle(
          fontFamily: 'monospace', fontWeight: FontWeight.w700, letterSpacing: 1.5)),
        centerTitle: false,
        actions: [
          if (ac != null) Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text('${msgs.length} msgs',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5)))),
          ),
        ],
      ),
      body: msgs.isEmpty
        ? Center(child: Text('No messages in buffer',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4))))
        : ListView.builder(
            itemCount: msgs.length,
            itemBuilder: (ctx, i) => _buildMsgCard(msgs[i], cs),
          ),
    );
  }

  Widget _buildMsgCard(AeroMessage msg, ColorScheme cs) {
    final type = msg.callType.isNotEmpty ? msg.callType : msg.suType;
    final time = '${msg.timestamp.hour.toString().padLeft(2, '0')}:'
                 '${msg.timestamp.minute.toString().padLeft(2, '0')}:'
                 '${msg.timestamp.second.toString().padLeft(2, '0')}';

    Color typeColor;
    switch (msg.suType) {
      case 'ACARS':   typeColor = Colors.cyan; break;
      case 'VASSIGN': typeColor = Colors.purple; break;
      case 'CALL':    typeColor = Colors.blue; break;
      default:        typeColor = Colors.orange; break;
    }

    final body = msg.hexBytes.length > 60
        ? msg.hexBytes.substring(0, 60)
        : msg.hexBytes;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.12))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: typeColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(3)),
            child: Text(type, style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.w700,
              color: typeColor, fontFamily: 'monospace')),
          ),
          if (msg.gesId > 0) ...[
            const SizedBox(width: 8),
            Text('GES ${msg.gesId}', style: TextStyle(
              fontSize: 9, color: cs.onSurface.withValues(alpha: 0.5))),
          ],
          const Spacer(),
          Text(time, style: TextStyle(
            fontSize: 9, fontFamily: 'monospace',
            color: cs.onSurface.withValues(alpha: 0.4))),
        ]),
        const SizedBox(height: 3),
        Text(body, style: TextStyle(
          fontSize: 10, fontFamily: 'monospace',
          color: cs.onSurface.withValues(alpha: 0.7)),
          maxLines: 3, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
