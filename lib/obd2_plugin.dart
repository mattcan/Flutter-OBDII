import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:math_expressions/math_expressions.dart';

enum Mode { parameter, config, dtc, at }

enum ConnectionType { bluetooth, wifi }

// Define constants for magic numbers
const int defaultRequestCode = 999999999999999999;
const int dtcRequestCode = 1234;

class Obd2Plugin {
  static const MethodChannel _channel = MethodChannel('obd2_plugin');

  BluetoothState _bluetoothState = BluetoothState.UNKNOWN;
  final FlutterBluetoothSerial _bluetooth = FlutterBluetoothSerial.instance;

  static const String defaultWifiHost = '192.168.0.10';
  static const int defaultWifiPort = 35000;

  Socket? _wifiSocket;
  ConnectionType? _activeTransport;

  BluetoothConnection? connection;
  int requestCode = defaultRequestCode;
  String lastCommand = "";
  Function(String command, String response, int requestCode)? onResponse;
  Mode commandMode = Mode.at;
  List<String> dtcCodesResponse = [];
  bool sendDTCToResponse = false;
  dynamic runningService = '';
  List<dynamic> parameterResponse = [];

  // Handle platform version request
  static Future<String?> get platformVersion async {
    final String? version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  Future<BluetoothState> get initBluetooth async {
    _bluetoothState = await FlutterBluetoothSerial.instance.state;
    return _bluetoothState;
  }

  Future<bool> get enableBluetooth async {
    bool status = false;
    if (_bluetoothState == BluetoothState.STATE_OFF) {
      bool? newStatus = await FlutterBluetoothSerial.instance.requestEnable();
      status = newStatus ?? false;
    } else {
      status = true;
    }
    return status;
  }

  Future<bool> get disableBluetooth async {
    bool status = false;
    if (_bluetoothState == BluetoothState.STATE_ON) {
      bool? newStatus = await FlutterBluetoothSerial.instance.requestDisable();
      status = newStatus ?? false;
    }
    return status;
  }

  Future<bool> get isBluetoothEnable async {
    if (_bluetoothState == BluetoothState.STATE_OFF) {
      return false;
    } else if (_bluetoothState == BluetoothState.STATE_ON) {
      return true;
    } else {
      try {
        _bluetoothState = await initBluetooth;
        return await isBluetoothEnable;
      } catch (e) {
        throw Exception("OBD2 plugin not initialized");
      }
    }
  }

  Future<List<BluetoothDevice>> get getPairedDevices async {
    return await _bluetooth.getBondedDevices();
  }

  Future<List<BluetoothDevice>> get getNearbyDevices async {
    List<BluetoothDevice> discoveryDevices = [];
    return await _bluetooth.startDiscovery().listen((event) {
      final existingIndex =
          discoveryDevices.indexWhere((element) => element.address == event.device.address);
      if (existingIndex >= 0) {
        discoveryDevices[existingIndex] = event.device;
      } else {
        if (event.device.name != null) {
          discoveryDevices.add(event.device);
        }
      }
    }).asFuture(discoveryDevices);
  }

  Future<List<BluetoothDevice>> get getNearbyAndPairedDevices async {
    List<BluetoothDevice> discoveryDevices = await _bluetooth.getBondedDevices();
    await _bluetooth.startDiscovery().listen((event) {
      final existingIndex =
          discoveryDevices.indexWhere((element) => element.address == event.device.address);
      if (existingIndex >= 0) {
        discoveryDevices[existingIndex] = event.device;
      } else {
        if (event.device.name != null) {
          discoveryDevices.add(event.device);
        }
      }
    }).asFuture(discoveryDevices);
    return discoveryDevices;
  }

  Future<void> getConnection(
      BluetoothDevice _device, Function(BluetoothConnection? connection) onConnected, Function(String message) onError) async {
    try {
      if (connection != null) {
        onConnected(connection);
        return;
      }
      connection = await BluetoothConnection.toAddress(_device.address);
      if (connection != null) {
        _activeTransport = ConnectionType.bluetooth;
        onConnected(connection);
      } else {
        throw Exception("Unable to connect. Ensure the device is nearby or disconnected from previous connections.");
      }
    } catch (e) {
      onError("Connection failed: ${e.toString()}");
    }
  }

  Future<void> getWifiConnection({
    String host = defaultWifiHost,
    int port = defaultWifiPort,
    required Function() onConnected,
    required Function(String message) onError,
  }) async {
    try {
      if (_wifiSocket != null) {
        onConnected();
        return;
      }
      _wifiSocket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      _activeTransport = ConnectionType.wifi;
      onConnected();
    } catch (e) {
      _wifiSocket = null;
      _activeTransport = null;
      onError("WiFi connection failed: ${e.toString()}");
    }
  }

  Future<bool> disconnect() async {
    bool disconnected = false;
    if (_activeTransport == ConnectionType.wifi) {
      _wifiSocket?.destroy();
      _wifiSocket = null;
      _activeTransport = null;
      disconnected = true;
    } else if (connection?.isConnected == true) {
      await connection?.close();
      connection = null;
      _activeTransport = null;
      disconnected = true;
    } else {
      connection = null;
      _activeTransport = null;
    }
    return disconnected;
  }

  Future<int> getParamsFromJSON(String jsonString, {int lastIndex = 0, int requestCode = 5}) async {
    commandMode = Mode.parameter;
    List<dynamic> stm = [];
    try {
      stm = json.decode(jsonString);
    } catch (e) {
      throw Exception("Invalid JSON string.");
    }

    if (stm.isEmpty) {
      throw Exception("Empty JSON data.");
    }

    runningService = stm[lastIndex];
    bool configed = lastIndex == stm.length - 1;
    sendDTCToResponse = configed;
    _write(stm[lastIndex]["PID"], requestCode);

    if (!configed) {
      Future.delayed(const Duration(milliseconds: 350), () {
        getParamsFromJSON(jsonString, lastIndex: lastIndex + 1);
      });
    }

    return ((stm.length * 350) + 150);
  }

  Future<int> getDTCFromJSON(String jsonString, {int lastIndex = 0, int requestCode = dtcRequestCode}) async {
    commandMode = Mode.dtc;
    List<dynamic> stm = [];
    try {
      stm = json.decode(jsonString);
    } catch (e) {
      throw Exception("Invalid JSON string.");
    }

    if (stm.isEmpty) {
      throw Exception("Empty JSON data.");
    }

    bool configed = lastIndex == stm.length - 1;
    sendDTCToResponse = configed;
    _write(stm[lastIndex]["command"], requestCode);

    if (!configed) {
      Future.delayed(const Duration(milliseconds: 1000), () {
        getDTCFromJSON(jsonString, lastIndex: lastIndex + 1);
      });
    }

    return ((stm.length * 1000) + 150);
  }

  Future<int> configObdWithJSON(String jsonString, {int lastIndex = 0, int requestCode = 2}) async {
    commandMode = Mode.config;
    List<dynamic> stm = [];
    try {
      stm = json.decode(jsonString);
    } catch (e) {
      throw Exception("Invalid JSON string.");
    }

    if (stm.isEmpty) {
      throw Exception("Empty JSON data.");
    }

    _write(stm[lastIndex]["command"], requestCode);
    bool configed = lastIndex == stm.length - 1;

    if (!configed) {
      Future.delayed(Duration(milliseconds: stm[lastIndex]["command"] == "AT Z" || stm[lastIndex]["command"] == "ATZ" ? 1000 : 100), () {
        configObdWithJSON(jsonString, lastIndex: lastIndex + 1);
      });
    }

    return (stm.length * 150 + 1500);
  }

  Future<bool> pairWithDevice(BluetoothDevice _device) async {
    bool paired = false;
    bool? isPaired = await _bluetooth.bondDeviceAtAddress(_device.address);
    paired = isPaired ?? false;
    return paired;
  }

  Future<bool> unpairWithDevice(BluetoothDevice _device) async {
    bool unpaired = false;
    try {
      bool? isUnpaired = await _bluetooth.removeDeviceBondWithAddress(_device.address);
      unpaired = isUnpaired ?? false;
    } catch (e) {
      unpaired = false;
    }
    return unpaired;
  }

  Future<bool> isPaired(BluetoothDevice _device) async {
    BluetoothBondState state = await _bluetooth.getBondStateForAddress(_device.address);
    return state.isBonded;
  }

  Future<bool> get hasConnection async {
    return connection != null || _wifiSocket != null;
  }

  Future<void> _write(String command, int requestCode) async {
    lastCommand = command;
    this.requestCode = requestCode;
    final bytes = Uint8List.fromList(utf8.encode("$command\r\n"));
    if (_activeTransport == ConnectionType.wifi && _wifiSocket != null) {
      _wifiSocket!.add(bytes);
      await _wifiSocket!.flush();
    } else {
      connection?.output.add(bytes);
      await connection?.output.allSent;
    }
  }

  double _volEff = 0.8322;
  double _fTime(x) => x / 1000;
  double _fRpmToRps(x) => x / 60;
  double _fMbarToKpa(x) => x / 1000 * 100;
  double _fCelsiusToKelvin(x) => x + 273.15;

  double _fImap(rpm, pressMbar, tempC) {
    double _v = (_fMbarToKpa(pressMbar) / _fCelsiusToKelvin(tempC) / 2);
    return _fRpmToRps(rpm) * _v;
  }

  double fMaf(rpm, pressMbar, tempC) {
    double c = _fImap(rpm, pressMbar, tempC);
    double v = c * _volEff * 1.984 * 28.97;
    return v / 8.314;
  }

  double fFuel(rpm, pressMbar, tempC) {
    return (fMaf(rpm, pressMbar, tempC) * 3600) / (14.7 * 820);
  }

  Future<bool> get isListeningToData async {
    return onResponse != null;
  }

  Future<void> setOnDataReceived(Function(String command, String response, int requestCode) onResponse) async {
    String response = "";
    if (this.onResponse != null) {
      throw Exception("onDataReceived is already set.");
    }
    this.onResponse = onResponse;

    void dataHandler(Uint8List data) {
      String string = String.fromCharCodes(data);
      if (!string.contains('>')) {
        response += string;
      } else {
        response += string;
        _processResponse(response);
        response = "";
      }
    }

    if (_activeTransport == ConnectionType.wifi && _wifiSocket != null) {
      _wifiSocket!.listen(dataHandler,
          onError: (e) => print("WiFi data error: $e"),
          onDone: () => print("WiFi socket closed"));
    } else {
      connection?.input?.listen((Uint8List data) => dataHandler(data));
    }
  }

  void _processResponse(String response) {
    if (this.onResponse != null) {
      // Handle response processing for different modes (parameter, dtc, etc.)
      if (commandMode == Mode.parameter) {
        // Process parameter response logic here
        this.onResponse!('PARAMETER', json.encode(parameterResponse), requestCode);
      } else if (commandMode == Mode.dtc) {
        // Process DTC response logic here
        this.onResponse!('DTC', json.encode(dtcCodesResponse), requestCode);
      } else {
        // General command response
        this.onResponse!(lastCommand, response, requestCode);
      }
      // Reset command mode
      commandMode = Mode.at;
      requestCode = defaultRequestCode;
      lastCommand = "";
    }
  }
}
