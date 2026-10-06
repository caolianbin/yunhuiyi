import 'dart:async';

// ⚠️ 这个包没有 signalr_netcore.dart 这个"伞文件"，
//    HubConnection / HubConnectionBuilder / HttpConnectionOptions / HttpTransportType
//    全部由 signalr_client.dart 统一导出。
import 'package:signalr_netcore/signalr_client.dart';

import '../core/session.dart';
import '../models/models.dart';

/// 会议内事件回调。
///
/// 之所以用「带空实现的抽象类」而不是回调集合：
/// 后端广播有 19 种，用抽象类可以让调用方只覆写关心的那几个，
/// 且每个回调都是强类型，避免在字符串事件名上写错。
abstract class RoomEventListener {
  void onJoinResult(JoinResultPayload r) {}

  void onParticipantJoined(Participant p) {}

  void onParticipantLeft(Participant p) {}

  /// MediaStateChanged：音视频开关、共享状态变化
  void onMediaStateChanged(Participant p) {}

  void onRaiseHandChanged(Participant p) {}

  void onRoleChanged(Participant p) {}

  /// 等候室队列变化（有人在等待 / 已被处理）
  void onWaitingRoomChanged(Participant p) {}

  void onAdmitted() {}

  void onDenied(String reason) {}

  void onKicked(String reason) {}

  void onMeetingEnded() {}

  void onMeetingLockChanged(bool locked) {}

  /// 共享被他人抢占或被主持人停止
  void onShareStopped(ShareStoppedInfo info) {}

  void onChatReceived(ChatMessage m) {}

  void onReaction(Reaction r) {}

  void onHostNotice(HostNotice notice) {}

  void onPollCreated(Poll p) {}

  void onPollUpdated(Poll p) {}

  void onRecordingStateChanged(RecordingState s) {}

  /// connecting / connected / reconnecting / reconnected / disconnected
  void onConnectionState(String state) {}

  /// Hub 调用失败（如"会议已锁定""无权限"）
  void onHubError(String message) {}
}

/// SignalR 客户端。
///
/// 契约与后端 Hubs/MeetingHub.cs 一一对应。
/// 注意：SignalR 的「组」绑定在连接上，断线重连后组关系会丢失，
/// 因此 onreconnected 里必须重新调用 Rejoin(meetingId)，否则会静默收不到任何广播。
class SignalRService {
  SignalRService(this._session);

  final Session _session;

  HubConnection? _conn;
  RoomEventListener? _listener;
  int? _meetingId;
  bool _connecting = false;

  bool get isConnected => _conn?.state == HubConnectionState.Connected;

  /// 事件名 → 处理器是否已注册（重连时不要重复注册，否则同一条消息会触发多次）
  final Set<String> _bound = {};

