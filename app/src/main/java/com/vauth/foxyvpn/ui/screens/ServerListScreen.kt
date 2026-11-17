package com.vauth.foxyvpn.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vauth.foxyvpn.R
import com.vauth.foxyvpn.data.ProxyStateStore
import com.vauth.foxyvpn.data.RECOMMENDED_COUNTRY_CODE
import com.vauth.foxyvpn.data.ServerListClient
import com.vauth.foxyvpn.data.model.VpnCountry
import com.vauth.foxyvpn.data.model.ConnectionState
import com.vauth.foxyvpn.data.model.emojiFlag
import com.vauth.foxyvpn.ui.ServerListViewModel
import com.vauth.foxyvpn.ui.ServerPingState
import com.vauth.foxyvpn.ui.ServerSpeedState
import com.vauth.foxyvpn.vpn.FoxyVpnService

private sealed class LocationRow {
    data class RecommendedRow(val country: VpnCountry) : LocationRow()

    data class CountryHeader(val country: VpnCountry) : LocationRow()

    data class CityRow(val country: VpnCountry, val cityIndex: Int) : LocationRow()
}

@Composable
fun ServerListScreen(
    serverListClient: ServerListClient,
    proxyStateStore: ProxyStateStore,
    onServerSelected: () -> Unit,
    onBack: () -> Unit,
    viewModel: ServerListViewModel =
        viewModel(factory = ServerListViewModel.factory(serverListClient, proxyStateStore, LocalContext.current)),
) {
    ServerListScreen(
        viewModel = viewModel,
        proxyStateStore = proxyStateStore,
        onServerSelected = onServerSelected,
        onBack = onBack,
    )
}

