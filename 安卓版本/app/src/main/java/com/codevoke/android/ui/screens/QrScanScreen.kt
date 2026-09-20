package com.codevoke.android.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.codevoke.android.ui.components.BlackCapsuleButton
import com.codevoke.android.ui.components.CodevokeGlassCard
import com.codevoke.android.ui.components.WhiteGlassBackground
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeRadius
import com.google.zxing.ResultPoint
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.DecoratedBarcodeView

/**
 * 扫码配对（契约 §6 配对入口之一）：扫电脑端设置页的 acode://pair?d=… 二维码。
 * zxing-android-embedded 的 DecoratedBarcodeView 内嵌取景，选中即返回。
 */
@Composable
fun QrScanScreen(
    goBack: () -> Unit,
    onScanned: (String) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var cameraGranted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var delivered by remember { mutableStateOf(false) }
    var barcodeView by remember { mutableStateOf<DecoratedBarcodeView?>(null) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> cameraGranted = granted }

    LaunchedEffect(Unit) {
        if (!cameraGranted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    DisposableEffect(lifecycleOwner, barcodeView) {
        val view = barcodeView ?: return@DisposableEffect onDispose {}
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> view.resume()
                Lifecycle.Event.ON_PAUSE -> view.pause()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        view.resume()
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            view.pause()
        }
    }

    Box(Modifier.fillMaxSize()) {
        WhiteGlassBackground(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = 18.dp, vertical = 22.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TopTitleBar(title = "扫码配对", goBack = goBack)
            if (cameraGranted) {
                AndroidView(
                    factory = { viewContext ->
                        DecoratedBarcodeView(viewContext).apply {
                            setStatusText("")
                            decodeSingle(object : BarcodeCallback {
                                override fun barcodeResult(result: BarcodeResult) {
                                    val text = result.text?.takeIf { it.isNotBlank() } ?: return
                                    if (delivered) return
                                    delivered = true
                                    // BarcodeCallback 可能在解码线程回调，统一回主线程导航。
                                    Handler(Looper.getMainLooper()).post { onScanned(text) }
                                }

                                override fun possibleResultPoints(resultPoints: List<ResultPoint>) = Unit
                            })
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .clip(RoundedCornerShape(CodevokeRadius.Chrome)),
                    update = { barcodeView = it },
                )
                Text(
                    "对准电脑端设置页显示的配对二维码",
                    color = CodevokeColor.Muted,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            } else {
                CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Text(
                            "扫码配对需要相机权限",
                            color = CodevokeColor.Ink,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            "相机仅用于扫描电脑端的配对二维码。没有相机时，也可以回到上一页改用「输入连接串」完成配对。",
                            color = CodevokeColor.Muted,
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                        )
                        BlackCapsuleButton(
                            text = "授予相机权限",
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(48.dp),
                            onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                        )
                    }
                }
            }
        }
    }
}
