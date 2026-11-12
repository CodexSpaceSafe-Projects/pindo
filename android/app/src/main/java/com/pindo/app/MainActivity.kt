package com.pindo.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private val store: AppStore by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val state by store.state.collectAsStateWithLifecycle()
            val dark = isPindoDarkTheme(state.preferences.theme)
            SideEffect {
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
            PindoTheme(theme = state.preferences.theme) {
                PindoScreen(store)
            }
        }
    }
    override fun onStart() { super.onStart(); store.startForeground() }
    override fun onStop() { store.stopForeground(); super.onStop() }
}
