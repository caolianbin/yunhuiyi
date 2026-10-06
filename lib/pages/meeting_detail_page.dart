import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../models/models.dart';
import '../services/meeting_service.dart';
import '../widgets/common.dart';
import 'room/room_page.dart';

class MeetingDetailPage extends StatefulWidget {
  const MeetingDetailPage({super.key, required this.meetingId});

  final int meetingId;

  @override
  State<MeetingDetailPage> createState() => _MeetingDetailPageState();
}

class _MeetingDetailPageState extends State<MeetingDetailPage> {
  Meeting? _meeting;
  List<Participant> _participants = const [];
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final svc = context.read<MeetingService>();
    try {
      final m = await svc.getById(widget.meetingId);
      List<Participant> ps = const [];
      try {
        ps = await svc.participants(widget.meetingId);
      } catch (_) {
        // 参会人拿不到不影响主体信息展示
      }
      if (mounted) {
        setState(() {
          _meeting = m;
          _participants = ps;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await context.read<MeetingService>().start(widget.meetingId);
      await _load();
      if (mounted) showSnack(context, '会议已开始');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e) {
      if (mounted) showSnack(context, '开始失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会议'),
        content: const Text('删除后会议记录不可恢复，确定继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await context.read<MeetingService>().delete(widget.meetingId);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meeting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('会议详情'),
        actions: [
          if (m != null && m.hostId == context.watch<Session>().user?.id)
            IconButton(
              tooltip: '删除会议',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: _error!, onRetry: _load)
              : m == null
                  ? const EmptyView(text: '会议不存在')
                  : _content(m),
    );
  }

  Widget _content(Meeting m) {
    final isHost = m.hostId == context.read<Session>().user?.id;
    final fmt = DateFormat('yyyy-MM-dd HH:mm');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.subject,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                      ),
                    ),
                    StatusChip(status: m.status),
                  ],
                ),
                if (m.description != null && m.description!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(m.description!, style: const TextStyle(height: 1.6)),
                ],
                const Divider(height: 26),
                _row('会议号', m.meetingNo, copyable: true),
                _row('主持人', m.hostName ?? '—'),
                _row('开始时间', fmt.format(m.startTime ?? DateTime.now())),
                _row('时长', '${m.durationMinutes} 分钟'),
                _row('参会人数', '${m.participantCount} 人'),
                if (m.hasPassword) _row('密码', '已设置'),
                if (m.waitingRoomEnabled) _row('等候室', '已开启'),
                if (m.isLocked) _row('锁定', '会议已锁定'),
                if (m.recurrence != null && m.recurrence!.isNotEmpty)
                  _row('重复', m.recurrence!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: m.inviteLink));
                  showSnack(context, '邀请链接已复制');
                },
                icon: const Icon(Icons.link, size: 18),
                label: const Text('复制邀请链接'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: m.meetingNo));
                  showSnack(context, '会议号已复制');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('复制会议号'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (isHost && m.status == 'waiting')
          FilledButton.icon(
            onPressed: _busy ? null : _start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('开始会议'),
          ),
        if (!m.isEnded)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: FilledButton.icon(
              onPressed: () async {
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => RoomPage(meetingId: m.id)),
                );
                if (mounted) _load();
              },
              icon: const Icon(Icons.videocam_rounded),
              label: const Text('进入会议'),
            ),
          ),
        const SizedBox(height: 20),
        const Text('参会人', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        if (_participants.isEmpty)
          const EmptyView(text: '暂无参会人', icon: Icons.group_outlined)
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < _participants.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: Avatar(
                      nickname: _participants[i].nickname,
                      url: _participants[i].avatar,
                      size: 38,
                    ),
                    title: Text(_participants[i].nickname),
                    subtitle: Text([
                      if (_participants[i].isHost) '主持人',
                      if (_participants[i].department != null &&
                          _participants[i].department!.isNotEmpty)
                        _participants[i].department!,
                      if (_participants[i].inWaitingRoom) '等候室中',
                    ].join(' · ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_participants[i].micOn)
                          const Icon(Icons.mic, size: 16, color: Color(0xFF30A46C)),
                        if (!_participants[i].micOn)
                          const Icon(Icons.mic_off, size: 16, color: Color(0xFFB9BEC7)),
                        const SizedBox(width: 6),
                        if (_participants[i].cameraOn)
                          const Icon(Icons.videocam, size: 16, color: Color(0xFF30A46C)),
                        if (!_participants[i].cameraOn)
                          const Icon(Icons.videocam_off, size: 16, color: Color(0xFFB9BEC7)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(String label, String value, {bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: const TextStyle(color: Color(0xFF8A9099), fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13.5)),
          ),
          if (copyable)
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                showSnack(context, '已复制');
              },
              child: const Icon(Icons.copy_rounded, size: 15, color: Color(0xFF1A73E8)),
            ),
        ],
      ),
    );
  }
}
