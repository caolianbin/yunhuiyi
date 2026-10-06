import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';

import '../core/api_client.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import '../models/models.dart';
import '../services/meeting_service.dart';
import '../services/rtc_service.dart';
import '../services/signalr_service.dart';

/// 房间生命周期
enum RoomPhase {
  /// 正在校验/连接
  connecting,

  /// 已在等候室等待主持人批准
  waiting,

  /// 已进入会议
  joined,

  /// 已离开（被踢/会议结束/主动退出）
  left,

  /// 出错（无法进入）
  error,
}

/// 会议页的状态中枢。
///
/// 职责划分：
///   SignalR → 会议业务状态（成员、共享标记、聊天、管控）
///   TRTC    → 媒体流（谁有画面、谁在共享、扬声器路由）
///   本类    → 把两者的 userId 对齐，并暴露给 UI
class RoomController extends ChangeNotifier implements RoomEventListener, RtcEventListener {
  RoomController({
    required Session session,
    required ApiClient api,
    required MeetingService meetings,
  })  : _session = session,
        _meetings = meetings {
    _signalr = SignalRService(session);
    _rtc = RtcService();
    _selfUserId = session.user?.id ?? 0;
  }

  final Session _session;
  final MeetingService _meetings;
  late final SignalRService _signalr;
  late final RtcService _rtc;

  int _selfUserId = 0;
  int get selfUserId => _selfUserId;

  // ---------- 基础信息 ----------
  Meeting? meeting;
  RoomPhase phase = RoomPhase.connecting;
  String? errorMessage;

  /// 允许进入的会议 ID
  int meetingId = 0;

  bool waitingRoomEnabled = false;
  bool isLocked = false;
  bool isPausedByHost = false;

  // ---------- 成员 ----------
  final Map<int, Participant> participants = {};
  final Map<int, Participant> waitingList = {};

  // ---------- 本端媒体状态 ----------
  bool micOn = true;
  bool cameraOn = true;
  bool frontCamera = true;
  bool isSharing = false;
  bool rtcEntered = false;
  bool rtcConfigured = false;
  String? rtcDisabledReason;
  bool speakerOn = true;

  /// 已请求共享、正在等用户在系统弹窗上确认。
  ///
  /// 从"点了共享"到"真的在共享"中间**必然**有一段空档：安卓要等用户在
  /// MediaProjection 授权框上点「开始录制」，iOS 要等用户点「开始直播」。
  /// 没有这个中间态的话，用户在弹窗上点「取消」后按钮会永远停在"停止共享"，
  /// 也就是那种"点了没反应"的假死状态。
  ///
  /// 真正开始的权威信号是 TRTC 的 `onScreenCaptureStarted` 回调。
  bool sharePending = false;

  Timer? _sharePendingTimer;

  /// 开始共享**之前**的摄像头状态。
  ///
  /// 共享时会临时关掉摄像头（省带宽），结束共享时要还原成原样 ——
  /// 不能无脑打开：用户可能本来就关着摄像头，只想共享屏幕。
  bool _cameraWasOnBeforeShare = false;

  // ---------- 远端媒体可用性 ----------
  final Map<String, bool> videoAvailable = {};
  final Map<String, bool> subAvailable = {};
  final Map<String, int> voiceVolume = {};

  // ---------- 视图 id（Flutter 侧原生视图句柄） ----------
  int? localViewId;
  final Map<String, int> remoteViewIds = {};
  final Map<String, int> subViewIds = {};
  final Set<String> _attached = {};

  /// 当前共享者 userId（含自己）。来自 TRTC 辅流 + SignalR 共享标记的并集。
  String? activeShareUserId;
  String? activeShareType;

  // ---------- 聊天 / 投票 ----------
  final List<ChatMessage> messages = [];
  final List<Poll> polls = [];

  // ---------- 一次性提示（SnackBar） ----------
  String? toast;
  int toastTick = 0;

  /// 当前提示是否要带一个「去设置」按钮（权限被永久拒绝时用）。
  /// 没有这个入口的话，用户误点一次「拒绝」就只能卸载重装。
  bool toastNeedsSettings = false;

  String? endReason;

  bool get isHost => _self().isHost;
  bool get isScreenShareSupported => Platform.isAndroid || Platform.isIOS;

