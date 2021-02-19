import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

List<String> audioActivityLog = [];
int _audioCount = 1;

class MyAudioPlayer {
  static const int PLAY_TIMEOUT_RESULT = -1;
  static const POOL_SIZE = 20;
  // We use a pool of 20 players and never dispose these, the audioplayers lib
  // have a problem with dispose() on iOS so we simply do not dispose, just keep
  // on re-using them.
  static List<AudioPlayer> _playerPool;
  static int _poolIndex = 0;
  static int _filenameCounter = 0;
  final _completer = Completer();
  StreamSubscription<AudioPlayerState> _subStateChange;
  StreamSubscription<String> _subPlayerError;
  StreamSubscription<Duration> _subPosChange;
  StreamSubscription<Duration> _subDurationChange;
  File _file;
  Duration _currentPosition = Duration.zero;
  Duration _duration;
  int _currentPoolIndex;
  bool _stopped = false;

  AudioPlayer get _player => _playerPool[_currentPoolIndex];
  Duration get currentPosition => _currentPosition;

  MyAudioPlayer() {
    // Pool management must not be called from two instance of this class at the
    // same time. Dart is single threaded so as long as we dont use Futures we
    // are safe to initialize pool and assign a pool index without worrying
    // about conflicts from other instances of this class
    if (_playerPool == null) {
      _initializePool();
    }

    _allocateNextAvailablePool();

    _subStateChange = _player.onPlayerStateChanged.listen(_handleStateChange);
    _subPlayerError = _player.onPlayerError.listen(_handlePlayerError);
    _subPosChange = _player.onAudioPositionChanged.listen(_handlePosChange);
    _subDurationChange =
        _player.onDurationChanged.listen(_handleDurationChange);
  }

  void _initializePool() {
    _playerPool = List.generate(
      POOL_SIZE,
      (idx) {
        final ap = AudioPlayer(mode: PlayerMode.MEDIA_PLAYER);
        if (Platform.isIOS) {
          // Workaround for https://github.com/luanpotter/audioplayers/issues/344
          ap.monitorNotificationStateChanges(_audioPlayerStateChangeHandler);
          ap.startHeadlessService();
        }
        return ap;
      },
    );
  }

  void _allocateNextAvailablePool() {
    bool foundAvailablePlayer = false;
    int nextPoolIndex;

    for (int i = 0; i < POOL_SIZE; i++) {
      nextPoolIndex = _poolIndex++;
      if (_poolIndex >= POOL_SIZE) _poolIndex = 0;
      if (_playerPool[nextPoolIndex].state != AudioPlayerState.PLAYING &&
          _playerPool[nextPoolIndex].state != AudioPlayerState.PAUSED) {
        foundAvailablePlayer = true;
        break;
      }
    }
    if (!foundAvailablePlayer) {
      final exceptionMessage =
          'AudioPlayer._allocateNextAvailablePool(): No free player available (POOL_SIZE = $POOL_SIZE)';
      _reportError(exceptionMessage);
      throw Exception(exceptionMessage);
    }

    _currentPoolIndex = nextPoolIndex;
  }

  Future<void> _handleStateChange(AudioPlayerState s) async {
    if (s == AudioPlayerState.COMPLETED ||
        s == AudioPlayerState.STOPPED ||
        s == AudioPlayerState.PAUSED) {
      if (s == AudioPlayerState.PAUSED) {
        _addActivityLog('[UNEXPECTED] State change: $s');
        _reportError('AudioPlayerState.PAUSED');
        try {
          await _player.resume();
          // ignore: empty_catches
        } catch (e) {}
      } else {
        _addActivityLog('[OK] State change: $s');
      }

      await _handleSoundCompleted();
    }
  }

  void _addActivityLog(String message) {
    audioActivityLog.add('${_audioCount++} $message');
  }

  Future<void> _handlePlayerError(String s) async {
    // If an error occurs, the state should be changed to STOPPED and that will
    // delete the temporary file and clean up state.
    _reportError('AudioPlayer.onPlayerError(): $s');
    // In the case the sound isn't stopped, lets try to force stop it
    await _forceStop();
  }

  void _handlePosChange(Duration p) => _currentPosition = p;

  Future<void> _handleDurationChange(Duration duration) async {
    // Duration is called several times for the same file, why? Return if we
    // get notified with the same duration again.
    if (_duration == duration) return;
    _duration = duration;

    await _forcefullyStopIfNotCompleted5SecondsAfterExpectedDuration(
      _duration ?? Duration.zero,
    );
  }

  Future<void> _forceStop() async {
    if (_stopped) return;
    await _handleSoundCompleted();
  }

