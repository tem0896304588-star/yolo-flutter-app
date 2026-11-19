
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class CameraInferenceScreen extends StatefulWidget {
  const CameraInferenceScreen({super.key});

  @override
  State<CameraInferenceScreen> createState() =>
      _CameraInferenceScreenState();
}

class _CameraInferenceScreenState
    extends State<CameraInferenceScreen> {
  static const String deviceName = 'BirdAI-ESP32';

  static final Guid serviceUuid =
      Guid('12345678-1234-1234-1234-123456789000');

  static final Guid characteristicUuid =
      Guid('12345678-1234-1234-1234-123456789001');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  bool _connected = false;
  bool _connecting = false;
  bool _sending = false;
  bool _birdActive = false;

  int _birdFrames = 0;
  int _emptyFrames = 0;

  String _status = 'พร้อมใช้งาน';
  String _detectionStatus = 'กำลังรอผลตรวจจับ';

  @override
  void dispose() {
    _connectionSub?.cancel();
    FlutterBluePlus.stopScan();
    _device?.disconnect();
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    return statuses.values.every((status) => status.isGranted);
  }

  Future<void> _connectBLE() async {
    if (_connecting || _connected) return;

    setState(() {
      _connecting = true;
      _status = 'กำลังขอสิทธิ์ Bluetooth...';
    });

    try {
      final granted = await _requestPermissions();

      if (!granted) {
        throw Exception('กรุณาอนุญาต Bluetooth ในการตั้งค่าแอป');
      }

      if (!await FlutterBluePlus.isSupported) {
        throw Exception('อุปกรณ์ไม่รองรับ Bluetooth');
      }

      setState(() => _status = 'กำลังค้นหา ESP32...');

      await FlutterBluePlus.startScan(
        withNames: [deviceName],
        timeout: const Duration(seconds: 12),
      );

      await FlutterBluePlus.isScanning
          .where((scanning) => !scanning)
          .first;

      final results = FlutterBluePlus.lastScanResults;

      final matches = results.where((result) {
        return result.device.platformName == deviceName ||
            result.advertisementData.advName == deviceName;
      });

      if (matches.isEmpty) {
        throw Exception('ไม่พบ BirdAI-ESP32');
      }

      final device = matches.first.device;

      setState(() => _status = 'กำลังเชื่อมต่อ...');

      await device.connect(
        timeout: const Duration(seconds: 15),
      );

      final services = await device.discoverServices();

      BluetoothCharacteristic? target;

      for (final service in services) {
        if (service.uuid == serviceUuid) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == characteristicUuid) {
              target = characteristic;
              break;
            }
          }
        }
      }

      if (target == null) {
        await device.disconnect();
        throw Exception('ไม่พบ BLE Characteristic');
      }

      _device = device;
      _characteristic = target;

      await _connectionSub?.cancel();

      _connectionSub = device.connectionState.listen((state) {
        if (!mounted) return;

        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _connected = false;
            _characteristic = null;
            _birdActive = false;
            _status = 'การเชื่อมต่อหลุด';
          });
        }
      });

      if (!mounted) return;

      setState(() {
        _connected = true;
        _birdActive = false;
        _birdFrames = 0;
        _emptyFrames = 0;
        _status = 'เชื่อมต่อ BirdAI-ESP32 สำเร็จ';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'เชื่อมต่อไม่สำเร็จ: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  Future<bool> _sendCommand(String command) async {
    if (!_connected || _characteristic == null || _sending) {
      return false;
    }

    _sending = true;

    try {
      await _characteristic!.write(
        utf8.encode(command),
        withoutResponse: false,
      );

      if (mounted) {
        setState(() => _status = 'ส่งคำสั่ง $command สำเร็จ');
      }

      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'ส่งคำสั่งไม่สำเร็จ: $e');
      }

      return false;
    } finally {
      _sending = false;
    }
  }

  void _onYOLOResult(List<YOLOResult> results) {
    final birdDetected = results.any((result) {
      return result.className.toLowerCase() == 'bird' &&
          result.confidence >= 0.55;
    });

    if (birdDetected) {
      _birdFrames++;
      _emptyFrames = 0;

      if (mounted) {
        setState(() => _detectionStatus = 'พบนก');
      }

      if (_birdFrames >= 3 && !_birdActive && _connected) {
        unawaited(_activateBird());
      }
    } else {
      _emptyFrames++;
      _birdFrames = 0;

      if (mounted) {
        setState(() => _detectionStatus = 'ไม่พบนก');
      }

      if (_emptyFrames >= 15 && _birdActive && _connected) {
        unawaited(_deactivateBird());
      }
    }
  }

  Future<void> _activateBird() async {
    if (_birdActive) return;

    final success = await _sendCommand('BIRD');

    if (success && mounted) {
      setState(() => _birdActive = true);
    }
  }

  Future<void> _deactivateBird() async {
    if (!_birdActive) return;

    final success = await _sendCommand('STOP');

    if (success && mounted) {
      setState(() => _birdActive = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          YOLOView(
            modelPath: 'yolo26n',
            task: YOLOTask.detect,
            confidenceThreshold: 0.25,
            onResult: _onYOLOResult,
          ),

          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(14),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'BIRD AI SYSTEM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 12),

                    Text(
                      'การตรวจจับ: $_detectionStatus',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'BLE: ${_connected ? "CONNECTED" : "DISCONNECTED"}',
                      style: TextStyle(
                        color: _connected
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      _status,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed:
                            (_connected || _connecting)
                                ? null
                                : _connectBLE,
                        child: Text(
                          _connecting
                              ? 'กำลังเชื่อมต่อ...'
                              : _connected
                                  ? 'เชื่อมต่อแล้ว'
                                  : 'เชื่อมต่อ BirdAI-ESP32',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
