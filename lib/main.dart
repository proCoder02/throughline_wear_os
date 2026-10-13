import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

const _mint = Color(0xFF80F0C0);
const _ink = Color(0xFF080B10);
const _surface = Color(0xFF171C25);

void main() {
  runApp(const ThroughlineWearApp());
}

class ThroughlineWearApp extends StatelessWidget {
  const ThroughlineWearApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Throughline',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _ink,
      colorScheme: const ColorScheme.dark(
        primary: _mint,
        onPrimary: _ink,
        surface: _surface,
        onSurface: Color(0xFFF3F5F8),
      ),
      useMaterial3: true,
    ),
    home: const WatchHomeScreen(),
  );
}

class ThroughlineApi {
  ThroughlineApi({Dio? dio, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: const String.fromEnvironment(
                'API_BASE_URL',
                defaultValue: 'https://129-213-21-239.sslip.io',
              ),
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 120),
              headers: {'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _storage.read(key: 'token');
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401) {
            await _storage.delete(key: 'token');
            onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );
  }

  final Dio _dio;
  final FlutterSecureStorage _storage;
  VoidCallback? onUnauthorized;

  Future<bool> hasToken() async =>
      (await _storage.read(key: 'token'))?.isNotEmpty ?? false;

  Future<void> login(String username, String password) async {
    final response = await _dio.post(
      '/login',
      data: {'username': username, 'password': password},
    );
    final token = response.data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const FormatException('The server did not return an access token.');
    }
    await _storage.write(key: 'token', value: token);
  }

  Future<void> logout() => _storage.delete(key: 'token');

  Future<List<BackendTask>> listTasks() async {
    final response = await _dio.get(
      '/tasks',
      queryParameters: {'status': 'open'},
    );
    if (response.data is! List) {
      throw const FormatException('The server returned an invalid task list.');
    }
    return (response.data as List)
        .map((json) => BackendTask.fromJson(json as Map<String, dynamic>))
        .toList()
      ..sort((a, b) {
        final aDate = a.reminderAt ?? DateTime(9999);
        final bDate = b.reminderAt ?? DateTime(9999);
        return aDate.compareTo(bDate);
      });
  }

  Future<void> completeTask(int id) => _dio.post('/tasks/$id/complete');

  Future<List<GlobalChatMessage>> loadGlobalChat() async {
    final response = await _dio.get('/chat/global');
    if (response.data is! List) {
      throw const FormatException(
        'The server returned an invalid chat history.',
      );
    }
    return (response.data as List).map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException(
          'The server returned an invalid chat message.',
        );
      }
      return GlobalChatMessage.fromJson(item);
    }).toList();
  }

  Future<String> sendGlobalChat(String prompt) async {
    final response = await _dio.post('/chat/global', data: {'prompt': prompt});
    final reply = response.data['reply'];
    if (reply is! String || reply.trim().isEmpty) {
      throw const FormatException('The server returned an empty chat reply.');
    }
    return reply;
  }

  Future<void> syncHeartRateSession(Map<String, Object?> session) =>
      _dio.post('/health/heart-rate', data: session);

  Future<String> transcribe(File audioFile) async {
    final form = FormData.fromMap({
      'audio': await MultipartFile.fromFile(
        audioFile.path,
        filename: 'watch-note.m4a',
      ),
    });
    final response = await _dio.post('/transcribe', data: form);
    final transcript = response.data['transcript'] as String?;
    if (transcript == null || transcript.trim().isEmpty) {
      throw const FormatException('No speech was recognized. Try again.');
    }
    return transcript;
  }

  Future<AnalysisResult> analyze(String transcript) async {
    final response = await _dio.post(
      '/analyze',
      data: {'transcript': transcript},
    );
    final data = response.data as Map<String, dynamic>;
    final tasks = data['tasks'];
    return AnalysisResult(
      conversationId: data['conversation_id'] as int,
      extractedTaskCount: tasks is List ? tasks.length : 0,
    );
  }
}

class HeartRateCaptureClient {
  static const _methodChannel = MethodChannel('throughline/health');
  static const _eventChannel = EventChannel('throughline/heart-rate');

  Future<bool> isSupported() async =>
      await _methodChannel.invokeMethod<bool>('isHeartRateSupported') ?? false;

  Future<bool> hasPermission() async =>
      await _methodChannel.invokeMethod<bool>('hasHeartRatePermission') ??
      false;

  Future<bool> requestPermission() async =>
      await _methodChannel.invokeMethod<bool>('requestHeartRatePermission') ??
      false;

  Future<void> start() => _methodChannel.invokeMethod<void>('startHeartRate');

  Future<void> stop() => _methodChannel.invokeMethod<void>('stopHeartRate');