  Future<void> _handleSoundCompleted() async {
    _stopped = true;
    if (_subPlayerError != null) {
      await _subPlayerError.cancel();
      _subPlayerError = null;
    }
    if (_subStateChange != null) {
      await _subStateChange.cancel();
      _subStateChange = null;
    }
    if (_subPosChange != null) {
      await _subPosChange.cancel();
      _subPosChange = null;
    }
    if (_subDurationChange != null) {
      await _subDurationChange.cancel();
      _subDurationChange = null;
    }
    _duration = null;
    try {
      // This shouldn't be needed but lets call it just to be safe (?)
      await _player.stop();
      // ignore: empty_catches
    } catch (e) {}
    if (_file != null) {
      await _file.delete();
      _file = null;
    }

    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  Future<void> playAndWait(Uint8List audioData) async {
    _stopped = false;
    _currentPosition = Duration.zero;
    _duration = null;

    _file = await _writeTempFile(audioData);

    if (!await _file.exists()) {
      throw Exception('AudioPlayers: File does not exist: ${_file?.path}');
    }

    int result;
    try {
      final playFuture = _player.play(_file.path, isLocal: true);
      result = await playFuture.timeout(
        Duration(seconds: 5),
        onTimeout: _forcefullyStopIfPlayDoesNotReturnWithin5Sec,
      );
      if (result == PLAY_TIMEOUT_RESULT) {
        // Error is reported and sound is forcefully stopped, just return
        return;
      }
    } catch (e) {
      if (_player.state == AudioPlayerState.PLAYING) {
        await stopAudio();
      }
      await _forceStop();
    }

    if (result != 1) {
      await _forcefullyStopIfNotExpectedResultFromPlay(result);
    } else {
      // result = 1 indicates that the state is set to PLAYING
      await _forcefullyStopIfNoDurationAndNotCompletedWithin10Sec();
    }

    return _completer.future;
  }

  Future<void> stopAudio() async {
    await _player.stop();
  }

  Future<File> _writeTempFile(Uint8List data) async {
    final tempDir = await getTemporaryDirectory();
    final unique = _filenameCounter++;
    final path = '${tempDir.path}/audio-$unique.mp3';
    final file = File(path);

    await file.writeAsBytes(data, flush: true);

    return file;
  }

  Future<void> _forcefullyStopIfNotExpectedResultFromPlay(int result) async {
    _reportError(
      'AudioPlayer.play() returned result = $result for file: ${_file?.path}',
    );
    await _forceStop();
  }

  FutureOr<int> _forcefullyStopIfPlayDoesNotReturnWithin5Sec() async {
    _reportError(
      'AudioPlayer.play() did not return with result within 5 seconds. file: ${_file?.path}',
    );
    await _forceStop();

    return PLAY_TIMEOUT_RESULT;
  }

  Future<void> _forcefullyStopIfNotCompleted5SecondsAfterExpectedDuration(
    Duration expectedSoundDuration,
  ) async {
    final timeout = await _watchDogTimer(
      Duration(seconds: 5) + expectedSoundDuration,
      () => _stopped || _completer.isCompleted,
    );

    if (timeout) {
      // We're not completed with the sound 5 seconds after expected duration
      // forcefully end the sound by calling completed.
      _reportError(
        'AudioPlayer did not complete within 5 seconds of duration. Duration: $expectedSoundDuration, file: ${_file?.path}',
      );

      await _forceStop();
    }
  }

  Future<void> _forcefullyStopIfNoDurationAndNotCompletedWithin10Sec() async {
    final timeout = await _watchDogTimer(
      (Duration(seconds: 10)),
      () => _stopped || _duration != null || _completer.isCompleted,
    );

    if (timeout) {
      // We have not received a duration or completed the sound 10 seconds after
      // we called play(). This is likely a "crash". Report the error and
      // forcefully end the sound by calling completed.
      _reportError(
        'AudioPlayer did not receive a duration or complete within 10 seconds of play(). File: ${_file?.path}',
      );

      await _forceStop();
    }
  }

  void _reportError(String exceptionString) {
    _addActivityLog('[ERROR] $exceptionString');
    developer.log('Error: $exceptionString');
  }

  _watchDogTimer(Duration timeout, bool Function() predicate) async {
    Duration waitStep = Duration(milliseconds: 5);
    Duration waitTime = Duration.zero;
    while (!predicate()) {
      await Future.delayed(waitStep);

      waitTime += waitStep;

      if (waitTime >= timeout) {
        return !predicate();
      }
    }

    return !predicate();
  }
}

void _audioPlayerStateChangeHandler(AudioPlayerState state) => null;