  Future<void> connect(int meetingId, RoomEventListener listener) async {
    if (_connecting) return;
    _connecting = true;
    _meetingId = meetingId;
    _listener = listener;
    try {
      await _ensureConnection();
      await _invoke('JoinRoom', [meetingId]);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _ensureConnection() async {
    if (_conn != null && isConnected) return;
    if (_conn == null) {
      final token = _session.token;
      _conn = HubConnectionBuilder()
          .withUrl(
            _session.hubUrl,
            options: HttpConnectionOptions(
              // 后端 JwtBearerEvents 会从 query 读 access_token；
              // 同时用 accessTokenFactory 带上 Authorization 头，两条路都通，兼容不同部署。
              accessTokenFactory: () async => token ?? '',
              // 移动端 WebSocket 更稳定；失败时库会自动降级到长轮询
              transport: HttpTransportType.WebSockets,
            ),
          )
          .withAutomaticReconnect(retryDelays: [0, 2000, 5000, 10000, 15000])
          .build();

      _bindHubEvents();

      _conn!.onreconnecting(({error}) {
        _listener?.onConnectionState('reconnecting');
      });

      _conn!.onreconnected(({connectionId}) async {
        _listener?.onConnectionState('reconnected');
        // 重连后连接是新的，组关系已丢失 —— 必须重新入组
        final mid = _meetingId;
        if (mid != null) {
          try {
            await _invoke('Rejoin', [mid]);
          } catch (_) {
            // 重连后 Rejoin 失败不致命，后续状态由下一次广播补齐
          }
        }
      });

      _conn!.onclose(({error}) {
        _listener?.onConnectionState('disconnected');
      });
    }
    if (!isConnected) {
      await _conn!.start();
      _listener?.onConnectionState('connected');
    }
  }

  /// 注册全部服务端广播。使用 _bound 幂等，避免热重载/重连导致重复触发。
  void _bindHubEvents() {
    void bind(String name, void Function(dynamic arg) handler) {
      if (_bound.contains(name)) return;
      _bound.add(name);
      _conn!.on(name, (args) {
        try {
          handler(args != null && args.isNotEmpty ? args[0] : null);
        } catch (e) {
          _listener?.onHubError('处理 $name 事件失败：$e');
        }
      });
    }

    Map<String, dynamic> asMap(dynamic a) =>
        a is Map ? a.cast<String, dynamic>() : <String, dynamic>{};

    bind('JoinResult', (a) => _listener?.onJoinResult(JoinResultPayload.fromJson(asMap(a))));
    bind('ParticipantJoined', (a) => _listener?.onParticipantJoined(Participant.fromJson(asMap(a))));
    bind('ParticipantLeft', (a) => _listener?.onParticipantLeft(Participant.fromJson(asMap(a))));
    bind('MediaStateChanged', (a) => _listener?.onMediaStateChanged(Participant.fromJson(asMap(a))));
    bind('RaiseHandChanged', (a) => _listener?.onRaiseHandChanged(Participant.fromJson(asMap(a))));
    bind('ParticipantRoleChanged', (a) => _listener?.onRoleChanged(Participant.fromJson(asMap(a))));

    bind('WaitingRoomChanged', (a) {
      final m = asMap(a);
      _listener?.onWaitingRoomChanged(Participant.fromJson(asMap(m['waiting'])));
    });

    bind('Admitted', (_) => _listener?.onAdmitted());
    bind('Denied', (a) => _listener?.onDenied(_msg(asMap(a), '主持人拒绝了你的入会申请')));
    bind('Kicked', (a) => _listener?.onKicked(_msg(asMap(a), '你已被移出会议')));
    bind('MeetingEnded', (_) => _listener?.onMeetingEnded());

    bind('MeetingLockChanged', (a) {
      final m = asMap(a);
      _listener?.onMeetingLockChanged(m['locked'] == true);
    });

    bind('ShareStopped', (a) => _listener?.onShareStopped(ShareStoppedInfo.fromJson(asMap(a))));
    bind('ChatReceived', (a) => _listener?.onChatReceived(ChatMessage.fromJson(asMap(a))));
    bind('ReactionReceived', (a) => _listener?.onReaction(Reaction.fromJson(asMap(a))));
    bind('HostNotice', (a) => _listener?.onHostNotice(HostNotice.fromJson(asMap(a))));
    bind('PollCreated', (a) => _listener?.onPollCreated(Poll.fromJson(asMap(a))));
    bind('PollUpdated', (a) => _listener?.onPollUpdated(Poll.fromJson(asMap(a))));
    bind('RecordingStateChanged',
        (a) => _listener?.onRecordingStateChanged(RecordingState.fromJson(asMap(a))));
  }

  static String _msg(Map<String, dynamic> m, String fallback) {
    final s = m['reason'] ?? m['message'];
    return (s == null || s.toString().isEmpty) ? fallback : s.toString();
  }

  Future<void> _invoke(String method, List<Object> args) async {
    final conn = _conn;
    if (conn == null) throw StateError('未连接');
    try {
      await conn.invoke(method, args: args);
    } on Exception catch (e) {
      // HubException 会以异常形式抛出，把后端的中文提示原样透出
      final text = e.toString().replaceFirst('Exception: ', '');
      _listener?.onHubError(text);
      rethrow;
    }
  }

  // ==================== 参会状态 ====================

  Future<void> joinRoom(int meetingId) => _invoke('JoinRoom', [meetingId]);

  Future<void> rejoin(int meetingId) => _invoke('Rejoin', [meetingId]);

  Future<void> leaveMeeting(int meetingId) => _invoke('LeaveMeeting', [meetingId]);

  /// 上报媒体状态。只为"确实变化的字段"传值，避免把服务端状态覆盖回旧值。
  Future<void> updateMedia(int meetingId, MediaStatePayload state) =>
      _invoke('UpdateMedia', [meetingId, state.toJson()]);

  Future<void> raiseHand(int meetingId, bool raised) =>
      _invoke('RaiseHand', [{'meetingId': meetingId, 'raised': raised}]);

  Future<void> sendReaction(int meetingId, String emoji) =>
      _invoke('SendReaction', [{'meetingId': meetingId, 'emoji': emoji}]);

  Future<void> sendChat({
    required int meetingId,
    required String content,
    String type = 'text',
    String? fileUrl,
    int? toUserId,
  }) =>
      _invoke('SendChat', [
        {
          'meetingId': meetingId,
          'type': type,
          'content': content,
          if (fileUrl != null) 'fileUrl': fileUrl,
          if (toUserId != null) 'toUserId': toUserId,
        }
      ]);

  // ==================== 主持人管控 ====================

  Future<void> hostMute(int meetingId, int targetUserId) =>
      _invoke('HostMute', [{'meetingId': meetingId, 'targetUserId': targetUserId}]);

  Future<void> hostUnmute(int meetingId, int targetUserId) =>
      _invoke('HostUnmute', [{'meetingId': meetingId, 'targetUserId': targetUserId}]);

  Future<void> hostMuteAll(int meetingId) => _invoke('HostMuteAll', [meetingId]);

  Future<void> hostUnmuteAll(int meetingId) => _invoke('HostUnmuteAll', [meetingId]);

  Future<void> hostRemove(int meetingId, int targetUserId) =>
      _invoke('HostRemove', [{'meetingId': meetingId, 'targetUserId': targetUserId}]);

  /// role: cohost / participant / viewer
  Future<void> hostSetRole(int meetingId, int targetUserId, String role) =>
      _invoke('HostSetRole', [
        {'meetingId': meetingId, 'targetUserId': targetUserId},
        role,
      ]);

  Future<void> hostAdmit(int meetingId, int targetUserId) =>
      _invoke('HostAdmit', [{'meetingId': meetingId, 'targetUserId': targetUserId}]);

  Future<void> hostDeny(int meetingId, int targetUserId) =>
      _invoke('HostDeny', [{'meetingId': meetingId, 'targetUserId': targetUserId}]);

  Future<void> hostToggleLock(int meetingId, bool locked) =>
      _invoke('HostToggleLock', [meetingId, locked]);

  Future<void> hostEndMeeting(int meetingId) => _invoke('HostEndMeeting', [meetingId]);

  // ==================== 投票 / 录制 ====================

  Future<void> hostCreatePoll(int meetingId, String title, List<String> options) =>
      _invoke('HostCreatePoll', [
        {'meetingId': meetingId, 'title': title, 'options': options}
      ]);

  Future<void> votePoll(int meetingId, int pollId, int optionIndex) => _invoke('VotePoll', [
        {'meetingId': meetingId, 'pollId': pollId, 'optionIndex': optionIndex}
      ]);

  Future<void> hostClosePoll(int meetingId, int pollId) =>
      _invoke('HostClosePoll', [meetingId, pollId]);

  Future<void> notifyRecording(int meetingId, String mode, bool started) =>
      _invoke('NotifyRecording', [meetingId, mode, started]);

  Future<void> dispose() async {
    await _conn?.stop();
    _conn = null;
    _bound.clear();
    _listener = null;
    _meetingId = null;
  }
}
