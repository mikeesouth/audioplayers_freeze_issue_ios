import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers_freeze_issue_ios/my_audio_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audioplayers hangup repro',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(title: 'Audioplayers hangup/freeze on iOS repro'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const int ACTIVITY_LOG_CAP = 100;
  static const List<int> _playCount = [1, 10, 100, 1000, 5000];
  List<MyAudioPlayer> _activePlayers = [];
  List<bool> _playing = List.generate(_playCount.length, (index) => false);
  bool _delayedPlayed = false;
  bool _cancelPlaybacks = false;
  Uint8List audioData;

  @override
  void initState() {
    super.initState();

    initStateAsync();
  }

  Future<void> initStateAsync() async {
    final assetData = await rootBundle.load('assets/foo.mp3');
    final buffer = assetData.buffer;

    setState(() {
      audioData = buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(children: [
            SizedBox(height: 30),
            ..._buildButtons(),
            SizedBox(height: 30),
            _buildDelayedPlayedButton(),
            SizedBox(height: 30),
            _buildStopButton(),
            SizedBox(height: 30),
            _buildCancelButton(),
            SizedBox(height: 30),
            ..._buildActivityLogChildren(),
          ]),
        ),
      ),
    );
  }

  Widget _buildCancelButton() {
    return MaterialButton(
      child: Text('Cancel all playbacks'),
      color: Colors.red,
      disabledColor: Colors.red.withAlpha(100),
      onPressed: _playing.any((p) => p) ? () => _cancelPlaybacks = true : null,
    );
  }

  Widget _buildDelayedPlayedButton() {
    return MaterialButton(
      child: Text('Delay 5s => play foo.mp3 (x1)'),
      color: Colors.yellow,
      disabledColor: Colors.yellow.withAlpha(100),
      onPressed: _delayedPlayed
          ? null
          : () async {
              setState(() => _delayedPlayed = true);
              await Future.delayed(Duration(seconds: 5));
              await MyAudioPlayer().playAndWait(audioData);
              setState(() => _delayedPlayed = false);
            },
    );
  }

  Widget _buildStopButton() {
    return MaterialButton(
      child: Text('Stop active sounds'),
      color: Colors.orange,
      disabledColor: Colors.orange.withAlpha(100),
      onPressed: () => _activePlayers.forEach((ap) => ap.stopAudio()),
    );
  }

  List<Widget> _buildButtons() {
    return List.generate(_playCount.length, (index) {
      final canPlay = audioData != null && !_playing[index];

      return MaterialButton(
        child: Text('Play foo.mp3 (x${_playCount[index]})'),
        color: Colors.blue,
        disabledColor: Colors.blue.withAlpha(100),
        onPressed: canPlay ? () => _play(index) : null,
      );
    });
  }

  Future<void> _play(int index) async {
    setState(() => _playing[index] = true);
    for (int i = 0; i < _playCount[index]; i++) {
      final player = MyAudioPlayer();
      _activePlayers.add(player);
      await player.playAndWait(audioData);
      _activePlayers.remove(player);
      setState(() {}); // Update activity log
      if (_cancelPlaybacks) break;
    }
    setState(() => _playing[index] = false);

    // Stop cancel playbacks if all playing flags are false
    if (_cancelPlaybacks && !_playing.any((p) => p)) {
      _cancelPlaybacks = false;
    }
  }

  List<Widget> _buildActivityLogChildren() {
    final lastActivityLogEntries = audioActivityLog
        .skip(max(0, audioActivityLog.length - ACTIVITY_LOG_CAP))
        .take(ACTIVITY_LOG_CAP)
        .toList()
        .reversed
        .toList();

    return List.generate(
      lastActivityLogEntries.length,
      (index) => Text(lastActivityLogEntries[index]),
    );
  }
}
