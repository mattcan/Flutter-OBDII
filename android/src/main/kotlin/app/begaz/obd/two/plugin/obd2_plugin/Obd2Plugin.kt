package app.mattcan.obd.two.plugin.obd2_plugin

import android.bluetooth.BluetoothAdapter
import android.content.Intent
import androidx.annotation.NonNull
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import android.bluetooth.BluetoothManager

import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.activity.ActivityAware


/** Obd2Plugin */
class Obd2Plugin: FlutterPlugin, MethodCallHandler, ActivityAware {
  private lateinit var channel: MethodChannel
  private lateinit var activity: Activity
  private var bluetoothAdapter: BluetoothAdapter? = null
  private val REQUEST_ENABLE_BLUETOOTH: Int = 1337
  private val REQUEST_DISCOVERABLE_BLUETOOTH: Int = 2137

  private var pendingResultForActivityResult: Result? = null

  // New activity result launchers
  private lateinit var enableBluetoothLauncher: ActivityResultLauncher<Intent>
  private lateinit var discoverableBluetoothLauncher: ActivityResultLauncher<Intent>

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
      this.activity = binding.activity
      val bluetoothManager: BluetoothManager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
      this.bluetoothAdapter = bluetoothManager.adapter

      // Register the new activity result API
      enableBluetoothLauncher = activity.registerForActivityResult(
          ActivityResultContracts.StartActivityForResult()
      ) { result ->
          if (pendingResultForActivityResult != null) {
              pendingResultForActivityResult?.success(result.resultCode != 0)
          }
      }

      discoverableBluetoothLauncher = activity.registerForActivityResult(
          ActivityResultContracts.StartActivityForResult()
      ) { result ->
          pendingResultForActivityResult?.success(if (result.resultCode == 0) -1 else result.resultCode)
      }
  }

  override fun onDetachedFromActivityForConfigChanges() {
      // Handle activity detach due to configuration change if needed
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
      // Handle re-attachment if necessary
      onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
      // Clean up any resources related to the activity
  }

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "obd2_plugin")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
        "enableBluetooth" -> {
            if (bluetoothAdapter?.isEnabled != true) {
                pendingResultForActivityResult = result
                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                enableBluetoothLauncher.launch(intent)
            } else {
                result.success(true)
            }
        }
        "getPlatformVersion" -> {
            result.success("Android ${android.os.Build.VERSION.RELEASE}")
        }
        else -> {
            result.notImplemented()
        }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
