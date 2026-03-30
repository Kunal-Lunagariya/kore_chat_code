import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http_parser/http_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class ApiCall {
  static const String baseUrl = 'https://chatapi.koremobiles.in/api/';

  static const String appName = 'Kore Chat';

  static String? _authToken;
  static String? appVersion;
  static String? appDeviceId;
  static final Connectivity _connectivity = Connectivity();
  static String? buildNumber;

  // ── SSL-tolerant HTTP client ───────────────────────────────────
  // In debug mode (dev tunnel), skip certificate verification.
  // In release mode, normal verification applies.
  static http.Client _buildClient() {
    if (kDebugMode) {
      final ioClient = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      return IOClient(ioClient);
    }
    return http.Client();
  }

  static void setAuthToken(String? token) => _authToken = token;
  static String? getAuthToken() => _authToken;
  static void clearAuthToken() => _authToken = null;

  static Future<bool> isInternetAvailable() async {
    try {
      final result = await _connectivity.checkConnectivity();
      return result.contains(ConnectivityResult.wifi) ||
          result.contains(ConnectivityResult.mobile);
    } catch (_) {
      return true;
    }
  }

  static Stream<List<ConnectivityResult>> get connectivityStream =>
      _connectivity.onConnectivityChanged;

  static Map<String, String> _getCommonHeaders({
    Map<String, String>? additionalHeaders,
  }) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'appname': appName,
      'appversion': appVersion ?? '1.0.0',
      'deviceid': appDeviceId ?? '--',
      'platform': 'app',
      'X-Tunnel-Skip-Browser-Warning': 'true',
    };
    if (_authToken != null) headers['Authorization'] = 'Bearer $_authToken';
    if (additionalHeaders != null) headers.addAll(additionalHeaders);
    return headers;
  }

  static Future<void> _checkInternetConnection() async {
    if (!await isInternetAvailable()) {
      throw NoInternetException(
        'No internet connection available. Please check your connection and try again.',
      );
    }
  }

  // ── GET ────────────────────────────────────────────────────────
  static Future<dynamic> get(
    String endpoint, {
    Map<String, String>? headers,
    Map<String, dynamic>? queryParameters,
  }) async {
    await _checkInternetConnection();
    var url = Uri.parse('$baseUrl$endpoint');
    if (queryParameters != null && queryParameters.isNotEmpty) {
      url = url.replace(queryParameters: queryParameters);
    }
    final requestHeaders = _getCommonHeaders(additionalHeaders: headers);
    if (kDebugMode) {
      print('GET Request: $url');
      print('Headers: $requestHeaders');
    }
    final client = _buildClient();
    try {
      final response = await client
          .get(url, headers: requestHeaders)
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              throw Exception(
                'Request timeout. Please check your internet connection.',
              );
            },
          );
      return _handleResponse(response);
    } catch (e) {
      if (kDebugMode) print('GET Error: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  // ── POST ───────────────────────────────────────────────────────
  static Future<dynamic> post(
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
  }) async {
    await _checkInternetConnection();
    final url = Uri.parse('$baseUrl$endpoint');
    final requestHeaders = _getCommonHeaders(additionalHeaders: headers);
    if (kDebugMode) {
      print('POST Request: $url');
      print('Headers: $requestHeaders');
      print('Body: ${jsonEncode(data)}');
    }
    final client = _buildClient();
    try {
      final response = await client
          .post(
            url,
            headers: requestHeaders,
            body: data != null ? jsonEncode(data) : null,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              throw Exception(
                'Request timeout. Please check your internet connection.',
              );
            },
          );
      return _handleResponse(response);
    } catch (e) {
      if (kDebugMode) print('POST Error: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  // ── PUT ────────────────────────────────────────────────────────
  static Future<dynamic> put(
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
  }) async {
    await _checkInternetConnection();
    final url = Uri.parse('$baseUrl$endpoint');
    final requestHeaders = _getCommonHeaders(additionalHeaders: headers);
    final client = _buildClient();
    try {
      final response = await client
          .put(
            url,
            headers: requestHeaders,
            body: data != null ? jsonEncode(data) : null,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              throw Exception(
                'Request timeout. Please check your internet connection.',
              );
            },
          );
      return _handleResponse(response);
    } catch (e) {
      if (kDebugMode) print('PUT Error: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  // ── DELETE ─────────────────────────────────────────────────────
  static Future<dynamic> delete(
    String endpoint, {
    Map<String, String>? headers,
    dynamic data,
  }) async {
    await _checkInternetConnection();
    final url = Uri.parse('$baseUrl$endpoint');
    final requestHeaders = _getCommonHeaders(additionalHeaders: headers);
    final client = _buildClient();
    try {
      final response = await client
          .delete(
            url,
            headers: requestHeaders,
            body: data != null ? jsonEncode(data) : null,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              throw Exception(
                'Request timeout. Please check your internet connection.',
              );
            },
          );
      return _handleResponse(response);
    } catch (e) {
      if (kDebugMode) print('DELETE Error: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  // ── PATCH ──────────────────────────────────────────────────────
  static Future<dynamic> patch(
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
  }) async {
    await _checkInternetConnection();
    final url = Uri.parse('$baseUrl$endpoint');
    final requestHeaders = _getCommonHeaders(additionalHeaders: headers);
    final client = _buildClient();
    try {
      final response = await client
          .patch(
            url,
            headers: requestHeaders,
            body: data != null ? jsonEncode(data) : null,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              throw Exception(
                'Request timeout. Please check your internet connection.',
              );
            },
          );
      return _handleResponse(response);
    } catch (e) {
      if (kDebugMode) print('PATCH Error: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  // ── Upload file ────────────────────────────────────────────────
  static Future<dynamic> uploadFile(
    String endpoint, {
    required String filePath,
    required String fileFieldName,
    Map<String, String>? fields,
    Map<String, String>? headers,
  }) async {
    await _checkInternetConnection();
    final url = Uri.parse('$baseUrl$endpoint');

    // MultipartRequest needs the underlying HttpClient for SSL bypass
    late http.StreamedResponse streamedResponse;

    if (kDebugMode) {
      final ioClient = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      final client = IOClient(ioClient);
      var request = http.MultipartRequest('POST', url);
      if (_authToken != null)
        request.headers['Authorization'] = 'Bearer $_authToken';
      request.headers['appname'] = appName;
      request.headers['appversion'] = appVersion ?? '1.0.0';
      if (headers != null) {
        headers.remove('Content-Type');
        request.headers.addAll(headers);
      }
      final mimeType = _getMimeType(filePath);
      request.files.add(
        await http.MultipartFile.fromPath(
          fileFieldName,
          filePath,
          contentType: MediaType.parse(mimeType),
        ),
      );
      if (fields != null) request.fields.addAll(fields);
      streamedResponse = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      client.close();
    } else {
      var request = http.MultipartRequest('POST', url);
      if (_authToken != null)
        request.headers['Authorization'] = 'Bearer $_authToken';
      request.headers['appname'] = appName;
      request.headers['appversion'] = appVersion ?? '1.0.0';
      if (headers != null) {
        headers.remove('Content-Type');
        request.headers.addAll(headers);
      }
      final mimeType = _getMimeType(filePath);
      request.files.add(
        await http.MultipartFile.fromPath(
          fileFieldName,
          filePath,
          contentType: MediaType.parse(mimeType),
        ),
      );
      if (fields != null) request.fields.addAll(fields);
      streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
    }

    final response = await http.Response.fromStream(streamedResponse);
    if (kDebugMode) {
      print('Upload Response Status: ${response.statusCode}');
      print('Upload Response Body: ${response.body}');
    }
    return _handleResponse(response);
  }

  // ── Response handler ───────────────────────────────────────────
  static dynamic _handleResponse(http.Response response) {
    if (kDebugMode) {
      print('Response Status Code: ${response.statusCode}');
      log('Response Body: ${response.body}');
    }

    final statusCode = response.statusCode;
    final body = response.body;

    // Safe JSON parse — if it's HTML or plain text, keep it as a String
    dynamic responseData;
    try {
      final decoded = body.isNotEmpty ? jsonDecode(body) : null;
      // Only treat as structured data if it's actually a Map or List
      if (decoded is Map || decoded is List) {
        responseData = decoded;
      } else {
        responseData = null; // was a JSON string/number — treat as no data
      }
    } catch (_) {
      responseData = null; // HTML or malformed JSON
    }

    // Helper to extract message from structured response or fall back to default
    String errorMsg(String fallback) {
      if (responseData is Map) {
        return (responseData)['message']?.toString() ??
            (responseData)['error']?.toString() ??
            fallback;
      }
      return fallback;
    }

    switch (statusCode) {
      case 200:
      case 201:
      case 202:
        return responseData;
      case 204:
        return null;
      case 400:
        throw Exception(errorMsg('Bad request'));
      case 401:
        clearAuthToken();
        throw Exception(errorMsg('Unauthorized. Please login again.'));
      case 403:
        throw Exception(
          errorMsg('Access forbidden. Please check your connection.'),
        );
      case 404:
        throw Exception(errorMsg('Resource not found'));
      case 422:
        throw Exception(errorMsg('Validation error'));
      case 500:
      case 502:
      case 503:
        throw Exception(errorMsg('Server error. Please try again later.'));
      default:
        throw Exception(errorMsg('Something went wrong. Status: $statusCode'));
    }
  }

  static String _getMimeType(String filePath) {
    switch (filePath.split('.').last.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      default:
        return 'application/octet-stream';
    }
  }
}

class NoInternetException implements Exception {
  final String message;
  NoInternetException(this.message);
  @override
  String toString() => message;
}
