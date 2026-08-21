package com.zhylee.discipline.mobile.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.zhylee.discipline.mobile.DisciplineApplication
import com.zhylee.discipline.mobile.model.PreviewScenario
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class PairingUiState(
  val code: String = "",
  val connecting: Boolean = false,
  val error: String? = null,
)

class DisciplineViewModel(application: Application) : AndroidViewModel(application) {
  private val discipline = application as DisciplineApplication
  val snapshot = discipline.repository.snapshot
  val paired = discipline.repository.paired

  private val mutablePairing = MutableStateFlow(PairingUiState())
  val pairing = mutablePairing.asStateFlow()

  fun updatePairingCode(value: String) {
    mutablePairing.value = mutablePairing.value.copy(code = value, error = null)
  }

  fun connect() {
    val code = mutablePairing.value.code.trim()
    if (code.isEmpty() || mutablePairing.value.connecting) return
    mutablePairing.value = mutablePairing.value.copy(connecting = true, error = null)
    viewModelScope.launch {
      runCatching { discipline.pairingManager.connect(code) }
        .onSuccess { mutablePairing.value = PairingUiState() }
        .onFailure { error ->
          mutablePairing.value = mutablePairing.value.copy(
            connecting = false,
            error = error.message ?: "Pairing failed",
          )
        }
    }
  }

  fun unpair() {
    if (mutablePairing.value.connecting) return
    mutablePairing.value = mutablePairing.value.copy(connecting = true, error = null)
    viewModelScope.launch {
      runCatching { discipline.pairingManager.unpair() }
        .onSuccess { mutablePairing.value = PairingUiState() }
        .onFailure { error ->
          mutablePairing.value = mutablePairing.value.copy(
            connecting = false,
            error = error.message ?: "Unpair failed",
          )
        }
    }
  }

  fun preview(scenario: PreviewScenario) {
    discipline.repository.preview(scenario)
  }

  fun refreshNotification() {
    discipline.repository.refreshNotification()
  }
}
