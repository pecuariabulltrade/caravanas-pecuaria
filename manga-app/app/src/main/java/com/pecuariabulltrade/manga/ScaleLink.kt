package com.pecuariabulltrade.manga

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Conexión con la balanza (XR5000) por Bluetooth clásico (SPP) o por cable USB (adaptador serie / CDC).
 * Entrega al listener cada línea de texto que manda la balanza.
 */
class ScaleLink(private val context: Context, private val listener: Listener) {

    interface Listener {
        fun onLine(line: String)
        fun onStatus(status: JSONObject)
        fun onLog(text: String)
    }

    companion object {
        private const val TAG = "ScaleLink"
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val ACTION_USB_PERMISSION = "com.pecuariabulltrade.manga.USB_PERMISSION"
    }

    @Volatile private var connected = false
    @Volatile private var via = ""          // "bluetooth" | "usb" | ""
    @Volatile private var deviceName = ""
    @Volatile private var lastError = ""
    private val stopFlag = AtomicBoolean(false)
    private var worker: Thread? = null
    private var btSocket: BluetoothSocket? = null
    private var usbPort: UsbSerialPort? = null
    private val adapter: BluetoothAdapter? by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    }

    // Reconexión automática mientras la app la pida
    @Volatile var autoReconnect = true
    @Volatile private var lastBtAddress: String? = null
    @Volatile private var usbBaud = 9600

    fun status(): JSONObject = JSONObject()
        .put("connected", connected)
        .put("via", via)
        .put("device", deviceName)
        .put("error", lastError)

    private fun publish() = listener.onStatus(status())
    private fun log(t: String) { Log.i(TAG, t); listener.onLog(t) }

    // ---------------- Bluetooth ----------------

    @SuppressLint("MissingPermission")
    fun pairedDevices(): String {
        val out = org.json.JSONArray()
        try {
            adapter?.bondedDevices?.forEach { d ->
                out.put(JSONObject().put("name", d.name ?: "").put("address", d.address))
            }
        } catch (e: SecurityException) {
            lastError = "Sin permiso de Bluetooth"
        }
        return out.toString()
    }

    fun bluetoothEnabled(): Boolean = adapter?.isEnabled == true

    @SuppressLint("MissingPermission")
    fun connectBluetooth(address: String) {
        disconnect(keepAuto = true)
        lastBtAddress = address
        stopFlag.set(false)
        worker = Thread {
            var attempt = 0
            while (!stopFlag.get()) {
                attempt++
                try {
                    val ad = adapter ?: throw IOException("La tablet no tiene Bluetooth")
                    if (!ad.isEnabled) throw IOException("Bluetooth apagado")
                    val dev = ad.getRemoteDevice(address)
                    deviceName = dev.name ?: address
                    try { ad.cancelDiscovery() } catch (_: Exception) {}
                    log("Conectando por Bluetooth a $deviceName (intento $attempt)…")
                    var sock: BluetoothSocket? = null
                    try {
                        sock = dev.createRfcommSocketToServiceRecord(SPP_UUID)
                        sock.connect()
                    } catch (e: IOException) {
                        try { sock?.close() } catch (_: Exception) {}
                        // Algunos equipos solo aceptan el canal 1 directo
                        val m = dev.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                        sock = m.invoke(dev, 1) as BluetoothSocket
                        sock.connect()
                    }
                    btSocket = sock
                    via = "bluetooth"; connected = true; lastError = ""
                    log("Conectado a $deviceName")
                    publish()
                    readLoop(sock!!.inputStream)
                } catch (e: Exception) {
                    lastError = e.message ?: e.toString()
                    log("Bluetooth: $lastError")
                } finally {
                    try { btSocket?.close() } catch (_: Exception) {}
                    btSocket = null
                    if (connected) { connected = false; via = ""; publish() }
                }
                if (stopFlag.get() || !autoReconnect) break
                publish()
                try { Thread.sleep(if (attempt < 3) 2000 else 5000) } catch (_: InterruptedException) { break }
            }
        }.apply { isDaemon = true; start() }
    }

    // ---------------- USB ----------------

    fun setUsbBaud(baud: Int) { usbBaud = baud }

    fun usbDevices(): String {
        val out = org.json.JSONArray()
        val mgr = context.getSystemService(Context.USB_SERVICE) as UsbManager
        for (drv in UsbSerialProber.getDefaultProber().findAllDrivers(mgr)) {
            val d = drv.device
            out.put(JSONObject().put("name", d.productName ?: drv.javaClass.simpleName)
                .put("vendor", d.vendorId).put("product", d.productId)
                .put("permiso", mgr.hasPermission(d)))
        }
        return out.toString()
    }

    fun connectUsb() {
        disconnect(keepAuto = true)
        val mgr = context.getSystemService(Context.USB_SERVICE) as UsbManager
        val drivers = UsbSerialProber.getDefaultProber().findAllDrivers(mgr)
        if (drivers.isEmpty()) {
            lastError = "No se encontró ningún dispositivo serie por USB"
            log(lastError); publish(); return
        }
        val driver = drivers[0]
        val device = driver.device
        if (!mgr.hasPermission(device)) {
            log("Pidiendo permiso para usar el USB…")
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(context, 0, Intent(ACTION_USB_PERMISSION).setPackage(context.packageName), flags)
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    try { context.unregisterReceiver(this) } catch (_: Exception) {}
                    val ok = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (ok) connectUsb() else { lastError = "Permiso USB denegado"; log(lastError); publish() }
                }
            }
            val filter = IntentFilter(ACTION_USB_PERMISSION)
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else context.registerReceiver(receiver, filter)
            mgr.requestPermission(device, pi)
            return
        }
        stopFlag.set(false)
        worker = Thread {
            try {
                val conn = mgr.openDevice(device) ?: throw IOException("No se pudo abrir el USB")
                val port = driver.ports[0]
                port.open(conn)
                port.setParameters(usbBaud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
                try { port.setDTR(true); port.setRTS(true) } catch (_: Exception) {}
                usbPort = port
                deviceName = device.productName ?: "USB serie"
                via = "usb"; connected = true; lastError = ""
                log("Conectado por USB a $deviceName ($usbBaud baud)")
                publish()
                val buf = ByteArray(1024)
                val sb = StringBuilder()
                while (!stopFlag.get()) {
                    val n = port.read(buf, 500)
                    if (n > 0) feed(sb, buf, n)
                }
            } catch (e: Exception) {
                lastError = e.message ?: e.toString()
                log("USB: $lastError")
            } finally {
                try { usbPort?.close() } catch (_: Exception) {}
                usbPort = null
                if (connected) { connected = false; via = ""; publish() }
            }
        }.apply { isDaemon = true; start() }
    }

    // ---------------- común ----------------

    private fun readLoop(input: InputStream) {
        val buf = ByteArray(1024)
        val sb = StringBuilder()
        while (!stopFlag.get()) {
            val n = input.read(buf)
            if (n < 0) throw IOException("La balanza cerró la conexión")
            if (n > 0) feed(sb, buf, n)
        }
    }

    private fun feed(sb: StringBuilder, buf: ByteArray, n: Int) {
        val s = String(buf, 0, n, Charsets.ISO_8859_1)
        for (ch in s) {
            if (ch == '\n' || ch == '\r') {
                if (sb.isNotEmpty()) { val line = sb.toString(); sb.setLength(0); listener.onLine(line) }
            } else {
                sb.append(ch)
                if (sb.length > 512) { val line = sb.toString(); sb.setLength(0); listener.onLine(line) }
            }
        }
    }

    fun disconnect(keepAuto: Boolean = false) {
        if (!keepAuto) autoReconnect = false
        stopFlag.set(true)
        try { btSocket?.close() } catch (_: Exception) {}
        try { usbPort?.close() } catch (_: Exception) {}
        worker?.interrupt()
        worker = null
        if (connected) { connected = false; via = ""; publish() }
        if (!keepAuto) autoReconnect = true
    }

    /** Reintenta la última conexión Bluetooth (p.ej. al volver a la app). */
    fun reconnectLast() {
        val a = lastBtAddress
        if (!connected && a != null) connectBluetooth(a)
    }
}
