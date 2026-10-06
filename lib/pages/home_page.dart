import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../models/models.dart';
import '../services/meeting_service.dart';
import '../widgets/common.dart';
import 'create_meeting_page.dart';
import 'join_meeting_page.dart';
import 'meeting_detail_page.dart';
import 'profile_page.dart';
import 'room/room_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user;

    return Scaffold(
      appBar: AppBar(
        title: const Text('会议', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
        actions: [
          IconButton(
            tooltip: '个人中心',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfilePage()),
            ),
            icon: Avatar(
              nickname: user?.nickname ?? '我',
              url: user?.avatar,
              size: 32,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _quickActions(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TabBar(
              controller: _tab,
              tabs: const [Tab(text: '全部'), Tab(text: '我发起'), Tab(text: '我参加')],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: const [
                _MeetingList(scope: null),
                _MeetingList(scope: 'hosted'),
                _MeetingList(scope: 'joined'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _ActionCard(
              icon: Icons.videocam_rounded,
              label: '发起会议',
              color: const Color(0xFF1A73E8),
              onTap: () async {
                final created = await Navigator.push<Meeting>(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateMeetingPage(mode: 'instant')),
                );
                if (created != null && context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RoomPage(meetingId: created.id)),
                  );
                }
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _ActionCard(
              icon: Icons.login_rounded,
              label: '加入会议',
              color: const Color(0xFF30A46C),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const JoinMeetingPage()),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _ActionCard(
              icon: Icons.event_available_rounded,
              label: '预约会议',
              color: const Color(0xFF9A5CFF),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreateMeetingPage(mode: 'scheduled')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _MeetingList extends StatefulWidget {
  const _MeetingList({required this.scope});

  final String? scope;

  @override
  State<_MeetingList> createState() => _MeetingListState();
}

class _MeetingListState extends State<_MeetingList> with AutomaticKeepAliveClientMixin {
  List<Meeting>? _items;
  String? _error;
  bool _loading = false;
  String _filter = '';

  @override
  bool get wantKeepAlive => true;

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
    try {
      final list = await context
          .read<MeetingService>()
          .list(scope: widget.scope, filter: _filter.isEmpty ? null : _filter);
      if (mounted) setState(() => _items = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enter(Meeting m) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => RoomPage(meetingId: m.id)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            children: [
              for (final f in const [
                ['', '全部'],
                ['ongoing', '进行中'],
                ['waiting', '待开始'],
                ['ended', '已结束'],
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f[1]),
                    selected: _filter == f[0],
                    onSelected: (_) {
                      setState(() => _filter = f[0]);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading && _items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    final items = _items ?? const <Meeting>[];
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [
            SizedBox(height: 80),
            EmptyView(text: '还没有会议\n点击上方「发起会议」立即开会', icon: Icons.event_note_outlined),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _MeetingCard(
          meeting: items[i],
          onEnter: () => _enter(items[i]),
          onOpen: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => MeetingDetailPage(meetingId: items[i].id)),
          ).then((_) => _load()),
        ),
      ),
    );
  }
}

class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.meeting, required this.onEnter, required this.onOpen});

  final Meeting meeting;
  final VoidCallback onEnter;
  final VoidCallback onOpen;

  String get _timeText {
    final t = meeting.startTime;
    if (t == null) return '—';
    final fmt = DateFormat('MM-dd HH:mm');
    final now = DateTime.now();
    final isToday = t.year == now.year && t.month == now.month && t.day == now.day;
    return isToday ? '今天 ${DateFormat('HH:mm').format(t)}' : fmt.format(t);
  }

  @override
  Widget build(BuildContext context) {
    final canEnter = !meeting.isEnded;

    return Card(
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meeting.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusChip(status: meeting.status),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: meeting.meetingNo));
                      showSnack(context, '会议号已复制：${meeting.meetingNo}');
                    },
                    child: Row(
                      children: [
                        Text(
                          '会议号 ${meeting.meetingNo}',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF1A73E8)),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.copy_rounded, size: 13, color: Color(0xFF1A73E8)),
                      ],
                    ),
                  ),
                  if (meeting.hasPassword) ...[
                    const SizedBox(width: 10),
                    const Icon(Icons.lock_outline, size: 13, color: Color(0xFF8A9099)),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _meta(Icons.schedule, _timeText),
                  _meta(Icons.person_outline, meeting.hostName ?? '主持人'),
                  _meta(Icons.group_outlined, '${meeting.participantCount} 人'),
                  if (meeting.waitingRoomEnabled) _meta(Icons.door_front_door_outlined, '等候室'),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onOpen,
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(38)),
                      child: const Text('详情'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: canEnter ? onEnter : null,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(38)),
                      child: Text(meeting.isOngoing ? '进入会议' : '开始'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: const Color(0xFF8A9099)),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF8A9099))),
      ],
    );
  }
}