  bool get isMyShareActive =>
      activeShareUserId != null && activeShareUserId == _selfUserId.toString();

  /// 共享舞台显示谁：优先自己（我在共享），其次任何在共享的人
  String? get stageUserId {
    if (isMyShareActive) return _selfUserId.toString();
    final sid = activeShareUserId;
    if (sid == null) return null;
    // 只有真的收到辅流才能显示画面，否则只显示"某人在共享"的提示
    return sid;
  }

  bool get stageHasVideo {
    final sid = stageUserId;
    if (sid == null) return false;
    if (sid == _selfUserId.toString()) return false; // 自己共享时本地不显示回显
    return subAvailable[sid] == true;
  }

  List<Participant> get joinedParticipants =>
      participants.values.where((p) => !p.inWaitingRoom).toList()
        ..sort((a, b) {
          if (a.userId == _selfUserId) return -1;
          if (b.userId == _selfUserId) return 1;
          if (a.isHost != b.isHost) return a.isHost ? -1 : 1;
          return a.nickname.compareTo(b.nickname);
        });

  Participant _self() =>
      participants[_selfUserId] ??
      Participant(userId: _selfUserId, nickname: _session.user?.nickname ?? '我');

  String nicknameOf(int userId) => participants[userId]?.nickname ?? '参会人';

  void clearToast() {
    toast = null;
    notifyListeners();
  }

  void _show(String msg, {bool needsSettings = false}) {
    toast = msg;
    toastNeedsSettings = needsSettings;
    toastTick++;
    notifyListeners();
  }

  // ==================================================================
  //  进入 / 离开
  // ==================================================================

  /// 进入会议。
  ///
  /// 顺序很重要：后端 JoinRoom 要求「参会记录已存在」（读作"请先通过会议入口验证后加入"），
  /// 所以必须先走 REST /api/meetings/join 落库，再连 SignalR 入组。
  /// [password] 为会议密码；会议需要密码而缺失时，REST 会返回「会议密码错误」，
  /// 由页面弹出密码输入框后带着密码重试。
  Future<void> start(int meetingId, {String? password}) async {
    this.meetingId = meetingId;
    phase = RoomPhase.connecting;
    errorMessage = null;
    notifyListeners();

    // 0) 权限先行。
    //    Android 上不申请 CAMERA / RECORD_AUDIO，TRTC 会静默失败：
    //    报 -1314（摄像头未授权）/ -1317（麦克风未授权），
    //    现象是「能进会议、能看到别人，自己却黑屏无声」，且不弹任何系统框。
    //    申请结果决定本地摄像头/麦克风是否打开——被拒也照常进会议，仍能看和听别人。
    final perm = await AppPermissions.requestForMeeting();
    cameraOn = perm.camera;
    micOn = perm.microphone;
    final permHint = perm.message;
    if (permHint != null) _show(permHint, needsSettings: true);
    notifyListeners();

    try {
      meeting = await _meetings.getById(meetingId);
      waitingRoomEnabled = meeting?.waitingRoomEnabled ?? false;
      isLocked = meeting?.isLocked ?? false;
      notifyListeners();
    } catch (_) {
      // 会议信息拿不到不致命，继续尝试加入
    }

    // 1) REST 校验入口（建参会记录 / 校验密码 / 判断是否需要等候室）
    try {
      final number = meeting?.meetingNo ?? '';
      if (number.isNotEmpty) {
        await _meetings.join(number, password: password);
      }
    } on ApiException catch (e) {
      phase = RoomPhase.error;
      errorMessage = e.message;
      notifyListeners();
      return;
    } catch (e) {
      phase = RoomPhase.error;
      errorMessage = '无法加入会议：${_cleanErr(e)}';
      notifyListeners();
      return;
    }

    // 2) 连 SignalR 并入组，拿到服务端权威的成员列表
    try {
      await _signalr.connect(meetingId, this);
    } on Exception catch (e) {
      phase = RoomPhase.error;
      errorMessage = '无法连接会议服务：${_cleanErr(e)}';
      notifyListeners();
      return;
    }
  }

