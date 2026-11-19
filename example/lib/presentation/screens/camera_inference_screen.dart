
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class CameraInferenceScreen extends StatefulWidget {
  const CameraInferenceScreen({super.key});

  @override
  State<CameraInferenceScreen> createState() =>
      _CameraInferenceScreenState();
}

class _CameraInferenceScreenState
    extends State<CameraInferenceScreen> {
  // ESP32-CAM BLE settings
  static const String deviceName = 'BirdAI-ESP32';

  static final Guid serviceUuid =
      Guid('12345678-1234-1234-1234-123456789000');

  static final Guid characteristicUuid =
      Guid('12345678-1234-1234-1234-123456789001');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;

  bool _connected = false;
  bool _connecting = false;
  bool _sending = false;

  String _status = 'ยังไม่ได้เชื่อมต่อ ESP32';

  int _birdFrames = 0;
  int _emptyFrames = 0;

  bool _birdActive = false;

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    _device?.disconnect();
    super.dispose();
  }

  // Connect to ESP32-CAM
  Future<void> _connectBLE() async {
    if (_connecting || _connected) return;

    setState(() {
      _connecting = true;
      _status = 'กำลังค้นหา ESP32...';
    });

    try {
      if (!await FlutterBluePlus.isSupported) {
        throw Exception('โทรศัพท์ไม่รองรับ Bluetooth');
      }

      await FlutterBluePlus.startScan(
        withNames: [deviceName],
        timeout: const Duration(seconds: 10),
      );

      await FlutterBluePlus.isScanning
          .where((scanning) => scanning == false)
          .first;

      final results = FlutterBluePlus.lastScanResults;

      final matches = results.where((r) =>
          r.device.platformName == deviceName ||
          r.advertisementData.advName == deviceName);

      if (matches.isEmpty) {
        throw Exception('ไม่พบ BirdAI-ESP32');
      }

      final device = matches.first.device;

      await device.connect(
        timeout: const Duration(seconds: 15),
      );

      final services = await device.discoverServices();

      BluetoothCharacteristic? target;

      for (final service in services) {
        if (service.uuid == serviceUuid) {
          for (final characteristic
              in service.characteristics) {
            if (characteristic.uuid ==
                characteristicUuid) {
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

      device.connectionState.listen((state) {
        if (!mounted) return;

        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _connected = false;
            _characteristic = null;
            _status = 'ESP32 หลุดการเชื่อมต่อ';
          });
        }
      });

      if (!mounted) return;

      setState(() {
        _connected = true;
        _status = 'เชื่อมต่อ BirdAI-ESP32 แล้ว';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'เชื่อมต่อไม่สำเร็จ: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    }
  }

  // Send command to ESP32
  Future<void> _sendCommand(String command) async {
    if (!_connected ||
        _characteristic == null ||
        _sending) {
      return;
    }

    _sending = true;

    try {
      await _characteristic!.write(
        utf8.encode(command),
      );

      if (mounted) {
        setState(() {
          _status = 'ส่งคำสั่ง $command แล้ว';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'ส่งคำสั่งไม่สำเร็จ: $e';
        });
      }
    } finally {
      _sending = false;
    }
  }

  // Receive YOLO detection results
  void _onYOLOResult(List<YOLOResult> results) {
    final birdDetected = results.any((result) =>
        result.className.toLowerCase() == 'bird' &&
        result.confidence >= 0.55);

    if (birdDetected) {
      _birdFrames++;
      _emptyFrames = 0;

      if (_birdFrames >= 3 && !_birdActive) {
        _birdActive = true;
        unawaited(_sendCommand('BIRD'));
      }
    } else {
      _emptyFrames++;
      _birdFrames = 0;

      if (_emptyFrames >= 15 && _birdActive) {
        _birdActive = false;
        unawaited(_sendCommand('STOP'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // YOLO live camera
          YOLOView(
            modelPath: 'yolo26n',
            task: YOLOTask.detect,
            confidenceThreshold: 0.25,
            onResult: _onYOLOResult,
          ),

          // BLE connection panel
          Positioned(
            top: 45,
            left: 15,
            right: 15,
            child: Card(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Text(
                      _status,
                      style: const TextStyle(
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed:
                          (_connected || _connecting)
                              ? null
                              : _connectBLE,
                      child: Text(
                        _connecting
                            ? 'กำลังเชื่อมต่อ...'
                            : _connected
                                ? 'เชื่อมต่อแล้ว'
                                : 'เชื่อมต่อ ESP32-CAM',
                      ),
                    ),
                    Text(
                      'BLE: ${_connected ? "CONNECTED" : "DISCONNECTED"}',
                      style: TextStyle(
                        color: _connected
                            ? Colors.greenAccent
                            : Colors.redAccent,
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
