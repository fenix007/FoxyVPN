import Foundation

public enum TunnelConfigurationError: LocalizedError {
    case invalidPort
    case invalidInterface

    public var errorDescription: String? {
        switch self {
        case .invalidPort: return "The local proxy port is invalid."
        case .invalidInterface: return "The default network interface is invalid."
        }
    }
}

/// Builds the only tunnel configuration accepted by the privileged helper.
/// Keeping this in code prevents an unprivileged caller from asking the helper
/// to run an arbitrary sing-box configuration as root.
public enum TunnelConfiguration {
    public static func data(port: Int, interface: String, routing: RoutingSettings = RoutingSettings()) throws -> Data {
        guard (1...65_535).contains(port) else {
            throw TunnelConfigurationError.invalidPort
        }
        guard interface.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#,
            options: .regularExpression
        ) != nil else {
            throw TunnelConfigurationError.invalidInterface
        }

        let routing = try routing.validated()
        let bootstrapDomains = [
            "fastly-masque.net",
            "firefox.com",
            "mozilla.org",
            "services.mozilla.com",
        ]

        var dnsRules: [[String: Any]] = [
            ["domain_suffix": bootstrapDomains, "action": "route", "server": "bootstrap-dns"],
        ]
        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["port": 53, "action": "hijack-dns"],
            ["process_name": ["foxyvpn-proxy"], "action": "route", "outbound": "direct"],
            ["ip_is_private": true, "action": "route", "outbound": "direct"],
            ["network": "udp", "action": "reject"],
        ]
        if !routing.domainSuffixes.isEmpty {
            dnsRules.append(["domain_suffix": routing.domainSuffixes, "action": "route", "server": "bootstrap-dns"])
            routeRules.append(["domain_suffix": routing.domainSuffixes, "action": "route", "outbound": "direct"])
        }
        if !routing.directIPCIDRs.isEmpty {
            routeRules.append(["ip_cidr": routing.directIPCIDRs, "action": "route", "outbound": "direct"])
        }

        let configuration: [String: Any] = [
            "log": [
                "level": "info",
                "timestamp": true,
            ],
            "dns": [
                "servers": [
                    [
                        "type": "https",
                        "tag": "bootstrap-dns",
                        "server": "1.1.1.1",
                        "server_port": 443,
                        "tls": [
                            "enabled": true,
                            "server_name": "cloudflare-dns.com",
                        ],
                        "detour": "direct",
                    ],
                    [
                        "type": "https",
                        "tag": "remote-dns",
                        "server": "1.1.1.1",
                        "server_port": 443,
                        "tls": [
                            "enabled": true,
                            "server_name": "cloudflare-dns.com",
                        ],
                        "detour": "proxy",
                    ],
                ],
                "rules": dnsRules,
                "final": "remote-dns",
                "strategy": "prefer_ipv4",
                "independent_cache": true,
                "reverse_mapping": true,
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": [
                        "172.19.0.1/30",
                        "fdfe:dcba:9876::1/126",
                    ],
                    "mtu": 1_400,
                    "stack": "system",
                    "auto_route": true,
                    "strict_route": true,
                ],
            ],
            "outbounds": [
                [
                    "type": "socks",
                    "tag": "proxy",
                    "server": "127.0.0.1",
                    "server_port": port,
                    "version": "5",
                ],
                [
                    "type": "direct",
                    "tag": "direct",
                    "bind_interface": interface,
                ],
            ],
            "route": [
                "rules": routeRules,
                "final": "proxy",
                "default_domain_resolver": "bootstrap-dns",
                "auto_detect_interface": true,
            ],
        ]

        return try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