  /// 媒体通道初始化（JoinResult=joined 之后才做）
  Future<void> _enterMedia() async {
    try {
      final cfg = await _meetings.rtcConfig();
      rtcConfigured = cfg.enabled;
      rtcDisabledReason = cfg.reason;
      if (!cfg.enabled) {
        notifyListeners();
        return;
      }
      final sig = await _meetings.rtcUserSig();
      await _rtc.init(this);

      // ⚠️ 必须用服务端返回的 userId 进房：
      //    签名是针对该 userId 计算的，用本地的 id 与之不一致会以
      //    userSig 校验失败被拒（-100018）。
      await _rtc.enterRoom(
        sdkAppId: cfg.sdkAppId,
        userId: sig.userId,
        userSig: sig.userSig,
        roomId: meetingId,
      );
      // 进房即开麦并强制扬声器。
      // micOn 已由 start() 里的权限申请结果决定：没麦克风权限就别开，
      // 否则只会换来一个 -1317（麦克风未授权）的报错提示。
      if (micOn) {
        await _rtc.startLocalAudio();
      }
      notifyListeners();
    } catch (e) {
      rtcConfigured = false;
      rtcDisabledReason = '音视频初始化失败：${_cleanErr(e)}';
      notifyListeners();
    }
  }

  static String _cleanErr(Object e) =>
      e is ApiException ? e.message : e.toString().replaceFirst('Exception: ', '');

  /// 离开会议（主动）
  Future<void> leave() async {
    try {
      if (rtcEntered) await _rtc.exitRoom();
    } catch (_) {}
    try {
      await _signalr.leaveMeeting(meetingId);
    } catch (_) {}
    try {
      await _meetings.leave(meetingId);
    } catch (_) {}
    await _teardown();
    phase = RoomPhase.left;
    notifyListeners();
  }

  Future<void> _teardown() async {
    // 放在最前面、且在任何 await 之前：dispose() 是不 await 它的，
    // 放后面会让计时器多活一小会儿，可能在控制器已销毁后回调。
    _clearSharePending();
    try {
      await _rtc.dispose();
    } catch (_) {}
    try {
      await _signalr.dispose();
    } catch (_) {}
    rtcEntered = false;
    isSharing = false;
    sharePending = false;
    activeShareUserId = null;
    remoteViewIds.clear();
    subViewIds.clear();
    _attached.clear();
  }

  @override
  void dispose() {
    _clearSharePending();
    _teardown();
    super.dispose();
  }

  // ==================================================================
  //  SignalR 事件
  // ==================================================================

  @override
  void onConnectionState(String state) {
    if (state == 'reconnected') {
      // 重连后 TRTC 仍在房里，但服务端成员快照可能已变，拉一次最新名单兜底
      _refreshParticipants();
    }
  }

