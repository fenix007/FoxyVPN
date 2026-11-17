package com.vauth.foxyvpn.ui

import android.content.Context
import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.vauth.foxyvpn.data.ProxyStateStore
import com.vauth.foxyvpn.data.ServerListClient
import com.vauth.foxyvpn.data.QuotaExceededError
import com.vauth.foxyvpn.data.SecureStorageException
import com.vauth.foxyvpn.data.TokenInvalidError
import com.vauth.foxyvpn.data.FxaRefreshFailure
import com.vauth.foxyvpn.data.GuardianHttpError
import com.vauth.foxyvpn.data.model.ConnectionState
import com.vauth.foxyvpn.data.model.ProxyCandidate
import com.vauth.foxyvpn.data.model.VpnCountry
import com.vauth.foxyvpn.vpn.FoxyVpnService
import com.vauth.foxyvpn.vpn.PingUtil
import java.net.SocketTimeoutException
import java.util.concurrent.TimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

enum class ServerPingState {
    PENDING,
    DONE,
    FAILED,
}

enum class ServerSpeedState { QUEUED, RUNNING, DONE, FAILED, TIMED_OUT, CANCELLED }

data class ServerListUiState(
    val countries: List<VpnCountry> = emptyList(),
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
    val pingResults: Map<String, Int> = emptyMap(),
    val pingStates: Map<String, ServerPingState> = emptyMap(),
    val directoryRevision: Int = 0,
    val speedResults: Map<String, Double> = emptyMap(),
    val speedCandidates: Map<String, ProxyCandidate> = emptyMap(),
    val speedStates: Map<String, ServerSpeedState> = emptyMap(),
    val isSpeedTesting: Boolean = false,
    val speedTestCompleted: Int = 0,
    val speedTestTotal: Int = 0,
)

