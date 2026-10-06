import 'dart:io';

import 'package:dio/dio.dart';

import 'app_config.dart';
import 'session.dart';

/// 统一的接口异常：把后端的 `{ message: "..." }`、网络错误、超时都归一成一句可展示的中文。
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final bool unauthorized;

  ApiException(this.message, {this.statusCode, this.unauthorized = false});

  @override
  String toString() => message;
}

/// REST 客户端。
///
/// 两个关键点：
///  1. baseUrl 每次都从 Session 现取 —— 用户可能在设置里改了服务器地址，不能缓存到构造时。
///  2. 401 统一抛出 unauthorized，由上层跳回登录页（token 有效期 7 天，过期属正常路径）。
class ApiClient {
  ApiClient(this._session) {
    _dio = Dio(BaseOptions(
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.receiveTimeout,
      // 由我们自己判断状态码，避免 Dio 在 4xx 时抛出信息量很低的异常
      validateStatus: (code) => code != null && code < 500,
      headers: {'Accept': 'application/json'},
    ));
  }

  final Session _session;
  late final Dio _dio;

  Dio get raw => _dio;

  Future<Response<T>> _send<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    bool auth = true,
  }) async {
    final url = '${_session.apiBase}$path';
    try {
      final res = await _dio.request<T>(
        url,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: auth && _session.token != null
              ? {'Authorization': 'Bearer ${_session.token}'}
              : null,
        ),
      );
      _throwIfError(res);
      return res;
    } on DioException catch (e) {
      throw ApiException(_friendlyNetworkError(e));
    }
  }

  void _throwIfError(Response res) {
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) return;
    if (code == 401) {
      throw ApiException(_messageOf(res.data) ?? '登录已过期，请重新登录',
          statusCode: code, unauthorized: true);
    }
    if (code == 403) {
      throw ApiException(_messageOf(res.data) ?? '没有权限执行该操作', statusCode: code);
    }
    throw ApiException(_messageOf(res.data) ?? '请求失败（HTTP $code）', statusCode: code);
  }

  String? _messageOf(dynamic data) {
    if (data is Map) {
      final m = data['message'] ?? data['title'] ?? data['error'];
      if (m != null && m.toString().trim().isNotEmpty) return m.toString();
    }
    if (data is String && data.trim().isNotEmpty && !data.trimLeft().startsWith('<')) {
      return data.trim();
    }
    // 后端 500 时可能返回 HTML 错误页，此时不展示原始 HTML
    return null;
  }

  String _friendlyNetworkError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查手机与服务器是否在同一网络';
      case DioExceptionType.connectionError:
        return '无法连接服务器（${_session.baseUrl}）。\n请确认：\n'
            '1) 后端已启动；\n'
            '2) 地址填的是电脑局域网 IP 而非 127.0.0.1；\n'
            '3) 手机与电脑在同一 WiFi，且防火墙放行端口。';
      case DioExceptionType.badCertificate:
        return 'HTTPS 证书校验失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return e.message ?? '网络异常';
    }
  }

  // ==================== 便捷方法 ====================

  Future<dynamic> get(String path, {Map<String, dynamic>? query, bool auth = true}) async {
    final res = await _send('GET', path, query: query, auth: auth);
    return res.data;
  }

  Future<dynamic> post(String path, {Object? data, bool auth = true}) async {
    final res = await _send('POST', path, data: data, auth: auth);
    return res.data;
  }

  Future<dynamic> put(String path, {Object? data, bool auth = true}) async {
    final res = await _send('PUT', path, data: data, auth: auth);
    return res.data;
  }

  Future<dynamic> delete(String path, {bool auth = true}) async {
    final res = await _send('DELETE', path, auth: auth);
    return res.data;
  }

  /// multipart 上传（头像、聊天文件）
  Future<dynamic> upload(String path, File file, {String field = 'file', bool auth = true}) async {
    final form = FormData.fromMap({
      field: await MultipartFile.fromFile(file.path, filename: file.uri.pathSegments.last),
    });
    try {
      final res = await _dio.post(
        '${_session.apiBase}$path',
        data: form,
        options: Options(
          headers: auth && _session.token != null
              ? {'Authorization': 'Bearer ${_session.token}'}
              : null,
        ),
      );
      _throwIfError(res);
      return res.data;
    } on DioException catch (e) {
      throw ApiException(_friendlyNetworkError(e));
    }
  }
}
