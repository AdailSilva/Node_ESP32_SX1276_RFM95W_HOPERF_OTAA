package br.com.adailsilva.lorawan_node_otaa_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Canal "lorawan/wifi" usado por lib/core/wifi_helper.dart.
 *
 * O Soft AP do gateway/nó é uma rede Wi-Fi sem internet: sem isto o Android
 * manda o tráfego do app pelos dados móveis e 192.168.101.101 não responde.
 *  - bindWifi : prende o tráfego do app ao Wi-Fi atual (bindProcessToNetwork)
 *  - connectAp: conecta no Soft AP com WifiNetworkSpecifier (Android 10+) e
 *               prende o tráfego nele (o Android pede para o usuário confirmar)
 *  - unbind   : solta o tráfego e libera a conexão com o Soft AP
 */
class MainActivity : FlutterActivity() {
    private var apCallback: ConnectivityManager.NetworkCallback? = null
    private val main = Handler(Looper.getMainLooper())

    private val cm: ConnectivityManager
        get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lorawan/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindWifi" -> result.success(bindWifi())
                    "unbind" -> {
                        unbindAll()
                        result.success(true)
                    }
                    "connectAp" -> connectAp(
                        call.argument<String>("ssid") ?: "",
                        call.argument<String>("password") ?: "",
                        result
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /** bindProcessToNetwork existe só a partir da API 23 (Android 6). */
    @Suppress("DEPRECATION")
    private fun bindTo(n: Network?): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) cm.bindProcessToNetwork(n)
        else ConnectivityManager.setProcessDefaultNetwork(n)

    @Suppress("DEPRECATION")
    private fun bindWifi(): Boolean {
        return try {
            val wifi = cm.allNetworks.firstOrNull {
                cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
            }
            if (wifi != null) bindTo(wifi) else {
                bindTo(null)
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun unbindAll() {
        try {
            bindTo(null)
        } catch (e: Exception) {
        }
        apCallback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (e: Exception) {
            }
        }
        apCallback = null
    }

    private fun connectAp(ssid: String, password: String, result: MethodChannel.Result) {
        if (ssid.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(false)
            return
        }
        unbindAll()
        val builder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (password.isNotEmpty()) builder.setWpa2Passphrase(password)
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(builder.build())
            .build()
        var replied = false
        fun reply(ok: Boolean) {
            main.post {
                if (!replied) {
                    replied = true
                    result.success(ok)
                }
            }
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                bindTo(network)
                reply(true)
            }

            override fun onUnavailable() {
                reply(false)
            }

            override fun onLost(network: Network) {
                try {
                    bindTo(null)
                } catch (e: Exception) {
                }
            }
        }
        apCallback = cb
        try {
            cm.requestNetwork(request, cb, 30000)
        } catch (e: Exception) {
            apCallback = null
            reply(false)
        }
    }

    override fun onDestroy() {
        unbindAll()
        super.onDestroy()
    }
}