  Future<void> _refreshParticipants() async {
    try {
      final list = await _meetings.participants(meetingId);
      for (final p in list) {
        participants[p.userId] = p;
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  void onJoinResult(JoinResultPayload r) {
    if (r.status == 'waiting') {
      phase = RoomPhase.waiting;
      if (r.self != null) waitingList[r.self!.userId] = r.self!;
      notifyListeners();
      return;
    }
    if (r.status != 'joined') {
      phase = RoomPhase.error;
      errorMessage = r.message ?? '无法加入会议';
      notifyListeners();
      return;
    }

    if (r.meeting != null) {
      meeting = r.meeting;
      waitingRoomEnabled = meeting?.waitingRoomEnabled ?? false;
      isLocked = meeting?.isLocked ?? false;
    }
    for (final p in r.participants) {
      participants[p.userId] = p;
    }
    // 等候室成员单独维护
    participants.removeWhere((k, v) => v.inWaitingRoom);
    if (r.self != null) {
      participants[r.self!.userId] = r.self!;
    }
    // 服务端已有共享标记时同步舞台（避免后进房的人看不到正在进行的共享）
    for (final p in r.participants) {
      if (p.isSharing) {
        activeShareUserId = p.userId.toString();
        activeShareType = p.shareType ?? 'screen';
      }
    }

    phase = RoomPhase.joined;
    notifyListeners();

    _enterMedia();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final msgs = await _meetings.messages(meetingId);
      messages
        ..clear()
        ..addAll(msgs);
      final pl = await _meetings.polls(meetingId);
      polls
        ..clear()
        ..addAll(pl);
      notifyListeners();
    } catch (_) {}
  }

  @override
  void onParticipantJoined(Participant p) {
    if (p.inWaitingRoom) {
      waitingList[p.userId] = p;
    } else {
      waitingList.remove(p.userId);
      participants[p.userId] = p;
    }
    notifyListeners();
  }

  @override
  void onParticipantLeft(Participant p) {
    participants.remove(p.userId);
    waitingList.remove(p.userId);
    videoAvailable.remove(p.userId.toString());
    subAvailable.remove(p.userId.toString());
    remoteViewIds.remove(p.userId.toString());
    subViewIds.remove(p.userId.toString());
    if (activeShareUserId == p.userId.toString()) {
      activeShareUserId = null;
      activeShareType = null;
    }
    notifyListeners();
  }

  @override
  void onMediaStateChanged(Participant p) {
    participants[p.userId] = p;
    // 共享状态以服务端为准修正舞台
    if (p.isSharing) {
      activeShareUserId = p.userId.toString();
      activeShareType = p.shareType ?? 'screen';
    } else if (activeShareUserId == p.userId.toString()) {
      activeShareUserId = null;
      activeShareType = null;
      subAvailable.remove(p.userId.toString());
    }
    // 主持人硬静音了我 → 本端必须真的停止上行，否则别人还能听见我
    if (p.userId == _selfUserId && p.hardMuted && micOn) {
      micOn = false;
      _rtc.muteLocalAudio(true);
      _show('你已被主持人静音');
    }
    notifyListeners();
  }

  @override
  void onRaiseHandChanged(Participant p) {
    participants[p.userId] = p;
    notifyListeners();
  }

  @override
  void onRoleChanged(Participant p) {
    participants[p.userId] = p;
    if (p.userId == _selfUserId) _show('你的角色已变更为 ${p.role}');
    notifyListeners();
  }

  @override
  void onWaitingRoomChanged(Participant p) {
    waitingList[p.userId] = p;
    if (isHost) _show('${p.nickname} 正在等候室等待');
    notifyListeners();
  }

  @override
  void onAdmitted() {
    phase = RoomPhase.joined;
    notifyListeners();
    _enterMedia();
    _loadHistory();
  }

  @override
  void onDenied(String reason) {
    phase = RoomPhase.error;
    errorMessage = reason;
    _teardown();
    notifyListeners();
  }

  @override
  void onKicked(String reason) {
    endReason = reason;
    phase = RoomPhase.left;
    _teardown();
    notifyListeners();
  }

  @override
  void onMeetingEnded() {
    endReason = '会议已结束';
    phase = RoomPhase.left;
    _teardown();
    notifyListeners();
  }

  @override
  void onMeetingLockChanged(bool locked) {
    isLocked = locked;
    _show(locked ? '会议已锁定，新成员无法加入' : '会议已解锁');
    notifyListeners();
  }

  @override
  void onShareStopped(ShareStoppedInfo info) {
    final wasMine = info.participantId == _selfUserId;
    if (wasMine) {
      // 自己的共享被抢占/被主持人停止：必须真的停掉上行，否则画面还在推
      _stopLocalShare(silent: true);
    }
    if (activeShareUserId == info.participantId.toString()) {
      activeShareUserId = null;
      activeShareType = null;
      subAvailable.remove(info.participantId.toString());
    }
    if (info.message.isNotEmpty) _show(info.message);
    notifyListeners();
  }

  @override
  void onChatReceived(ChatMessage m) {
    messages.add(m);
    notifyListeners();
  }

  @override
  void onReaction(Reaction r) {
    _show('${r.nickname} ${r.emoji}');
  }

  @override
  void onHostNotice(HostNotice n) {
    if (n.type == 'ended') {
      endReason = n.message;
      phase = RoomPhase.left;
      _teardown();
      notifyListeners();
      return;
    }
    if (n.message.isNotEmpty) _show(n.message);
  }

  @override
  void onPollCreated(Poll p) {
    polls.add(p);
    _show('新投票：${p.title}');
    notifyListeners();
  }

  @override
  void onPollUpdated(Poll p) {
    final i = polls.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      polls[i] = p;
    } else {
      polls.add(p);
    }
    notifyListeners();
  }

  @override
  void onRecordingStateChanged(RecordingState s) {
    _show(s.started ? '录制已开始（${s.mode}）' : '录制已结束');
  }

  @override
  void onHubError(String message) => _show(message);

  // ==================================================================
  //  TRTC 事件
  // ==================================================================

  @override
  void onEnterRoom(int result) {
    if (result > 0) {
      rtcEntered = true;
      notifyListeners();
      // 进房成功后把当前已知的共享者订阅上
      _syncStage();
    } else {
      rtcConfigured = false;
      rtcDisabledReason = '进入音视频房间失败（错误码 $result）';
      notifyListeners();
    }
  }

  @override
  void onExitRoom(int reason) {
    rtcEntered = false;
    notifyListeners();
  }

  @override
  void onUserVideoAvailable(String userId, bool available) {
    videoAvailable[userId] = available;
    if (available) {
      _attachStream(userId, TRTCVideoStreamType.big);
    } else {
      _detachStream(userId, TRTCVideoStreamType.big);
    }
    notifyListeners();
  }

  @override
  void onUserSubStreamAvailable(String userId, bool available) {
    subAvailable[userId] = available;
    if (available) {
      activeShareUserId = userId;
      activeShareType = 'screen';
      _attachStream(userId, TRTCVideoStreamType.sub);
    } else {
      _detachStream(userId, TRTCVideoStreamType.sub);
      if (activeShareUserId == userId) {
        activeShareUserId = null;
        activeShareType = null;
      }
    }
    notifyListeners();
  }

  @override
  void onUserAudioAvailable(String userId, bool available) {
    final p = participants[int.tryParse(userId) ?? 0];
    if (p != null) participants[p.userId] = p.copyWith(micOn: available);
    notifyListeners();
  }

  @override
  void onRemoteUserEnter(String userId) {
    // TRTC 侧有人进房：业务状态由 SignalR 维护，这里只做视图占位
    notifyListeners();
  }

  @override
  void onRemoteUserLeave(String userId) {
    videoAvailable.remove(userId);
    subAvailable.remove(userId);
    remoteViewIds.remove(userId);
    subViewIds.remove(userId);
    _attached.removeWhere((k) => k.startsWith('$userId-'));
    if (activeShareUserId == userId) {
      activeShareUserId = null;
      activeShareType = null;
    }
    notifyListeners();
  }

  @override
  void onFirstVideoFrame(String? userId, TRTCVideoStreamType streamType) {
    // 首帧到达说明画面真的在渲染，此时停止对该路的重复绑定
  }

  @override
  void onScreenCaptureStarted() {
    // ★ 这是「真的开始共享」的唯一权威信号。
    //   两个平台的系统弹窗都要用户点一下才真正开始采集，所以「上报服务端」和
    //   「提示用户」都必须放在这里，而不是放在点了按钮的那一刻 ——
    //   否则用户只要一点「取消」，服务端就已经认为你在共享了，别人会一直等你画面。
    _clearSharePending();
    isSharing = true;
    notifyListeners();
    _reportMedia(MediaStatePayload(
      isSharing: true,
      shareType: 'screen',
      cameraOn: false,
    ));
    _show('屏幕共享已开始');
  }

  @override
  void onScreenCaptureStopped(int reason) {
    _clearSharePending();
    isSharing = false;
    notifyListeners();
  }

  @override
  void onVoiceVolume(Map<String, int> volumes) {
    voiceVolume
      ..clear()
      ..addAll(volumes);
    // 音量回调间隔 300ms，用于把正在说话的人框出来。
    // 直接 notifyListeners 让相关方块重建；错误处理成"多说一句话就多刷一帧"的代价可接受。
    notifyListeners();
  }

  /// userId → 是否正在说话（阈值取 12，避免呼吸声就点亮）
  bool isSpeaking(int userId) {
    final v = voiceVolume[userId.toString()] ?? 0;
    return v > 12;
  }

  @override
  void onError(int errCode, String errMsg) {
    if (errCode == -1308) {
      // 录屏授权被拒 / 录屏启动失败：复位本地共享状态，
      // 否则按钮会一直停在"等待确认…"或"停止共享"。
      _stopLocalShare(silent: true);
    }
    // ⚠️ 把 SDK 自带的 errMsg 一起传进去。遇到没收录的错误码时，
    //    这句原文是唯一能指明方向的信息 —— 只丢一个数字给用户等于没提示。
    _show(describeTrtcError(errCode, errMsg: errMsg));
  }

  @override
  void onWarning(int warningCode, String warningMsg) {
    // 警告多为网络波动，不打扰用户
  }

  // ==================================================================
  //  视图绑定
  // ==================================================================

  void onLocalViewCreated(int viewId) {
    localViewId = viewId;
    // 视图就绪即可开预览（不必等进房成功）：用户能立刻在本地看到自己，
    // 也能第一时间暴露"摄像头权限被拒"这类问题。
    if (cameraOn) {
      _rtc.startLocalPreview(viewId);
    }
  }

  void onRemoteViewCreated(String userId, int viewId) {
    remoteViewIds[userId] = viewId;
    _attached.remove('$userId-${TRTCVideoStreamType.big.name}');
    _attachStream(userId, TRTCVideoStreamType.big);
  }

  void onSubViewCreated(String userId, int viewId) {
    subViewIds[userId] = viewId;
    _attached.remove('$userId-${TRTCVideoStreamType.sub.name}');
    _attachStream(userId, TRTCVideoStreamType.sub);
  }

  /// 真正调用 startRemoteView。
  ///
  /// "视图 id" 与 "流的可用性" 来自两个异步来源（Flutter 视图树 / TRTC 事件），
  /// 谁先到不确定，所以两边任意一侧发生变化都调用本方法重试一次，直到成功为止
  /// —— 比记住"先有视图还是先有流"要可靠得多。
  void _attachStream(String userId, TRTCVideoStreamType streamType) {
    if (!rtcEntered || userId.isEmpty) return;
    final isSub = streamType == TRTCVideoStreamType.sub;
    final viewId = isSub ? subViewIds[userId] : remoteViewIds[userId];
    final available = isSub ? subAvailable[userId] : videoAvailable[userId];
    if (viewId == null || available != true) return;

    // key 必须与 onRemoteViewCreated/onSubViewCreated 里的失效 key 写法一致，
    // 统一用枚举的 name，避免"插值出 TRTCVideoStreamType.big 却按 big 去删"导致去重失效。
    final key = '$userId-${streamType.name}';
    if (_attached.contains(key)) return;
    _attached.add(key);
    _rtc.startRemoteView(userId, streamType, viewId).catchError((_) {
      _attached.remove(key); // 失败后允许下次状态变化时重试
    });
  }

  void _detachStream(String userId, TRTCVideoStreamType streamType) {
    final key = '$userId-${streamType.name}';
    _attached.remove(key);
    _rtc.stopRemoteView(userId, streamType);
  }

  void _syncStage() {
    final sid = activeShareUserId;
    if (sid != null && subAvailable[sid] == true) {
      _attachStream(sid, TRTCVideoStreamType.sub);
    }
    for (final p in joinedParticipants) {
      if (p.userId == _selfUserId) continue;
      final uid = p.userId.toString();
      if (videoAvailable[uid] == true) {
        _attachStream(uid, TRTCVideoStreamType.big);
      }
    }
  }

  // ==================================================================
  //  本地媒体操作
  // ==================================================================

  Future<void> toggleMic() async {
    if (_self().hardMuted) {
      _show('你已被主持人静音，无法自行开启');
      return;
    }
    final next = !micOn;
    micOn = next;
    notifyListeners();
    await _rtc.muteLocalAudio(!next);
    await _reportMedia(MediaStatePayload(micOn: next));
  }

  Future<void> toggleCamera() async {
    final next = !cameraOn;
    cameraOn = next;
    // 共享期间用户手动改过摄像头 → 以用户最后的意愿为准，
    // 别在停止共享时又把它"还原"回去。
    if (isSharing || sharePending) _cameraWasOnBeforeShare = next;
    notifyListeners();
    await _rtc.setCameraEnabled(next);
    await _reportMedia(MediaStatePayload(cameraOn: next));
  }

  Future<void> switchCamera() async {
    await _rtc.switchCamera();
    frontCamera = _rtc.isFrontCamera;
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    notifyListeners();
    await _rtc.setSpeakerOn(speakerOn);
    _show(speakerOn ? '已切换到扬声器' : '已切换到听筒');
  }

  /// 开始 / 停止屏幕共享
  Future<void> toggleShare() async {
    // sharePending 也按"共享中"处理：用户已经点了共享、系统弹窗还开着，
    // 这时再点一下应当算取消，否则会重复请求一次录屏授权。
    if (isSharing || sharePending) {
      await _stopLocalShare();
      return;
    }
    if (!rtcEntered) {
      _show('音视频尚未就绪，暂时无法共享屏幕');
      return;
    }
    // Android 13+ 需要通知权限，否则前台服务的「正在共享屏幕」通知不显示，
    // 用户会以为没在共享。功能不受影响，属于体验层面的兜底。
    await AppPermissions.requestNotificationIfNeeded();
    try {
      // 先进入"等待确认"状态，再去发起请求。
      //
      // ⚠️ 顺序很讲究：如果等 startScreenCapture() 返回后再置位，中间隔着一次
      //    await（微任务跳转），理论上存在"回调先到、状态后置"的竞态。
      //    先置位就完全不会有这个问题，而且用户点下去立刻能看到反馈。
      sharePending = true;
      notifyListeners();

      // 共享时关掉摄像头，避免主路+辅路两路视频同时占带宽。
      // 先记下原来的状态：用户本来就把摄像头关着的话，共享结束后不能替他打开。
      _cameraWasOnBeforeShare = cameraOn;
      if (cameraOn) {
        cameraOn = false;
        await _rtc.stopLocalPreview();
      }
      final trigger = await _rtc.startScreenCapture();

      // ⚠️ 这里**不能**直接 isSharing = true。
      //    两个平台都还要等用户点一下系统弹窗（安卓「开始录制」/ iOS「开始直播」），
      //    真正开始的信号是 TRTC 的 onScreenCaptureStarted 回调。
      //    若在这一刻就置位，用户在弹窗上点「取消」后按钮会永远停在"停止共享"，
      //    看起来就是"点了没反应"。
      _armSharePendingTimeout(trigger);
      _show(trigger == ScreenShareTrigger.broadcastPicker
          ? '请在弹出的系统窗口里点一下「开始直播」'
          : '请在系统弹窗里点一下「开始录制」');
    } catch (e) {
      _clearSharePending();
      await _restoreCameraAfterShare();
      _show('屏幕共享启动失败：${_cleanErr(e)}');
    }
  }

  void _clearSharePending() {
    _sharePendingTimer?.cancel();
    _sharePendingTimer = null;
    sharePending = false;
  }

  /// 兜底计时器。
  ///
  /// 用户在系统弹窗上直接取消时，**不保证**一定会有回调过来：
  ///   · iOS：把系统录屏选择器划掉，不会有任何回调；
  ///   · Android：一般会走 `onError(-1308)`，但不同 ROM 上不保证。
  /// 没有兜底的话 `sharePending` 会一直挂着，按钮永远停在"等待确认…"，
  /// 用户会觉得 App 卡死了。
  ///
  /// 这个计时器是**安全**的：只要共享真的开始了，`onScreenCaptureStarted`
  /// 会先把它取消掉，所以不会误伤正在进行的共享。
  void _armSharePendingTimeout(ScreenShareTrigger trigger) {
    _sharePendingTimer?.cancel();
    // 安卓的系统授权框是即时的，给它短一点；iOS 用户可能还要先找一下那个选择器。
    final wait = trigger == ScreenShareTrigger.broadcastPicker
        ? const Duration(seconds: 60)
        : const Duration(seconds: 25);
    _sharePendingTimer = Timer(wait, () {
      if (!sharePending || isSharing) return;
      _stopLocalShare(silent: true);
      _show(trigger == ScreenShareTrigger.broadcastPicker
          ? '没有检测到共享开始。也可以从控制中心长按「录屏」按钮手动开启。'
          : '没有检测到共享开始，请重试并在系统弹窗里点「开始录制」。');
    });
  }

  Future<void> _stopLocalShare({bool silent = false}) async {
    if (!isSharing && !sharePending) return;
    _clearSharePending();
    try {
      await _rtc.stopScreenCapture();
    } catch (_) {}
    isSharing = false;
    notifyListeners();
    await _restoreCameraAfterShare();
    await _reportMedia(MediaStatePayload(
      isSharing: false,
      cameraOn: cameraOn,
    ));
    if (!silent) _show('屏幕共享已停止');
  }

  /// 共享结束后把摄像头恢复成**共享之前的样子**。
  ///
  /// ⚠️ 两个坑都在这里：
  ///  1. 只改 `cameraOn` 状态位是不够的 —— 开共享时真的调过 `stopLocalPreview()`，
  ///     这里必须真的重新 `startLocalPreview`（走 `setCameraEnabled(true)`）。
  ///     否则按钮显示「视频已开」、状态也上报成开，但自己画面一直是黑的：
  ///     别人看你就是个黑框，你自己还看不出来。
  ///  2. 也不能无脑打开 —— 用户本来就是关着摄像头的（只想共享屏幕），
  ///     共享结束后替他打开等于擅自改了他的状态。
  Future<void> _restoreCameraAfterShare() async {
    final restore = _cameraWasOnBeforeShare;
    cameraOn = restore;
    notifyListeners();
    await _rtc.setCameraEnabled(restore);
    notifyListeners();
  }

  Future<void> _reportMedia(MediaStatePayload payload) async {
    try {
      await _signalr.updateMedia(meetingId, payload);
    } catch (_) {
      // 状态上报失败不阻塞本地操作
    }
  }

  // ==================================================================
  //  会议内互动
  // ==================================================================

  Future<void> sendChat(String text, {String type = 'text', String? fileUrl, int? toUserId}) async {
    final content = text.trim();
    if (content.isEmpty && fileUrl == null) return;
    try {
      await _signalr.sendChat(
        meetingId: meetingId,
        content: content,
        type: type,
        fileUrl: fileUrl,
        toUserId: toUserId,
      );
    } on Exception catch (e) {
      _show(_cleanErr(e));
    }
  }

  Future<void> toggleRaiseHand() async {
    final me = _self();
    try {
      await _signalr.raiseHand(meetingId, !me.raisedHand);
    } on Exception catch (e) {
      _show(_cleanErr(e));
    }
  }

  Future<void> sendReaction(String emoji) async {
    try {
      await _signalr.sendReaction(meetingId, emoji);
    } catch (_) {}
  }

  // ==================================================================
  //  主持人操作
  // ==================================================================

  Future<void> hostMute(int userId, bool mute) => _guarded(() async {
        if (mute) {
          await _signalr.hostMute(meetingId, userId);
        } else {
          await _signalr.hostUnmute(meetingId, userId);
        }
      });

  Future<void> hostMuteAll(bool mute) => _guarded(() async {
        if (mute) {
          await _signalr.hostMuteAll(meetingId);
        } else {
          await _signalr.hostUnmuteAll(meetingId);
        }
      });

  Future<void> hostRemove(int userId) => _guarded(() async {
        await _signalr.hostRemove(meetingId, userId);
      });

  Future<void> hostSetRole(int userId, String role) => _guarded(() async {
        await _signalr.hostSetRole(meetingId, userId, role);
      });

  Future<void> hostAdmit(int userId) => _guarded(() async {
        await _signalr.hostAdmit(meetingId, userId);
        waitingList.remove(userId);
        notifyListeners();
      });

  Future<void> hostDeny(int userId) => _guarded(() async {
        await _signalr.hostDeny(meetingId, userId);
        waitingList.remove(userId);
        notifyListeners();
      });

  Future<void> hostToggleLock(bool locked) => _guarded(() async {
        await _signalr.hostToggleLock(meetingId, locked);
      });

  Future<void> hostEndMeeting() => _guarded(() async {
        await _signalr.hostEndMeeting(meetingId);
      });

  Future<void> hostCreatePoll(String title, List<String> options) => _guarded(() async {
        await _signalr.hostCreatePoll(meetingId, title, options);
      });

  Future<void> votePoll(int pollId, int optionIndex) => _guarded(() async {
        await _signalr.votePoll(meetingId, pollId, optionIndex);
      });

  Future<void> hostClosePoll(int pollId) => _guarded(() async {
        await _signalr.hostClosePoll(meetingId, pollId);
      });

  /// 把 HubException 的中文提示统一弹出来，避免"点了没反应"
  Future<void> _guarded(Future<void> Function() action) async {
    try {
      await action();
    } on Exception catch (e) {
      _show(_cleanErr(e));
    }
  }
}