@Composable
fun ServerListScreen(
    viewModel: ServerListViewModel,
    proxyStateStore: ProxyStateStore,
    onServerSelected: () -> Unit,
    onBack: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val countries = state.countries
    val isLoading = state.isLoading
    val errorMessage = state.errorMessage
    val selectedState by proxyStateStore.selectedProxyFlow.collectAsStateWithLifecycle()
    val connectionState by FoxyVpnService.state.collectAsStateWithLifecycle()
    val serviceTesting by FoxyVpnService.locationTestRunning.collectAsStateWithLifecycle()
    val testing = state.isSpeedTesting || serviceTesting
    val canTest = !testing && connectionState == ConnectionState.DISCONNECTED
    val snackbarHost = remember { SnackbarHostState() }
    val context = LocalContext.current

    DisposableEffect(viewModel) {
        onDispose { viewModel.stopSpeedTests() }
    }

    LaunchedEffect(viewModel) {
        viewModel.loadServerList(force = true)
    }

    LaunchedEffect(errorMessage) {
        val message = errorMessage
        if (message != null && countries.isNotEmpty()) {
            snackbarHost.showSnackbar(message)
            viewModel.clearError()
        }
    }

    val ordered =
        remember(countries) {
            countries.sortedWith(compareBy({ it.code != RECOMMENDED_COUNTRY_CODE }, { it.name }))
        }

    val rows =
        remember(ordered) {
            buildList {
                for (country in ordered) {
                    if (country.code == RECOMMENDED_COUNTRY_CODE) {
                        add(LocationRow.RecommendedRow(country))
                        continue
                    }
                    add(LocationRow.CountryHeader(country))
                    country.cities.indices.forEach { index ->
                        add(LocationRow.CityRow(country, index))
                    }
                }
            }
        }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHost) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.server_list_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.action_back),
                        )
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                errorMessage != null && countries.isEmpty() ->
                    Column(
                        modifier = Modifier.align(Alignment.Center).padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(
                            errorMessage,
                            textAlign = TextAlign.Center,
                            color = MaterialTheme.colorScheme.error,
                        )
                        TextButton(
                            onClick = {
                                viewModel.loadServerList(force = true)
                            }
                        ) {
                            Text(stringResource(R.string.retry))
                        }
                    }
                else ->
                    LazyColumn(Modifier.selectableGroup()) {
                        item(key = "speed-test-controls") {
                            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    TextButton(
                                        enabled = canTest && selectedState != null,
                                        onClick = viewModel::testSelectedLocation,
                                    ) { Text(stringResource(R.string.speed_test_selected)) }
                                    TextButton(
                                        enabled = state.isSpeedTesting || canTest,
                                        onClick = {
                                            if (state.isSpeedTesting) viewModel.stopSpeedTests()
                                            else viewModel.testAllLocations()
                                        },
                                    ) {
                                        Text(stringResource(if (state.isSpeedTesting) R.string.speed_test_stop else R.string.speed_test_all))
                                    }
                                }
                                Text(
                                    stringResource(R.string.speed_test_quota_notice),
                                    style = MaterialTheme.typography.bodySmall,
                                )
                                if (connectionState != ConnectionState.DISCONNECTED && !testing) {
                                    Text(stringResource(R.string.speed_test_disconnect_first), style = MaterialTheme.typography.bodySmall)
                                }
                                if (state.isSpeedTesting) {
                                    Text(
                                        stringResource(R.string.speed_test_progress, state.speedTestCompleted, state.speedTestTotal),
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                            }
                        }
                        items(
                            rows,
                            key = { row ->
                                when (row) {
                                    is LocationRow.RecommendedRow ->
                                        "recommended:${row.country.code}"
                                    is LocationRow.CountryHeader -> "country:${row.country.code}"
                                    is LocationRow.CityRow ->
                                        "city:${row.country.code}:${row.country.cities[row.cityIndex].code}"
                                }
                            },
                        ) { row ->
                            val selected = selectedState
                            when (row) {
                                is LocationRow.RecommendedRow ->
                                    ListItem(
                                        leadingContent = {
                                            Icon(Icons.Filled.Public, contentDescription = null)
                                        },
                                        headlineContent = {
                                            Text(
                                                stringResource(R.string.server_list_recommended_title),
                                                fontWeight = FontWeight.SemiBold,
                                            )
                                        },
                                        supportingContent = {
                                            Column {
                                                Text(stringResource(R.string.server_list_recommended_desc))
                                                SpeedResult(state.speedResults["${row.country.code}:"], state.speedStates["${row.country.code}:"])
                                            }
                                        },
                                        trailingContent = {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                if (row.country.code == selected?.countryCode) {
                                                    Icon(Icons.Filled.CheckCircle, contentDescription = null)
                                                }
                                                IconButton(
                                                    enabled = canTest,
                                                    onClick = { viewModel.testLocation(ServerListClient.candidatesForCountry(countries, row.country.code)) },
                                                ) {
                                                    Icon(Icons.Filled.Speed, contentDescription = stringResource(R.string.speed_test_location, row.country.name))
                                                }
                                            }
                                        },
                                        modifier =
                                            Modifier.padding(horizontal = 8.dp)
                                                .selectable(
                                                    enabled = !testing,
                                                    selected =
                                                        row.country.code == selected?.countryCode,
                                                    role = Role.RadioButton,
                                                    onClick = {
                                                        val candidates =
                                                            ServerListClient.candidatesForCountry(
                                                                countries,
                                                                row.country.code,
                                                            )
                                                        val chosen = viewModel.preferredCandidate(candidates)
                                                        if (chosen != null) {
                                                            viewModel.selectCandidate(chosen)
                                                            onServerSelected()
                                                        } else {
                                                            viewModel.setErrorMessage(
                                                                context.getString(
                                                                    R.string.server_list_no_servers_country,
                                                                    row.country.name,
                                                                )
                                                            )
                                                        }
                                                    },
                                                ),
                                    )
                                is LocationRow.CountryHeader ->
                                    ListItem(
                                        leadingContent = {
                                            Text(
                                                text = row.country.emojiFlag,
                                                style = MaterialTheme.typography.titleLarge,
                                            )
                                        },
                                        headlineContent = {
                                            Text(row.country.name, fontWeight = FontWeight.SemiBold)
                                        },
                                        modifier = Modifier.padding(horizontal = 8.dp),
                                    )
                                is LocationRow.CityRow -> {
                                    val city = row.country.cities[row.cityIndex]
                                    val available =
                                        remember(countries, row.country.code, city.code) {
                                            ServerListClient.candidatesForCity(
                                                countries,
                                                row.country.code,
                                                city.code,
                                            )
                                        }
                                    val serverCount = available.size

                                    val pingKey = "${row.country.code}:${city.code}"
                                    val pingMs = state.pingResults[pingKey]
                                    val pingState =
                                        state.pingStates[pingKey] ?: ServerPingState.PENDING

                                    LaunchedEffect(pingKey, available, state.directoryRevision) {
                                        viewModel.probeCityLatency(
                                            row.country.code,
                                            city.code,
                                            available,
                                        )
                                    }

                                    ListItem(
                                        headlineContent = { Text(city.code) },
                                        supportingContent = {
                                            val primaryHostname = available.firstOrNull()?.host
                                            val serverLabel =
                                                when {
                                                    primaryHostname == null ->
                                                        stringResource(R.string.server_list_no_servers_available)
                                                    serverCount > 1 ->
                                                        stringResource(
                                                            R.string.server_list_more_servers,
                                                            primaryHostname,
                                                            serverCount - 1,
                                                        )
                                                    else -> primaryHostname
                                                }
                                            val pingLabel =
                                                when {
                                                    pingMs != null ->
                                                        stringResource(
                                                            R.string.server_list_tcp_ms,
                                                            pingMs,
                                                        )
                                                    pingState == ServerPingState.FAILED ->
                                                        stringResource(R.string.server_list_tcp_unavailable)
                                                    else ->
                                                        stringResource(R.string.server_list_checking_tcp)
                                                }
                                            Column {
                                                Text("$serverLabel \u2022 $pingLabel")
                                                SpeedResult(state.speedResults[pingKey], state.speedStates[pingKey])
                                            }
                                        },
                                        trailingContent = {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                if (row.country.code == selected?.countryCode && city.code == selected?.cityCode) {
                                                    Icon(Icons.Filled.CheckCircle, contentDescription = null)
                                                }
                                                IconButton(
                                                    enabled = canTest && available.isNotEmpty(),
                                                    onClick = { viewModel.testLocation(available) },
                                                ) {
                                                    Icon(Icons.Filled.Speed, contentDescription = stringResource(R.string.speed_test_location, city.code))
                                                }
                                            }
                                        },
                                        modifier =
                                            Modifier.padding(start = 24.dp, end = 8.dp)
                                                .selectable(
                                                    enabled = !testing,
                                                    selected =
                                                        row.country.code == selected?.countryCode &&
                                                            city.code == selected?.cityCode,
                                                    role = Role.RadioButton,
                                                    onClick = {
                                                        val candidates =
                                                            ServerListClient.candidatesForCity(
                                                                countries,
                                                                row.country.code,
                                                                city.code,
                                                            )
                                                        val chosen = viewModel.preferredCandidate(candidates)
                                                        if (chosen != null) {
                                                            viewModel.selectCandidate(chosen)
                                                            onServerSelected()
                                                        } else {
                                                            viewModel.setErrorMessage(
                                                                context.getString(
                                                                    R.string.server_list_no_servers_city,
                                                                    city.code,
                                                                )
                                                            )
                                                        }
                                                    },
                                                ),
                                    )
                                }
                            }
                        }
                    }
            }
        }
    }
}

@Composable
private fun SpeedResult(megabitsPerSecond: Double?, state: ServerSpeedState?) {
    val label = when (state) {
        ServerSpeedState.QUEUED -> stringResource(R.string.speed_test_queued)
        ServerSpeedState.RUNNING -> stringResource(R.string.speed_test_running)
        ServerSpeedState.DONE -> megabitsPerSecond?.let { stringResource(R.string.speed_test_mbps, it) }
        ServerSpeedState.FAILED -> stringResource(R.string.speed_test_failed)
        ServerSpeedState.TIMED_OUT -> stringResource(R.string.speed_test_timeout)
        ServerSpeedState.CANCELLED -> stringResource(R.string.speed_test_cancelled)
        null -> stringResource(R.string.speed_test_untested)
    }
    if (label != null) Text(label, color = if (state == ServerSpeedState.FAILED || state == ServerSpeedState.TIMED_OUT) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
}