  /// Fallback sync path -- used only when the direct API sync fails (e.g.
  /// the watch has no network of its own). Puts the session on the Wear OS
  /// Data Layer; the platform delivers it to the paired phone over
  /// Bluetooth, where HeartRateRelayListenerService forwards it to the
  /// backend using its own cached auth -- works even if neither app is in
  /// the foreground.
  Future<void> relayViaBluetooth(String sessionId, String sessionJson) =>
      _methodChannel.invokeMethod<void>('relayHeartRateViaBluetooth', {
        'sessionId': sessionId,
        'sessionJson': sessionJson,
      });

  Stream<Map<String, dynamic>> get events => _eventChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));
}

class HeartRateSample {
  const HeartRateSample({
    required this.bpm,
    required this.measuredAt,
    required this.source,
    this.accuracy,
  });

  final double bpm;
  final DateTime measuredAt;
  final String source;
  final String? accuracy;

  factory HeartRateSample.fromEvent(Map<String, dynamic> event) {
    final bpm = event['bpm'];
    final measuredAt = event['measuredAt'];
    final source = event['source'];
    if (event['type'] != 'sample' ||
        bpm is! num ||
        measuredAt is! String ||
        source is! String) {
      throw const FormatException(
        'The watch returned an invalid heart-rate sample.',
      );
    }
    final timestamp = DateTime.tryParse(measuredAt);
    if (timestamp == null || !bpm.isFinite || bpm <= 0) {
      throw const FormatException(
        'The watch returned an invalid heart-rate sample.',
      );
    }
    return HeartRateSample(
      bpm: bpm.toDouble(),
      measuredAt: timestamp.toUtc(),
      source: source,
      accuracy: event['accuracy'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'bpm': bpm,
    'measured_at': measuredAt.toIso8601String(),
    'source': source,
    if (accuracy != null) 'accuracy': accuracy,
  };
}

class BackendTask {
  const BackendTask({
    required this.id,
    required this.description,
    required this.status,
    this.owner,
    this.dueDate,
    this.reminderAt,
  });

  final int id;
  final String description;
  final String status;
  final String? owner;
  final String? dueDate;
  final DateTime? reminderAt;

  factory BackendTask.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final description = json['description'];
    final status = json['status'];
    if (id is! int || description is! String || status is! String) {
      throw const FormatException('The server returned an invalid task.');
    }
    final rawReminder = json['reminder_at'];
    return BackendTask(
      id: id,
      description: description,
      status: status,
      owner: json['owner'] as String?,
      dueDate: json['due_date'] as String?,
      reminderAt: rawReminder is String
          ? DateTime.tryParse(rawReminder)?.toLocal()
          : null,
    );
  }

  String get dueLabel {
    if (reminderAt != null) {
      final now = DateTime.now();
      final isToday =
          reminderAt!.year == now.year &&
          reminderAt!.month == now.month &&
          reminderAt!.day == now.day;
      final time =
          '${reminderAt!.hour.toString().padLeft(2, '0')}:${reminderAt!.minute.toString().padLeft(2, '0')}';
      return isToday ? 'Today · $time' : '${_shortDate(reminderAt!)} · $time';
    }
    return dueDate?.trim().isNotEmpty == true ? dueDate!.trim() : 'No date';
  }
}

class AnalysisResult {
  const AnalysisResult({
    required this.conversationId,
    required this.extractedTaskCount,
  });

  final int conversationId;
  final int extractedTaskCount;
}

class GlobalChatMessage {
  const GlobalChatMessage({
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String role;
  final String content;
  final DateTime createdAt;

  factory GlobalChatMessage.fromJson(Map<String, dynamic> json) {
    final role = json['role'];
    final content = json['content'];
    final createdAt = json['created_at'];
    if ((role != 'user' && role != 'assistant') ||
        content is! String ||
        createdAt is! String) {
      throw const FormatException(
        'The server returned an invalid chat message.',
      );
    }
    final timestamp = DateTime.tryParse(createdAt);
    if (timestamp == null) {
      throw const FormatException(
        'The server returned an invalid chat timestamp.',
      );
    }
    return GlobalChatMessage(
      role: role as String,
      content: content,
      createdAt: timestamp.toLocal(),
    );
  }
}

enum _WatchDestination { home, followUps, heartRate, globalChat }

class WatchHomeScreen extends StatefulWidget {
  const WatchHomeScreen({super.key});

  @override
  State<WatchHomeScreen> createState() => _WatchHomeScreenState();
}

class _WatchHomeScreenState extends State<WatchHomeScreen> {
  final _api = ThroughlineApi();
  final _heartRateClient = HeartRateCaptureClient();
  final _healthStorage = const FlutterSecureStorage();
  StreamSubscription<Map<String, dynamic>>? _heartRateSubscription;
  List<BackendTask> _tasks = [];
  List<HeartRateSample> _activeHeartRateSamples = [];
  HeartRateSample? _latestHeartRate;
  DateTime? _heartRateSessionStartedAt;
  String? _heartRateSessionId;
  String? _heartRateError;
  String? _heartRateAvailability;
  bool? _heartRateSupported;
  bool _isCheckingHeartRate = false;
  bool _isStartingHeartRate = false;
  bool _isMeasuringHeartRate = false;
  int _savedHeartRateSessionCount = 0;
  bool _isCheckingSession = true;
  bool _isAuthenticated = false;
  bool _isLoadingTasks = false;
  String? _error;
  _WatchDestination _destination = _WatchDestination.home;

  static const _heartRateSessionsKey = 'health.heart_rate.sessions.v1';

  @override
  void initState() {
    super.initState();
    _api.onUnauthorized = () {
      if (!mounted) return;
      setState(() {
        _isAuthenticated = false;
        _destination = _WatchDestination.home;
        _error = 'Your session expired. Sign in again.';
      });
    };
    _checkSession();
  }

  Future<void> _checkSession() async {
    try {
      final hasToken = await _api.hasToken();
      if (!mounted) return;
      setState(() {
        _isAuthenticated = hasToken;
        _isCheckingSession = false;
      });
      if (hasToken) {
        unawaited(_checkHeartRateSupport());
        unawaited(_loadSavedHeartRateSessionCount());
        await _loadTasks();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isCheckingSession = false;
        _error = 'Could not read saved sign-in: $error';
      });
    }
  }

  Future<void> _login(String username, String password) async {
    try {
      await _api.login(username, password);
      if (!mounted) return;
      setState(() {
        _isAuthenticated = true;
        _destination = _WatchDestination.home;
        _error = null;
      });
      await _loadTasks();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _apiError(error));
    }
  }

