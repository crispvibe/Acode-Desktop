package com.codevoke.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import com.codevoke.android.ui.screens.CodevokeApp
import com.codevoke.android.ui.theme.CodevokeTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContent {
            CodevokeTheme {
                CodevokeApp()
            }
        }
    }
}
