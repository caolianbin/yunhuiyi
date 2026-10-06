import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_video_view.dart';

import '../../core/api_client.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/meeting_service.dart';
import '../../state/room_controller.dart';
import '../../widgets/common.dart';
import 'widgets/control_bar.dart';
import 'widgets/panels.dart';
import 'widgets/video_tile.dart';

/// 会议页。
///
/// 布局策略：
///   · 有人在共享屏幕 → 上方"共享舞台"占主体，参会人缩成底部横条
///   · 没人共享      → 视频宫格
/// 这样共享时观众看得清内容，不共享时又能看到所有人的脸。
class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.meetingId, this.password});

  final int meetingId;
  final String? password;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  late final RoomController _c;

  Timer? _timer;
  Duration _elapsed = Duration.zero;

  int _unread = 0;
  bool _sheetOpen = false;
  int _lastToastTick = 0;
  bool _popupShown = false;

  @override
  void initState() {
    super.initState();
    _c = RoomController(
      session: context.read<Session>(),
      api: context.read<ApiClient>(),
      meetings: context.read<MeetingService>(),
    );
    _c.addListener(_onChange);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _c.phase == RoomPhase.joined) {
        setState(() => _elapsed += const Duration(seconds: 1));
      }
    });
    // 首帧之后再启动，避免在 initState 里触发 notifyListeners 引起 setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _c.start(widget.meetingId, password: widget.password);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.removeListener(_onChange);
    _c.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;

    // 一次性提示
    if (_c.toastTick != _lastToastTick) {
      _lastToastTick = _c.toastTick;
      final msg = _c.toast;
      if (msg != null && msg.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final needsSettings = _c.toastNeedsSettings;
            showSnack(
              context,
              msg,
              actionLabel: needsSettings ? '去设置' : null,
              onAction: needsSettings ? AppPermissions.openSettings : null,
            );
            _c.clearToast();
          }
        });
      }
    }

    // 被踢 / 会议结束 / 主动离开 → 关闭弹层并退出
    if (_c.phase == RoomPhase.left && !_popupShown) {
      _popupShown = true;
      final reason = _c.endReason;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (reason != null && reason.isNotEmpty) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('已离开会议'),
              content: Text(reason),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        }
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    setState(() {});
  }

  String get _elapsedText {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _openSheet(Widget Function() builder, {double factor = 0.7}) {
    if (_sheetOpen) return;
    _sheetOpen = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * factor,
        // 面板内容依赖控制器状态（新消息、成员变化），必须跟随刷新
        child: ListenableBuilder(listenable: _c, builder: (_, __) => builder()),
      ),
    ).whenComplete(() {
      _sheetOpen = false;
      if (mounted) setState(() => _unread = 0);
    });
  }

  Future<void> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开会议'),
        content: const Text('确定要离开当前会议吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('离开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _c.leave();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF16171A),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_c.phase) {
      case RoomPhase.connecting:
        return const _Centered(
          icon: Icons.wifi_tethering,
          title: '正在进入会议…',
          child: Padding(
            padding: EdgeInsets.only(top: 18),
            child: CircularProgressIndicator(color: Colors.white),
          ),
        );
      case RoomPhase.waiting:
        return _waitingRoom();
      case RoomPhase.error:
        return _errorView();
      case RoomPhase.left:
        return const _Centered(icon: Icons.exit_to_app, title: '已离开会议');
      case RoomPhase.joined:
        return _room();
    }
  }

  Widget _waitingRoom() {
    return _Centered(
      icon: Icons.meeting_room_outlined,
      title: '正在等候主持人批准',
      child: Column(
        children: [
          const SizedBox(height: 10),
          const Text(
            '主持人批准后会自动进入会议，请稍候…',
            style: TextStyle(color: Color(0xFF9AA0A9), fontSize: 13),
          ),
          const SizedBox(height: 22),
          TextButton(
            onPressed: () async {
              await _c.leave();
              if (mounted) Navigator.of(context).maybePop();
            },
            child: const Text('取消并退出', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    final msg = _c.errorMessage ?? '无法进入会议';
    final needPassword = msg.contains('密码');
    return _Centered(
      icon: Icons.error_outline,
      title: msg,
      child: Column(
        children: [
          const SizedBox(height: 16),
          if (needPassword)
            FilledButton(
              onPressed: _askPassword,
              child: const Text('输入会议密码'),
            )
          else
            FilledButton(
              onPressed: () => _c.start(widget.meetingId, password: widget.password),
              child: const Text('重试'),
            ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('返回', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Future<void> _askPassword() async {
    final controller = TextEditingController();
    final pwd = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('会议密码'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入会议密码'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pwd != null && pwd.isNotEmpty) {
      await _c.start(widget.meetingId, password: pwd);
    }
  }

  // ============================================================
  //  会议主界面
  // ============================================================

  Widget _room() {
    final hasStage = _c.activeShareUserId != null;

    return Column(
      children: [
        _header(),
        if (!_c.rtcConfigured && _c.rtcDisabledReason != null) _warning(_c.rtcDisabledReason!),
        if (_c.rtcConfigured && !_c.rtcEntered) _warning('正在连接音视频服务…'),
        Expanded(
          child: hasStage
              ? Column(
                  children: [
                    Expanded(child: _stage()),
                    SizedBox(height: 104, child: _strip()),
                  ],
                )
              : _grid(),
        ),
        ControlBar(
          micOn: _c.micOn,
          cameraOn: _c.cameraOn,
          isSharing: _c.isSharing,
          sharePending: _c.sharePending,
          hardMuted: _c.joinedParticipants
              .where((p) => p.userId == _c.selfUserId)
              .map((p) => p.hardMuted)
              .firstOrNull ??
              false,
          handRaised: _c.joinedParticipants
              .where((p) => p.userId == _c.selfUserId)
              .map((p) => p.raisedHand)
              .firstOrNull ??
              false,
          memberCount: _c.joinedParticipants.length,
          unreadCount: _unread,
          shareEnabled: _c.isScreenShareSupported,
          onToggleMic: _c.toggleMic,
          onToggleCamera: _c.toggleCamera,
          onSwitchCamera: _c.switchCamera,
          onToggleShare: _c.toggleShare,
          onToggleHand: _c.toggleRaiseHand,
          onOpenChat: () => _openSheet(
            () => ChatPanel(controller: _c, selfUserId: _c.selfUserId),
            factor: 0.78,
          ),
          onOpenMembers: () => _openSheet(() => MemberPanel(controller: _c), factor: 0.72),
          onOpenMore: () => _openSheet(
            () => MorePanel(controller: _c, selfUserId: _c.selfUserId),
            factor: 0.7,
          ),
          onLeave: _confirmLeave,
        ),
      ],
    );
  }

  Widget _header() {
    return Container(
      color: const Color(0xFF16171A),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _c.meeting?.subject ?? '会议中',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '会议号 ${_c.meeting?.meetingNo ?? _c.meetingId}',
                      style: const TextStyle(color: Color(0xFF9AA0A9), fontSize: 11.5),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.circle, size: 6, color: Color(0xFF30A46C)),
                    const SizedBox(width: 4),
                    Text(
                      _c.rtcEntered ? '已连接 · $_elapsedText' : '连接中 · $_elapsedText',
                      style: const TextStyle(color: Color(0xFF9AA0A9), fontSize: 11.5),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_c.isLocked)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.lock, size: 16, color: Color(0xFFFFC53D)),
            ),
          IconButton(
            tooltip: '成员',
            onPressed: () => _openSheet(() => MemberPanel(controller: _c), factor: 0.72),
            icon: const Icon(Icons.people_outline, color: Colors.white, size: 21),
          ),
        ],
      ),
    );
  }

  Widget _warning(String text) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3A2E12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 15, color: Color(0xFFFFC53D)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFFFFD98A), fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 共享舞台 ----------

  Widget _stage() {
    final sid = _c.activeShareUserId;
    final isMine = _c.isMyShareActive;

    if (isMine) {
      return Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF202226),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.screen_share_rounded, size: 54, color: Color(0xFF1A73E8)),
            SizedBox(height: 14),
            Text('你正在共享屏幕',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text(
              '别人看到的画面由系统录制后推送到会议中，\n本机不会显示自己的屏（避免镜像回环）。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9AA0A9), fontSize: 12, height: 1.6),
            ),
          ],
        ),
      );
    }

    if (sid == null) return const SizedBox.shrink();

    final hasVideo = _c.subAvailable[sid] == true;
    final name = _c.nicknameOf(int.tryParse(sid) ?? 0);

    if (!hasVideo) {
      return _Centered(
        icon: Icons.cast_connected_rounded,
        title: '$name 正在共享屏幕',
        child: const Padding(
          padding: EdgeInsets.only(top: 14),
          child: Text(
            '正在等待画面…',
            style: TextStyle(color: Color(0xFF9AA0A9), fontSize: 12),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            // 共享画布是主路之外的"辅流"，这里订阅并渲染
            child: TRTCCloudVideoView(
              key: ValueKey('stage-$sid'),
              onViewCreated: (viewId) => _c.onSubViewCreated(sid, viewId),
            ),
          ),
          Positioned(
            left: 10,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xCC1A73E8),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$name 的屏幕',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 共享时底部缩略图横条
  Widget _strip() {
    final list = _c.joinedParticipants;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, i) {
        final p = list[i];
        final uid = p.userId.toString();
        final isSelf = p.userId == _c.selfUserId;
        return SizedBox(
          width: 76,
          child: VideoTile(
            userId: uid,
            nickname: p.nickname,
            isLocal: isSelf,
            videoOn: isSelf ? _c.cameraOn : (_c.videoAvailable[uid] == true),
            micOn: p.micOn,
            speaking: _c.isSpeaking(p.userId),
            isSharing: p.isSharing,
            isHost: p.isHost,
            avatar: p.avatar,
            compact: true,
            onViewCreated: (viewId) =>
                isSelf ? _c.onLocalViewCreated(viewId) : _c.onRemoteViewCreated(uid, viewId),
          ),
        );
      },
    );
  }

  // ---------- 视频宫格 ----------

  Widget _grid() {
    final list = _c.joinedParticipants;
    final n = list.length;
    final columns = n <= 1 ? 1 : (n <= 4 ? 2 : 3);

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: columns == 1 ? 3 / 4 : (columns == 2 ? 0.78 : 0.72),
      ),
      itemCount: n,
      itemBuilder: (_, i) {
        final p = list[i];
        final uid = p.userId.toString();
        final isSelf = p.userId == _c.selfUserId;
        return VideoTile(
          userId: uid,
          nickname: p.nickname,
          isLocal: isSelf,
          videoOn: isSelf ? _c.cameraOn : (_c.videoAvailable[uid] == true),
          micOn: p.micOn,
          speaking: _c.isSpeaking(p.userId),
          isSharing: p.isSharing,
          isHost: p.isHost,
          avatar: p.avatar,
          onViewCreated: (viewId) =>
              isSelf ? _c.onLocalViewCreated(viewId) : _c.onRemoteViewCreated(uid, viewId),
          onTap: () => _showParticipant(p),
        );
      },
    );
  }

  void _showParticipant(Participant p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Avatar(nickname: p.nickname, url: p.avatar, size: 42),
              title: Text(p.nickname),
              subtitle: Text([
                if (p.isHost) '主持人',
                if (p.department != null && p.department!.isNotEmpty) p.department!,
                if (p.isSharing) '共享中',
              ].join(' · ')),
            ),
            const Divider(height: 1),
            if (_c.isHost && p.userId != _c.selfUserId)
              ListTile(
                leading: Icon(p.micOn ? Icons.mic_off : Icons.mic),
                title: Text(p.micOn ? '静音该成员' : '解除静音'),
                onTap: () {
                  Navigator.pop(ctx);
                  _c.hostMute(p.userId, p.micOn);
                },
              ),
            if (_c.isHost && p.userId != _c.selfUserId)
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: const Text('移出会议'),
                textColor: const Color(0xFFE5484D),
                iconColor: const Color(0xFFE5484D),
                onTap: () {
                  Navigator.pop(ctx);
                  _c.hostRemove(p.userId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('关闭'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }
}

/// 居中提示块
class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.title, this.child});

  final IconData icon;
  final String title;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 54, color: const Color(0xFF5A6069)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.6,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (child != null) child!,
          ],
        ),
      ),
    );
  }
}