  Future<void> _loadTasks() async {
    setState(() {
      _isLoadingTasks = true;
      _error = null;
    });
    try {
      final tasks = await _api.listTasks();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _isLoadingTasks = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingTasks = false;
        _error = _apiError(error);
      });
    }
  }

  Future<void> _complete(BackendTask task) async {
    try {
      await _api.completeTask(task.id);
      if (!mounted) return;
      setState(() => _tasks.removeWhere((saved) => saved.id == task.id));
      _showMessage('Marked done');
    } catch (error) {
      _showMessage('Could not mark done: ${_apiError(error)}');
    }
  }

  Future<void> _capture() async {
    final result = await Navigator.of(context).push<AnalysisResult>(
      MaterialPageRoute(builder: (_) => CaptureScreen(api: _api)),
    );
    if (result == null || !mounted) return;
    await _loadTasks();
    if (!mounted) return;
    _showMessage(
      result.extractedTaskCount == 1
          ? 'Saved · 1 follow-up found'
          : 'Saved · ${result.extractedTaskCount} follow-ups found',
    );
  }

  Future<void> _logout() async {
    try {
      await _api.logout();
      if (!mounted) return;
      setState(() {
        _isAuthenticated = false;
        _destination = _WatchDestination.home;
        _tasks = [];
        _error = null;
      });
    } catch (error) {
      _showMessage('Could not sign out: ${_apiError(error)}');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkHeartRateSupport() async {
    if (_isCheckingHeartRate) return;
    setState(() => _isCheckingHeartRate = true);
    try {
      final supported = await _heartRateClient.isSupported();
      if (!mounted) return;
      setState(() {
        _heartRateSupported = supported;
        _isCheckingHeartRate = false;
        _heartRateError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _heartRateSupported = false;
        _isCheckingHeartRate = false;
        _heartRateError = _heartRateErrorMessage(error);
      });
    }
  }

  Future<void> _loadSavedHeartRateSessionCount() async {
    try {
      final stored = await _healthStorage.read(key: _heartRateSessionsKey);
      if (stored == null || !mounted) return;
      final sessions = jsonDecode(stored);
      if (sessions is List && mounted) {
        setState(() => _savedHeartRateSessionCount = sessions.length);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _heartRateError = 'Could not read saved health data.');
      }
    }
  }

  Future<void> _startHeartRateMeasurement() async {
    if (_isStartingHeartRate || _isMeasuringHeartRate) return;
    setState(() {
      _isStartingHeartRate = true;
      _heartRateError = null;
      _heartRateAvailability = null;
      _activeHeartRateSamples = [];
      _latestHeartRate = null;
    });

    try {
      final isSupported = await _heartRateClient.isSupported();
      if (!isSupported) {
        throw StateError(
          'This watch does not support live heart-rate measurement.',
        );
      }

      var hasPermission = await _heartRateClient.hasPermission();
      if (!hasPermission) {
        hasPermission = await _heartRateClient.requestPermission();
      }
      if (!hasPermission) {
        throw StateError('Heart-rate permission was not granted.');
      }

      _heartRateSessionStartedAt = DateTime.now().toUtc();
      _heartRateSessionId = _heartRateSessionStartedAt!.microsecondsSinceEpoch
          .toString();
      _heartRateSubscription = _heartRateClient.events.listen(
        _handleHeartRateEvent,
        onError: (Object error) {
          if (!mounted) return;
          setState(() => _heartRateError = _heartRateErrorMessage(error));
          unawaited(_stopHeartRateMeasurement(saveSession: false));
        },
      );
      await _heartRateClient.start();
      if (!mounted) return;
      setState(() {
        _heartRateSupported = true;
        _isStartingHeartRate = false;
        _isMeasuringHeartRate = true;
      });
    } catch (error) {
      await _heartRateSubscription?.cancel();
      _heartRateSubscription = null;
      if (!mounted) return;
      setState(() {
        _isStartingHeartRate = false;
        _isMeasuringHeartRate = false;
        _heartRateError = _heartRateErrorMessage(error);
      });
    }
  }

  void _handleHeartRateEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    if (event['type'] == 'availability') {
      setState(() => _heartRateAvailability = event['state'] as String?);
      return;
    }

    try {
      final sample = HeartRateSample.fromEvent(event);
      setState(() {
        _latestHeartRate = sample;
        _activeHeartRateSamples.add(sample);
      });
    } catch (error) {
      setState(() => _heartRateError = _heartRateErrorMessage(error));
    }
  }

  Future<void> _stopHeartRateMeasurement({bool saveSession = true}) async {
    final subscription = _heartRateSubscription;
    _heartRateSubscription = null;
    if (mounted) setState(() => _isMeasuringHeartRate = false);

    try {
      await _heartRateClient.stop();
    } catch (error) {
      if (mounted) {
        setState(() => _heartRateError = _heartRateErrorMessage(error));
      }
    }
    await subscription?.cancel();

    if (saveSession && _activeHeartRateSamples.isNotEmpty) {
      final sessionJson = {
        'session_id': _heartRateSessionId,
        'started_at': _heartRateSessionStartedAt?.toIso8601String(),
        'ended_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'wear_health_services',
        'samples': _activeHeartRateSamples
            .map((sample) => sample.toJson())
            .toList(),
      };
      try {
        final stored = await _healthStorage.read(key: _heartRateSessionsKey);
        final decoded = stored == null ? <dynamic>[] : jsonDecode(stored);
        final sessions = decoded is List ? decoded : <dynamic>[];
        sessions.add(sessionJson);
        final retainedSessions = sessions.length > 30
            ? sessions.sublist(sessions.length - 30)
            : sessions;
        await _healthStorage.write(
          key: _heartRateSessionsKey,
          value: jsonEncode(retainedSessions),
        );
        if (mounted) {
          setState(() {
            _savedHeartRateSessionCount = retainedSessions.length;
            _heartRateAvailability = 'Saved securely on this watch';
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() => _heartRateError = _heartRateErrorMessage(error));
        }
      }
      // Best-effort background sync -- never blocks or surfaces an error
      // into the UI the local save above already confirmed. Direct API
      // sync first (works whenever the watch has its own network); on
      // failure, fall back to the Bluetooth Data Layer relay through the
      // paired phone (see HeartRateCaptureClient.relayViaBluetooth) rather
      // than giving up immediately -- that fallback itself is best-effort
      // too, so a session only ever stays local-only if BOTH paths fail
      // (e.g. no network AND no paired phone in range).
      unawaited(
        _api.syncHeartRateSession(sessionJson).catchError((_) {
          return _heartRateClient
              .relayViaBluetooth(
                _heartRateSessionId ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                jsonEncode(sessionJson),
              )
              .catchError((_) {});
        }),
      );
    }
  }

  @override
  void dispose() {
    final subscription = _heartRateSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    if (_isMeasuringHeartRate) unawaited(_heartRateClient.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final contentWidth = (width - 32).clamp(0.0, 320.0).toDouble();
    return PopScope<Object?>(
      canPop: !_isAuthenticated || _destination == _WatchDestination.home,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop ||
            !_isAuthenticated ||
            _destination == _WatchDestination.home) {
          return;
        }
        setState(() => _destination = _WatchDestination.home);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Center(
            child: SizedBox(
              width: contentWidth,
              child: _isCheckingSession
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _mint,
                        ),
                      ),
                    )
                  : _isAuthenticated
                  ? switch (_destination) {
                      _WatchDestination.home => _buildHome(contentWidth),
                      _WatchDestination.followUps => _buildFollowUps(
                        contentWidth,
                      ),
                      _WatchDestination.heartRate => _buildHeartRate(
                        contentWidth,
                      ),
                      _WatchDestination.globalChat => GlobalChatScreen(
                        api: _api,
                        onBack: () => setState(
                          () => _destination = _WatchDestination.home,
                        ),
                      ),
                    }
                  : LoginScreen(error: _error, onLogin: _login),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHome(double width) {
    final now = DateTime.now();
    final horizontalPadding = (width / 2).clamp(0.0, 12.0).toDouble();
    return RefreshIndicator(
      onRefresh: () async => _loadTasks(),
      color: _mint,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              12,
              horizontalPadding,
              24,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _WatchPageHeader(
                  title: 'Throughline',
                  leading: const Icon(Icons.all_inclusive, color: _mint),
                  trailing: IconButton(
                    tooltip: 'Sign out',
                    onPressed: _logout,
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _shortDate(now).toUpperCase(),
                  style: const TextStyle(
                    color: _mint,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _tasks.isEmpty ? 'Clear your mind.' : 'One thing at a time.',
                  style: const TextStyle(
                    fontSize: 23,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _tasks.isEmpty
                      ? 'Capture a thought or check in.'
                      : '${_tasks.length} follow-up${_tasks.length == 1 ? '' : 's'} waiting.',
                  style: const TextStyle(
                    color: Color(0xFF929BA9),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _capture,
                    icon: const Icon(Icons.mic_none_rounded),
                    label: const Text('Capture a thought'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: _mint,
                      foregroundColor: _ink,
                      textStyle: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _WatchDestinationCard(
                  icon: Icons.check_circle_outline_rounded,
                  title: 'Follow-ups',
                  subtitle: _isLoadingTasks && _tasks.isEmpty
                      ? 'Syncing your list'
                      : _tasks.isEmpty
                      ? 'You’re all caught up'
                      : '${_tasks.length} to take care of',
                  onTap: () => setState(
                    () => _destination = _WatchDestination.followUps,
                  ),
                ),
                const SizedBox(height: 8),
                _WatchDestinationCard(
                  icon: Icons.favorite_outline_rounded,
                  title: 'Heart rate',
                  subtitle: _latestHeartRate == null
                      ? 'Take a spot check'
                      : '${_latestHeartRate!.bpm.round()} BPM · ${_shortTime(_latestHeartRate!.measuredAt.toLocal())}',
                  iconColor: const Color(0xFFFF8F82),
                  onTap: () => setState(
                    () => _destination = _WatchDestination.heartRate,
                  ),
                ),
                const SizedBox(height: 8),
                _WatchDestinationCard(
                  icon: Icons.forum_outlined,
                  title: 'Global Chat',
                  subtitle: 'Ask across your conversations',
                  onTap: () => setState(
                    () => _destination = _WatchDestination.globalChat,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ErrorCard(message: _error!, onRetry: _loadTasks),
                  ),
                const Center(
                  child: Text(
                    'Swipe to scroll · Pull down to sync',
                    style: TextStyle(fontSize: 10, color: Color(0xFF747E8D)),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowUps(double width) {
    final horizontalPadding = (width / 2).clamp(0.0, 12.0).toDouble();
    return RefreshIndicator(
      onRefresh: () async => _loadTasks(),
      color: _mint,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              8,
              horizontalPadding,
              24,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _WatchPageHeader(
                  title: 'Follow-ups',
                  onBack: () =>
                      setState(() => _destination = _WatchDestination.home),
                  trailing: IconButton(
                    tooltip: 'Refresh follow-ups',
                    onPressed: _isLoadingTasks ? null : _loadTasks,
                    icon: _isLoadingTasks
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _mint,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _tasks.isEmpty ? 'All caught up.' : '${_tasks.length} to do.',
                  style: const TextStyle(
                    fontSize: 23,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Tap Done when it’s taken care of.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF929BA9)),
                ),
                const SizedBox(height: 14),
                if (_error != null)
                  _ErrorCard(message: _error!, onRetry: _loadTasks),
                if (_isLoadingTasks && _tasks.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _mint,
                      ),
                    ),
                  )
                else if (_tasks.isEmpty && _error == null)
                  const _EmptyHint(
                    icon: Icons.check_circle_outline_rounded,
                    text: 'Nothing pending.\nCapture a thought to add one.',
                  )
                else
                  ..._tasks.map(
                    (task) => _ReminderCard(
                      task: task,
                      onDone: () => _complete(task),
                    ),
                  ),
                const SizedBox(height: 8),
                const Center(
                  child: Text(
                    'Synced with Throughline',
                    style: TextStyle(fontSize: 10, color: Color(0xFF747E8D)),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeartRate(double width) {
    final horizontalPadding = (width / 2).clamp(0.0, 12.0).toDouble();
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WatchPageHeader(
            title: 'Heart rate',
            onBack: () => setState(() => _destination = _WatchDestination.home),
          ),
          const SizedBox(height: 8),
          const Text(
            'Check in with your body.',
            style: TextStyle(
              fontSize: 22,
              height: 1.05,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Keep the watch snug on your wrist.',
            style: TextStyle(fontSize: 11, color: Color(0xFF929BA9)),
          ),
          const SizedBox(height: 14),
          _HeartRateCard(
            isSupported: _heartRateSupported,
            isChecking: _isCheckingHeartRate,
            isStarting: _isStartingHeartRate,
            isMeasuring: _isMeasuringHeartRate,
            latestSample: _latestHeartRate,
            sampleCount: _activeHeartRateSamples.length,
            savedSessionCount: _savedHeartRateSessionCount,
            availability: _heartRateAvailability,
            error: _heartRateError,
            onStart: _startHeartRateMeasurement,
            onStop: _stopHeartRateMeasurement,
          ),
        ],
      ),
    );
  }
}

class _WatchPageHeader extends StatelessWidget {
  const _WatchPageHeader({
    required this.title,
    this.leading,
    this.onBack,
    this.trailing,
  });

  final String title;
  final Widget? leading;
  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (onBack != null)
        IconButton(
          tooltip: 'Back',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        )
      else if (leading != null) ...[
        leading!,
        const SizedBox(width: 8),
      ],
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      if (trailing != null) trailing!,
    ],
  );
}

class _WatchDestinationCard extends StatelessWidget {
  const _WatchDestinationCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor = _mint,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) => Material(
    color: _surface,
    borderRadius: BorderRadius.circular(24),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF929BA9),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF929BA9)),
            ],
          ),
        ),
      ),
    ),
  );
}

class GlobalChatScreen extends StatefulWidget {
  const GlobalChatScreen({required this.api, required this.onBack, super.key});

  final ThroughlineApi api;
  final VoidCallback onBack;

  @override
  State<GlobalChatScreen> createState() => _GlobalChatScreenState();
}

class _GlobalChatScreenState extends State<GlobalChatScreen> {
  final _promptController = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <GlobalChatMessage>[];
  bool _isLoading = true;
  bool _isSending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final messages = await widget.api.loadGlobalChat();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(messages);
        _isLoading = false;
      });
      _scrollToEnd(animate: false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _apiError(error);
      });
    }
  }

  Future<void> _send() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty || _isSending) return;
    setState(() {
      _isSending = true;
      _error = null;
      _promptController.clear();
      _messages.add(
        GlobalChatMessage(
          role: 'user',
          content: prompt,
          createdAt: DateTime.now(),
        ),
      );
    });
    _scrollToEnd();

    try {
      final reply = await widget.api.sendGlobalChat(prompt);
      if (!mounted) return;
      setState(() {
        _messages.add(
          GlobalChatMessage(
            role: 'assistant',
            content: reply,
            createdAt: DateTime.now(),
          ),
        );
        _isSending = false;
      });
      _scrollToEnd();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _error = _apiError(error);
      });
    }
  }

  void _scrollToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final end = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          end,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(end);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: _WatchPageHeader(
          title: 'Global Chat',
          onBack: widget.onBack,
          trailing: IconButton(
            tooltip: 'Refresh chat',
            onPressed: _isLoading || _isSending ? null : _loadMessages,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Ask across your conversations',
            style: TextStyle(fontSize: 11, color: Color(0xFF929BA9)),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: _isLoading && _messages.isEmpty
            ? const Center(
                child: CircularProgressIndicator(strokeWidth: 2, color: _mint),
              )
            : _messages.isEmpty && _error == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 28, color: _mint),
                      SizedBox(height: 10),
                      Text(
                        'Ask about a person, a plan, or something you recorded.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFBBC2CC),
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                key: const Key('global-chat-messages'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                itemCount: _messages.length + (_isSending ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _messages.length) {
                    return const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _mint,
                          ),
                        ),
                      ),
                    );
                  }
                  return _GlobalChatBubble(message: _messages[index]);
                },
              ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFFFB4A8),
                  ),
                ),
              ),
              if (_messages.isEmpty)
                TextButton(
                  onPressed: _isLoading ? null : _loadMessages,
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFF303846)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('global-chat-prompt'),
                    controller: _promptController,
                    minLines: 1,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Ask anything…',
                      hintStyle: TextStyle(
                        color: Color(0xFF929BA9),
                        fontSize: 13,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Material(
                  color: _mint,
                  shape: const CircleBorder(),
                  child: InkWell(
                    key: const Key('global-chat-send'),
                    customBorder: const CircleBorder(),
                    onTap: _isSending || _promptController.text.trim().isEmpty
                        ? null
                        : _send,
                    child: Padding(
                      padding: const EdgeInsets.all(9),
                      child: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _ink,
                              ),
                            )
                          : const Icon(
                              Icons.arrow_upward_rounded,
                              color: _ink,
                              size: 18,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class _GlobalChatBubble extends StatelessWidget {
  const _GlobalChatBubble({required this.message});

  final GlobalChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.76,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF244C3D) : _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF303846)),
        ),
        child: Text(
          message.content,
          style: const TextStyle(fontSize: 12, height: 1.3),
        ),
      ),
    );
  }
}