class ServerListViewModel(
    private val serverListClient: ServerListClient,
    private val proxyStateStore: ProxyStateStore,
    context: Context,
) : ViewModel() {

    private val application = context.applicationContext as Application

    private val _state = MutableStateFlow(ServerListUiState())
    val state: StateFlow<ServerListUiState> = _state.asStateFlow()

    private val probeSlots = Semaphore(4)
    private var speedJob: Job? = null
    private var directoryJob: Job? = null

    init {
        loadServerList(force = false)
    }

    fun loadServerList(force: Boolean = false) {
        if (_state.value.isSpeedTesting || directoryJob?.isActive == true) return
        directoryJob = viewModelScope.launch {
            if (_state.value.countries.isEmpty()) {
                _state.update { it.copy(isLoading = true, errorMessage = null) }
            }
            if (!force) {
                val cached = withContext(Dispatchers.IO) { serverListClient.loadCachedCountries() }
                if (cached.isNotEmpty()) {
                    _state.update { it.copy(countries = cached, isLoading = false) }
                }
            }
            try {
                val fresh = withContext(Dispatchers.IO) { serverListClient.fetchCountries() }
                _state.update { current ->
                    if (current.isSpeedTesting) return@update current.copy(isLoading = false)
                    val retained = current.speedCandidates.filterValues { candidate ->
                        ServerListClient.candidatesForCountry(fresh, candidate.countryCode).contains(candidate)
                    }
                    current.copy(
                        countries = fresh,
                        isLoading = false,
                        errorMessage = null,
                        pingResults = emptyMap(),
                        pingStates = emptyMap(),
                        speedResults = current.speedResults.filterKeys { it in retained },
                        speedCandidates = retained,
                        speedStates = retained.keys.associateWith { ServerSpeedState.DONE },
                        directoryRevision = current.directoryRevision + 1,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                _state.update { current ->
                    current.copy(
                        isLoading = false,
                        errorMessage = error.message ?: "Failed to load server list",
                    )
                }
            }
        }
    }

    fun testAllLocations() {
        val targets = buildList {
            for (country in _state.value.countries) {
                if (country.code == com.vauth.foxyvpn.data.RECOMMENDED_COUNTRY_CODE) {
                    ServerListClient.candidatesForCountry(_state.value.countries, country.code)
                        .firstOrNull()?.let { add(it) }
                } else {
                    for (city in country.cities) {
                        ServerListClient.candidatesForCity(_state.value.countries, country.code, city.code)
                            .firstOrNull()?.let { add(it) }
                    }
                }
            }
        }
        testCandidates(targets)
    }

    fun testSelectedLocation() {
        val selected = proxyStateStore.selectedProxyFlow.value ?: return
        val available = if (selected.countryCode == com.vauth.foxyvpn.data.RECOMMENDED_COUNTRY_CODE) {
            ServerListClient.candidatesForCountry(_state.value.countries, selected.countryCode)
        } else {
            ServerListClient.candidatesForCity(_state.value.countries, selected.countryCode, selected.cityCode)
        }
        val target = available.firstOrNull { it.host == selected.host && it.port == selected.port }
            ?: available.firstOrNull() ?: return
        testCandidates(listOf(target))
    }

    fun testLocation(available: List<ProxyCandidate>) {
        available.firstOrNull()?.let { testCandidates(listOf(it)) }
    }

    private fun testCandidates(candidates: List<ProxyCandidate>) {
        if (_state.value.isSpeedTesting || candidates.isEmpty()) return
        if (FoxyVpnService.state.value != ConnectionState.DISCONNECTED || FoxyVpnService.locationTestRunning.value) {
            setErrorMessage(application.getString(com.vauth.foxyvpn.R.string.speed_test_disconnect_first))
            return
        }
        val targets = candidates.distinctBy { speedKey(it) }
        _state.update { current ->
            val keys = targets.map { speedKey(it) }.toSet()
            current.copy(
                isSpeedTesting = true,
                speedTestCompleted = 0,
                speedTestTotal = targets.size,
                speedResults = current.speedResults - keys,
                speedCandidates = current.speedCandidates - keys,
                speedStates = current.speedStates + keys.associateWith { ServerSpeedState.QUEUED },
            )
        }
        speedJob = viewModelScope.launch {
            try {
                for (candidate in targets) {
                    ensureActive()
                    val key = speedKey(candidate)
                    _state.update { it.copy(speedStates = it.speedStates + (key to ServerSpeedState.RUNNING)) }
                    try {
                        val result = withTimeout(45_000L) {
                            FoxyVpnService.measureLocationSpeed(application, candidate)
                        }
                        _state.update {
                            it.copy(
                                speedResults = it.speedResults + (key to result.megabitsPerSecond),
                                speedCandidates = it.speedCandidates + (key to candidate),
                                speedStates = it.speedStates + (key to ServerSpeedState.DONE),
                            )
                        }
                    } catch (_: TimeoutCancellationException) {
                        ensureActive()
                        _state.update { it.copy(speedStates = it.speedStates + (key to ServerSpeedState.TIMED_OUT)) }
                    } catch (cancelled: CancellationException) {
                        _state.update { it.copy(speedStates = it.speedStates + (key to ServerSpeedState.CANCELLED)) }
                        throw cancelled
                    } catch (_: SocketTimeoutException) {
                        _state.update { it.copy(speedStates = it.speedStates + (key to ServerSpeedState.TIMED_OUT)) }
                    } catch (_: TimeoutException) {
                        _state.update { it.copy(speedStates = it.speedStates + (key to ServerSpeedState.TIMED_OUT)) }
                    } catch (error: Exception) {
                        _state.update { it.copy(speedStates = it.speedStates + (key to ServerSpeedState.FAILED)) }
                        setErrorMessage(error.message ?: "Location speed test failed")
                        if (error is TokenInvalidError || error is QuotaExceededError ||
                            error is SecureStorageException || error is IllegalStateException ||
                            (error is GuardianHttpError && error.statusCode in listOf(401, 403, 429)) ||
                            (error is FxaRefreshFailure && error.permanent)) break
                    }
                    _state.update { it.copy(speedTestCompleted = it.speedTestCompleted + 1) }
                }
            } finally {
                _state.update { current ->
                    current.copy(
                        isSpeedTesting = false,
                        speedStates = current.speedStates.filterValues { it != ServerSpeedState.QUEUED },
                    )
                }
            }
        }
    }

    fun stopSpeedTests() { speedJob?.cancel() }

    fun preferredCandidate(available: List<ProxyCandidate>): ProxyCandidate? {
        val first = available.firstOrNull() ?: return null
        val tested = _state.value.speedCandidates[speedKey(first)]
        return tested?.takeIf { available.contains(it) } ?: available.randomOrNull()
    }

    private fun speedKey(candidate: ProxyCandidate) =
        "${candidate.countryCode}:${if (candidate.countryCode == com.vauth.foxyvpn.data.RECOMMENDED_COUNTRY_CODE) "" else candidate.cityCode}"

    fun probeCityLatency(countryCode: String, cityCode: String, available: List<ProxyCandidate>) {
        val pingKey = "$countryCode:$cityCode"
        if (_state.value.pingStates.containsKey(pingKey)) return

        _state.update { it.copy(pingStates = it.pingStates + (pingKey to ServerPingState.PENDING)) }

        val target = available.firstOrNull()?.let { it.host to it.port }
        if (target == null) {
            _state.update { it.copy(pingStates = it.pingStates + (pingKey to ServerPingState.FAILED)) }
            return
        }

        viewModelScope.launch {
            val result =
                try {
                    probeSlots.withPermit {
                        withContext(Dispatchers.IO) {
                            PingUtil.measureTcpLatencyMs(target.first, target.second)
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    null
                }

            if (result != null) {
                _state.update {
                    it.copy(
                        pingResults = it.pingResults + (pingKey to result),
                        pingStates = it.pingStates + (pingKey to ServerPingState.DONE),
                    )
                }
            } else {
                _state.update {
                    it.copy(pingStates = it.pingStates + (pingKey to ServerPingState.FAILED))
                }
            }
        }
    }

    fun selectCandidate(candidate: ProxyCandidate) {
        if (_state.value.isSpeedTesting) return
        proxyStateStore.save(candidate)
    }

    fun clearError() {
        _state.update { it.copy(errorMessage = null) }
    }

    fun setErrorMessage(message: String) {
        _state.update { it.copy(errorMessage = message) }
    }

    companion object {
        fun factory(serverListClient: ServerListClient, proxyStateStore: ProxyStateStore, context: Context) =
            viewModelFactory {
                initializer { ServerListViewModel(serverListClient, proxyStateStore, context.applicationContext) }
            }
    }
}
