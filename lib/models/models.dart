import 'dart:convert';

/// 后端 DTO 的 Dart 映射。
///
/// 约定：ASP.NET Core 的 System.Text.Json 默认使用 camelCase，
/// SignalR 广播同样是 camelCase，因此这里统一按 camelCase 解析。
/// 所有解析都做了空值兜底，避免后端新增/缺失字段直接把 App 打崩。

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  final s = v.toString();
  if (s.isEmpty) return null;
  // 后端 DateTime.Now（Kind=Local）会带偏移；Kind=Unspecified 则不带时区，
  // DateTime.parse 对不带时区的串按本地时间处理，符合本场景。
  try {
    return DateTime.parse(s);
  } catch (_) {
    return null;
  }
}

String _str(dynamic v, [String fallback = '']) => v?.toString() ?? fallback;
int _int(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? fallback;
}

bool _bool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v?.toString().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return fallback;
}

// ==================== 用户 / 认证 ====================

class AppUser {
  final int id;
  final String username;
  final String nickname;
  final String? avatar;
  final String? department;
  final String pmi;
  final String? email;
  final bool isAdmin;

  const AppUser({
    required this.id,
    required this.username,
    required this.nickname,
    this.avatar,
    this.department,
    this.pmi = '',
    this.email,
    this.isAdmin = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: _int(j['id']),
        username: _str(j['username']),
        nickname: _str(j['nickname']),
        avatar: j['avatar'] as String?,
        department: j['department'] as String?,
        pmi: _str(j['pmi']),
        email: j['email'] as String?,
        isAdmin: _bool(j['isAdmin']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'nickname': nickname,
        'avatar': avatar,
        'department': department,
        'pmi': pmi,
        'email': email,
        'isAdmin': isAdmin,
      };

  AppUser copyWith({String? nickname, String? department, String? email, String? avatar}) =>
      AppUser(
        id: id,
        username: username,
        nickname: nickname ?? this.nickname,
        avatar: avatar ?? this.avatar,
        department: department ?? this.department,
        pmi: pmi,
        email: email ?? this.email,
        isAdmin: isAdmin,
      );
}

class AuthResult {
  final int userId;
  final String token;
  final AppUser user;

  const AuthResult({required this.userId, required this.token, required this.user});

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        userId: _int(j['userId']),
        token: _str(j['token']),
        user: AppUser.fromJson((j['user'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

// ==================== 会议 ====================

class Meeting {
  final int id;
  final String meetingNo;
  final String inviteCode;
  final String subject;
  final String? description;
  final int hostId;
  final String? hostName;
  final String? hostAvatar;
  final DateTime? startTime;
  final DateTime? liveStartedAt;
  final int durationMinutes;

  /// waiting / ongoing / ended
  final String status;
  final bool isLive;
  final bool isLocked;
  final bool waitingRoomEnabled;
  final bool watermarkEnabled;
  final bool hasPassword;
  final String? recurrence;
  final int participantCount;
  final String inviteLink;

  const Meeting({
    required this.id,
    required this.meetingNo,
    this.inviteCode = '',
    required this.subject,
    this.description,
    required this.hostId,
    this.hostName,
    this.hostAvatar,
    this.startTime,
    this.liveStartedAt,
    this.durationMinutes = 60,
    this.status = 'waiting',
    this.isLive = false,
    this.isLocked = false,
    this.waitingRoomEnabled = false,
    this.watermarkEnabled = false,
    this.hasPassword = false,
    this.recurrence,
    this.participantCount = 0,
    this.inviteLink = '',
  });

  factory Meeting.fromJson(Map<String, dynamic> j) => Meeting(
        id: _int(j['id']),
        meetingNo: _str(j['meetingNo']),
        inviteCode: _str(j['inviteCode']),
        subject: _str(j['subject'], '未命名会议'),
        description: j['description'] as String?,
        hostId: _int(j['hostId']),
        hostName: j['hostName'] as String?,
        hostAvatar: j['hostAvatar'] as String?,
        startTime: _parseDate(j['startTime']),
        liveStartedAt: _parseDate(j['liveStartedAt']),
        durationMinutes: _int(j['durationMinutes'], 60),
        status: _str(j['status'], 'waiting'),
        isLive: _bool(j['isLive']),
        isLocked: _bool(j['isLocked']),
        waitingRoomEnabled: _bool(j['waitingRoomEnabled']),
        watermarkEnabled: _bool(j['watermarkEnabled']),
        hasPassword: _bool(j['hasPassword']),
        recurrence: j['recurrence'] as String?,
        participantCount: _int(j['participantCount']),
        inviteLink: _str(j['inviteLink']),
      );

  bool get isOngoing => status == 'ongoing';
  bool get isEnded => status == 'ended';

  String get statusText {
    switch (status) {
      case 'ongoing':
        return '进行中';
      case 'ended':
        return '已结束';
      default:
        return '待开始';
    }
  }
}

/// REST /api/meetings/join 的返回
class JoinOutcome {
  /// joined / waiting / need_password
  final String joinStatus;
  final int meetingId;
  final String message;

  const JoinOutcome({required this.joinStatus, required this.meetingId, this.message = ''});

  factory JoinOutcome.fromJson(Map<String, dynamic> j) => JoinOutcome(
        joinStatus: _str(j['joinStatus'], 'joined'),
        meetingId: _int(j['meetingId']),
        message: _str(j['message']),
      );
}

// ==================== 参会人 / 会议内状态 ====================

class Participant {
  final int userId;
  final String nickname;
  final String? avatar;
  final String? department;

  /// host / cohost / participant / viewer
  final String role;
  final bool micOn;
  final bool cameraOn;
  final bool isSpeaking;
  final bool raisedHand;
  final bool isSharing;
  final bool hardMuted;
  final bool inWaitingRoom;
  final String? pmi;

  /// screen / camera；未共享为 null
  final String? shareType;

  const Participant({
    required this.userId,
    required this.nickname,
    this.avatar,
    this.department,
    this.role = 'participant',
    this.micOn = false,
    this.cameraOn = false,
    this.isSpeaking = false,
    this.raisedHand = false,
    this.isSharing = false,
    this.hardMuted = false,
    this.inWaitingRoom = false,
    this.pmi,
    this.shareType,
  });

  factory Participant.fromJson(Map<String, dynamic> j) => Participant(
        userId: _int(j['userId']),
        nickname: _str(j['nickname'], '参会人'),
        avatar: j['avatar'] as String?,
        department: j['department'] as String?,
        role: _str(j['role'], 'participant'),
        micOn: _bool(j['micOn']),
        cameraOn: _bool(j['cameraOn']),
        isSpeaking: _bool(j['isSpeaking']),
        raisedHand: _bool(j['raisedHand']),
        isSharing: _bool(j['isSharing']),
        hardMuted: _bool(j['hardMuted']),
        inWaitingRoom: _bool(j['inWaitingRoom']),
        pmi: j['pmi'] as String?,
        shareType: j['shareType'] as String?,
      );

  bool get isHost => role == 'host' || role == 'cohost';

  /// 是否在共享屏幕（排除"用摄像头视频冒充共享"的降级情况）
  bool get isScreenSharing => isSharing && (shareType == null || shareType == 'screen');

  Participant copyWith({
    String? nickname,
    String? avatar,
    String? department,
    String? role,
    bool? micOn,
    bool? cameraOn,
    bool? isSpeaking,
    bool? raisedHand,
    bool? isSharing,
    bool? hardMuted,
    bool? inWaitingRoom,
    String? shareType,
    bool clearShareType = false,
  }) =>
      Participant(
        userId: userId,
        nickname: nickname ?? this.nickname,
        avatar: avatar ?? this.avatar,
        department: department ?? this.department,
        role: role ?? this.role,
        micOn: micOn ?? this.micOn,
        cameraOn: cameraOn ?? this.cameraOn,
        isSpeaking: isSpeaking ?? this.isSpeaking,
        raisedHand: raisedHand ?? this.raisedHand,
        isSharing: isSharing ?? this.isSharing,
        hardMuted: hardMuted ?? this.hardMuted,
        inWaitingRoom: inWaitingRoom ?? this.inWaitingRoom,
        pmi: pmi,
        shareType: clearShareType ? null : (shareType ?? this.shareType),
      );
}

/// SignalR JoinResult 载荷
class JoinResultPayload {
  /// joined / waiting / error
  final String status;
  final String? message;
  final Meeting? meeting;
  final List<Participant> participants;
  final Participant? self;

  const JoinResultPayload({
    required this.status,
    this.message,
    this.meeting,
    this.participants = const [],
    this.self,
  });

  factory JoinResultPayload.fromJson(Map<String, dynamic> j) {
    final rawParts = (j['participants'] as List?) ?? const [];
    return JoinResultPayload(
      status: _str(j['status'], 'error'),
      message: j['message'] as String?,
      meeting: j['meeting'] == null
          ? null
          : Meeting.fromJson((j['meeting'] as Map).cast<String, dynamic>()),
      participants: rawParts
          .map((e) => Participant.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      self: j['self'] == null
          ? null
          : Participant.fromJson((j['self'] as Map).cast<String, dynamic>()),
    );
  }
}

/// 发送给后端的媒体状态（只提交发生变化的字段，null 表示不修改）
class MediaStatePayload {
  final bool? micOn;
  final bool? cameraOn;
  final bool? isSpeaking;
  final bool? isSharing;
  final String? shareType;

  const MediaStatePayload({
    this.micOn,
    this.cameraOn,
    this.isSpeaking,
    this.isSharing,
    this.shareType,
  });

  Map<String, dynamic> toJson() => {
        if (micOn != null) 'micOn': micOn,
        if (cameraOn != null) 'cameraOn': cameraOn,
        if (isSpeaking != null) 'isSpeaking': isSpeaking,
        if (isSharing != null) 'isSharing': isSharing,
        if (shareType != null) 'shareType': shareType,
      };
}

// ==================== 聊天 / 举手 / 投票 ====================

class ChatMessage {
  final int id;
  final int senderId;
  final String senderName;
  final String? senderAvatar;

  /// text / image / file
  final String type;
  final String content;
  final String? fileUrl;
  final int? toUserId;
  final DateTime? sentAt;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.senderAvatar,
    this.type = 'text',
    required this.content,
    this.fileUrl,
    this.toUserId,
    this.sentAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: _int(j['id']),
        senderId: _int(j['senderId']),
        senderName: _str(j['senderName'], '未知'),
        senderAvatar: j['senderAvatar'] as String?,
        type: _str(j['type'], 'text'),
        content: _str(j['content']),
        fileUrl: j['fileUrl'] as String?,
        toUserId: j['toUserId'] == null ? null : _int(j['toUserId']),
        sentAt: _parseDate(j['sentAt']),
      );
}

class Poll {
  final int id;
  final String title;
  final List<String> options;
  final Map<String, int> results;
  final bool isOpen;
  final int creatorId;
  final bool voted;

  const Poll({
    required this.id,
    required this.title,
    this.options = const [],
    this.results = const {},
    this.isOpen = true,
    this.creatorId = 0,
    this.voted = false,
  });

  factory Poll.fromJson(Map<String, dynamic> j) {
    final opts = (j['options'] as List?) ?? const [];
    final rawResults = (j['results'] as Map?) ?? const {};
    return Poll(
      id: _int(j['id']),
      title: _str(j['title']),
      options: opts.map((e) => e.toString()).toList(),
      results: rawResults.map((k, v) => MapEntry(k.toString(), _int(v))),
      isOpen: _bool(j['isOpen'], true),
      creatorId: _int(j['creatorId']),
      voted: _bool(j['voted']),
    );
  }

  int countFor(int index) => results[index.toString()] ?? 0;

  int get totalVotes => results.values.fold(0, (a, b) => a + b);
}

/// 主持人管控 / 系统通知
class HostNotice {
  /// muted / unmuted / mute_all / unmute_all / removed / lock / ended / role / admin_notice
  final String type;
  final String message;
  final int? targetUserId;

  const HostNotice({required this.type, required this.message, this.targetUserId});

  factory HostNotice.fromJson(Map<String, dynamic> j) => HostNotice(
        type: _str(j['type']),
        message: _str(j['message']),
        targetUserId: j['targetUserId'] == null ? null : _int(j['targetUserId']),
      );
}

/// 共享被停止（抢占 / 主持人强制停止）
class ShareStoppedInfo {
  /// 被停止共享的成员
  final int participantId;

  /// preempted / stopped_by_host
  final String reason;
  final String message;

  const ShareStoppedInfo({
    required this.participantId,
    this.reason = '',
    this.message = '',
  });

  factory ShareStoppedInfo.fromJson(Map<String, dynamic> j) => ShareStoppedInfo(
        participantId: _int(j['participantId']),
        reason: _str(j['reason']),
        message: _str(j['message']),
      );
}

/// 表情回应
class Reaction {
  final int userId;
  final String nickname;
  final String emoji;

  const Reaction({required this.userId, required this.nickname, required this.emoji});

  factory Reaction.fromJson(Map<String, dynamic> j) => Reaction(
        userId: _int(j['userId']),
        nickname: _str(j['nickname']),
        emoji: _str(j['emoji'], '👍'),
      );
}

/// 录制状态
class RecordingState {
  final int meetingId;
  final String mode;
  final bool started;

  const RecordingState({required this.meetingId, this.mode = '', this.started = false});

  factory RecordingState.fromJson(Map<String, dynamic> j) => RecordingState(
        meetingId: _int(j['meetingId']),
        mode: _str(j['mode']),
        started: _bool(j['started']),
      );
}

// ==================== 文件上传 ====================

class UploadedFile {
  final String url;
  final String name;
  final int size;

  const UploadedFile({required this.url, required this.name, this.size = 0});

  factory UploadedFile.fromJson(Map<String, dynamic> j) => UploadedFile(
        url: _str(j['url']),
        name: _str(j['name']),
        size: _int(j['size']),
      );

  String get readableSize {
    if (size <= 0) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

// ==================== TRTC 配置 ====================

class RtcConfig {
  final bool enabled;
  final int sdkAppId;
  final String? reason;

  const RtcConfig({required this.enabled, required this.sdkAppId, this.reason});

  factory RtcConfig.fromJson(Map<String, dynamic> j) => RtcConfig(
        enabled: _bool(j['enabled']),
        sdkAppId: _int(j['sdkAppId']),
        reason: j['reason'] as String?,
      );
}

class RtcUserSig {
  final String userId;
  final String userSig;
  final int expire;

  const RtcUserSig({required this.userId, required this.userSig, this.expire = 0});

  factory RtcUserSig.fromJson(Map<String, dynamic> j) => RtcUserSig(
        userId: _str(j['userId']),
        userSig: _str(j['userSig']),
        expire: _int(j['expire']),
      );
}

/// 便于把 payload 打印成日志
String prettyJson(Object? o) {
  try {
    return const JsonEncoder.withIndent('  ').convert(o);
  } catch (_) {
    return o.toString();
  }
}
