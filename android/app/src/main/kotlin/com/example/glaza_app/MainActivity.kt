package com.example.glaza_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val channelName = "glaza/network"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listIpv4" -> result.success(listIpv4())
                    "guessHotspotApIp" -> result.success(guessHotspotApIp())
                    "hasVpn" -> result.success(hasVpn())
                    else -> result.notImplemented()
                }
            }
    }

    private fun listIpv4(): List<Map<String, String>> {
        val out = ArrayList<Map<String, String>>()
        try {
            val en = NetworkInterface.getNetworkInterfaces() ?: return out
            while (en.hasMoreElements()) {
                val nif = en.nextElement()
                val name = nif.name ?: continue
                val addrs = nif.inetAddresses
                while (addrs.hasMoreElements()) {
                    val a = addrs.nextElement()
                    val host = a.hostAddress ?: continue
                    if (host.contains(':')) continue // skip IPv6
                    out.add(mapOf("name" to name, "ip" to host))
                }
            }
        } catch (_: Exception) {
        }

        // Дополнительно: LinkProperties активных сетей (Android 6+)
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                for (network in cm.allNetworks) {
                    val lp: LinkProperties = cm.getLinkProperties(network) ?: continue
                    val ifName = lp.interfaceName ?: "net"
                    for (la in lp.linkAddresses) {
                        val host = la.address.hostAddress ?: continue
                        if (host.contains(':')) continue
                        out.add(mapOf("name" to ifName, "ip" to host))
                    }
                }
            }
        } catch (_: Exception) {
        }
        return out
    }

    private fun guessHotspotApIp(): String? {
        val known = setOf(
            "192.168.43.1",
            "192.168.49.1",
            "192.168.137.1",
            "192.168.42.1",
            "192.168.0.1",
            "192.168.150.1",
            "192.168.1.1",
        )
        val all = listIpv4()
        for (e in all) {
            val ip = e["ip"] ?: continue
            if (known.contains(ip)) return ip
        }
        for (e in all) {
            val name = (e["name"] ?: "").lowercase()
            val ip = e["ip"] ?: continue
            if ((name.contains("ap") || name.contains("softap") ||
                        name.contains("swlan") || name == "wlan1" ||
                        name.contains("tether")) &&
                (ip.startsWith("192.168.") || ip.startsWith("10."))
            ) {
                return ip
            }
        }
        for (e in all) {
            val ip = e["ip"] ?: continue
            if (Regex("""^192\.168\.\d+\.1$""").matches(ip)) return ip
        }

        // WifiManager иногда знает IP интерфейса (не всегда softAP)
        try {
            @Suppress("DEPRECATION")
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val ipInt = wm.connectionInfo?.ipAddress ?: 0
            if (ipInt != 0) {
                val ip = String.format(
                    "%d.%d.%d.%d",
                    ipInt and 0xff,
                    ipInt shr 8 and 0xff,
                    ipInt shr 16 and 0xff,
                    ipInt shr 24 and 0xff,
                )
                if (ip.startsWith("192.168.") || ip.startsWith("10.")) return ip
            }
        } catch (_: Exception) {
        }
        return null
    }

    private fun hasVpn(): Boolean {
        return listIpv4().any {
            val n = (it["name"] ?: "").lowercase()
            n.startsWith("tun") || n.startsWith("ppp") || n.contains("vpn")
        }
    }
}