class _HeartRateCard extends StatelessWidget {
  const _HeartRateCard({
    required this.isSupported,
    required this.isChecking,
    required this.isStarting,
    required this.isMeasuring,
    required this.latestSample,
    required this.sampleCount,
    required this.savedSessionCount,
    required this.availability,
    required this.error,
    required this.onStart,
    required this.onStop,
  });

  final bool? isSupported;
  final bool isChecking;
  final bool isStarting;
  final bool isMeasuring;
  final HeartRateSample? latestSample;
  final int sampleCount;
  final int savedSessionCount;
  final String? availability;
  final String? error;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final canMeasure = isSupported != false && !isChecking;
    final buttonLabel = isChecking
        ? 'Checking watch'
        : isStarting
        ? 'Starting'
        : isMeasuring
        ? 'Stop measurement'
        : isSupported == false
        ? 'Sensor unavailable'
        : 'Measure heart rate';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF252D39)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.favorite_rounded,
                color: Color(0xFFFF8F82),
                size: 17,
              ),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'HEART RATE',
                  style: TextStyle(
                    fontSize: 10,
                    color: Color(0xFF929BA9),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isMeasuring)
                const SizedBox(
                  width: 7,
                  height: 7,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _mint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (latestSample != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  latestSample!.bpm.round().toString(),
                  style: const TextStyle(
                    fontSize: 34,
                    height: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 5, bottom: 3),
                  child: Text(
                    'BPM',
                    style: TextStyle(fontSize: 10, color: Color(0xFF929BA9)),
                  ),
                ),
              ],
            )
          else
            Text(
              isMeasuring ? 'Waiting for reading' : 'Ready for a spot check',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          if (latestSample != null)
            Text(
              '${_shortTime(latestSample!.measuredAt.toLocal())} · $sampleCount sample${sampleCount == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF929BA9)),
            )
          else
            Text(
              isMeasuring
                  ? (availability ?? 'Keep the watch snug on your wrist.')
                  : '$savedSessionCount saved session${savedSessionCount == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF929BA9)),
            ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              error!,
              style: const TextStyle(fontSize: 10, color: Color(0xFFFFB4A8)),
            ),
          ],
          const SizedBox(height: 9),
          OutlinedButton.icon(
            onPressed: isMeasuring
                ? onStop
                : canMeasure && !isStarting
                ? onStart
                : null,
            icon: isStarting || isChecking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    isMeasuring
                        ? Icons.stop_rounded
                        : Icons.favorite_outline_rounded,
                    size: 17,
                  ),
            label: Text(buttonLabel),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: isMeasuring ? const Color(0xFFFF8F82) : _mint,
              side: BorderSide(
                color: isMeasuring
                    ? const Color(0xFF68413F)
                    : const Color(0xFF385849),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.error, required this.onLogin});

  final String? error;
  final Future<void> Function(String username, String password) onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  bool _isSigningIn = false;
  bool _showPassword = false;
  bool _passwordStep = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSigningIn) return;
    if (_username.text.trim().isEmpty) {
      _usernameFocusNode.requestFocus();
      return;
    }
    if (_password.text.isEmpty) {
      _passwordFocusNode.requestFocus();
      return;
    }
    setState(() => _isSigningIn = true);
    await widget.onLogin(_username.text.trim(), _password.text);
    if (mounted) setState(() => _isSigningIn = false);
  }

  void _advanceToPassword() {
    if (_username.text.trim().isEmpty) {
      _usernameFocusNode.requestFocus();
      return;
    }
    setState(() => _passwordStep = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _passwordFocusNode.requestFocus();
    });
  }

  void _editUsername() {
    setState(() => _passwordStep = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _usernameFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final formWidth = (width - 36).clamp(0.0, 304.0).toDouble();
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 32).clamp(0.0, double.infinity),
          ),
          child: Center(
            child: SizedBox(
              width: formWidth,
              child: AutofillGroup(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_passwordStep)
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Change username',
                            onPressed: _isSigningIn ? null : _editUsername,
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Password',
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _username.text.trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF929BA9),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    else ...[
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.all_inclusive, color: _mint, size: 21),
                          SizedBox(width: 7),
                          Flexible(
                            child: Text(
                              'Throughline',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Sign in',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Sync your follow-ups.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF929BA9),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_passwordStep)
                      TextField(
                        key: const Key('login-password'),
                        controller: _password,
                        focusNode: _passwordFocusNode,
                        autofocus: true,
                        keyboardType: TextInputType.visiblePassword,
                        textCapitalization: TextCapitalization.none,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        autocorrect: false,
                        enableSuggestions: false,
                        obscureText: !_showPassword,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip: _showPassword
                                ? 'Hide password'
                                : 'Show password',
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                          ),
                          filled: true,
                          fillColor: _surface,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                            borderSide: BorderSide(color: _mint, width: 1.5),
                          ),
                        ),
                      )
                    else
                      TextField(
                        key: const Key('login-username'),
                        controller: _username,
                        focusNode: _usernameFocusNode,
                        autofocus: true,
                        keyboardType: TextInputType.text,
                        textCapitalization: TextCapitalization.none,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => _advanceToPassword(),
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                          filled: true,
                          fillColor: _surface,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(14)),
                            borderSide: BorderSide(color: _mint, width: 1.5),
                          ),
                        ),
                      ),
                    if (widget.error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        widget.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFFF8F82),
                          fontSize: 11,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isSigningIn
                          ? null
                          : _passwordStep
                          ? _submit
                          : _advanceToPassword,
                      icon: _isSigningIn
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _ink,
                              ),
                            )
                          : Icon(
                              _passwordStep
                                  ? Icons.login_rounded
                                  : Icons.arrow_forward_rounded,
                              size: 18,
                            ),
                      label: Text(
                        _isSigningIn
                            ? 'Signing in'
                            : _passwordStep
                            ? 'Sign in'
                            : 'Continue',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: _mint,
                        foregroundColor: _ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF2C1C20),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: const TextStyle(fontSize: 11, color: Color(0xFFFFB4A8)),
        ),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Icon(icon, color: _mint, size: 19),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFFBBC2CC),
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({required this.task, required this.onDone});

  final BackendTask task;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF252D39)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.notifications_none_rounded,
              size: 17,
              color: _mint,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                task.description,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Text(
            task.dueLabel,
            style: const TextStyle(fontSize: 10, color: Color(0xFF929BA9)),
          ),
        ),
        const SizedBox(height: 9),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.check_rounded, size: 14),
            label: const Text('Done', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: _mint,
              side: const BorderSide(color: Color(0xFF385849)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({required this.api, super.key});

  final ThroughlineApi api;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _controller = TextEditingController();
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _isWorking = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    setState(() => _error = null);
    try {
      if (_isRecording) {
        final path = await _recorder.stop();
        if (mounted) setState(() => _isRecording = false);
        if (path == null) {
          throw StateError('The recording did not produce a file.');
        }
        await _transcribe(File(path));
        return;
      }
      if (!await _recorder.hasPermission()) {
        throw StateError('Microphone permission is required to record.');
      }
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}${Platform.pathSeparator}throughline-watch-${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (mounted) setState(() => _isRecording = true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _error = _apiError(error);
      });
    }
  }

  Future<void> _transcribe(File audioFile) async {
    setState(() {
      _isWorking = true;
      _error = null;
    });
    try {
      final transcript = await widget.api.transcribe(audioFile);
      if (!mounted) return;
      setState(() {
        _controller.text = transcript;
        _isWorking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isWorking = false;
        _error = _apiError(error);
      });
    } finally {
      if (await audioFile.exists()) await audioFile.delete();
    }
  }

  Future<void> _analyze() async {
    final transcript = _controller.text.trim();
    if (transcript.isEmpty || _isWorking || _isRecording) return;
    setState(() {
      _isWorking = true;
      _error = null;
    });
    try {
      final result = await widget.api.analyze(transcript);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isWorking = false;
        _error = _apiError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = (width * 0.08).clamp(0.0, 28.0).toDouble();
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            8,
            horizontalPadding,
            22,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WatchPageHeader(
                title: 'Quick capture',
                onBack: _isWorking || _isRecording
                    ? null
                    : () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 8),
              const Text(
                'Save this thought.',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              const Text(
                'Speak now or type with your watch.',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF929BA9),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isWorking ? null : _toggleRecording,
                  icon: Icon(
                    _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                  ),
                  label: Text(
                    _isRecording ? 'Stop recording' : 'Record a note',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: _isRecording
                        ? const Color(0xFFFF8F82)
                        : _surface,
                    foregroundColor: _isRecording ? _ink : _mint,
                  ),
                ),
              ),
              if (_isRecording) ...[
                const SizedBox(height: 7),
                const Center(
                  child: Text(
                    'Recording on this watch',
                    style: TextStyle(fontSize: 10, color: Color(0xFFFFB4A8)),
                  ),
                ),
              ],
              const SizedBox(height: 13),
              TextField(
                key: const Key('capture-input'),
                controller: _controller,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Type a thought…',
                  filled: true,
                  fillColor: _surface,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 9),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFFF8F82),
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 13),
              if (_isWorking)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _mint,
                    ),
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('save-capture'),
                    onPressed: _controller.text.trim().isEmpty || _isRecording
                        ? null
                        : _analyze,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: _mint,
                      foregroundColor: _ink,
                    ),
                    child: const Text('Save thought'),
                  ),
                ),
              const SizedBox(height: 6),
              const Center(
                child: Text(
                  'Throughline will find follow-ups.',
                  style: TextStyle(fontSize: 10, color: Color(0xFF747E8D)),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _apiError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    if (error.response == null) {
      return 'Could not reach Throughline. Check the connection and retry.';
    }
    return 'Request failed (${error.response!.statusCode}). Please retry.';
  }
  if (error is FormatException || error is StateError) return error.toString();
  return 'Something went wrong: $error';
}

String _shortDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

String _shortTime(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String _heartRateErrorMessage(Object error) {
  if (error is PlatformException) {
    return switch (error.code) {
      'heart_rate_permission_required' => 'Allow heart-rate access to measure.',
      'heart_rate_not_supported' => 'This watch cannot measure heart rate.',
      _ => 'Could not read heart rate. Please try again.',
    };
  }
  if (error is StateError) return error.message;
  if (error is FormatException) return error.message;
  return 'Could not read heart rate. Please try again.';
}
