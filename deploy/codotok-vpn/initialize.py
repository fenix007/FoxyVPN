#!/usr/bin/env python3
"""Generate dedicated VPN credentials on the VPS without logging them."""
import base64
import json
import os
from pathlib import Path
import secrets

os.umask(0o077)
root = Path(__file__).resolve().parent
config = root / 'server.json'
profile = root / 'codotok-vpn.foxyvpn.json'
if config.exists() or profile.exists():
    raise SystemExit('Existing VPN credentials retained; initialization refused.')
key = base64.b64encode(secrets.token_bytes(32)).decode('ascii')
server = {
    'log': {'level': 'warn', 'timestamp': True},
    'dns': {
        'servers': [{'type': 'https', 'tag': 'resolver', 'server': '1.1.1.1',
                     'server_port': 443, 'tls': {'enabled': True, 'server_name': 'cloudflare-dns.com'}}],
        'final': 'resolver',
    },
    'inbounds': [{'type': 'shadowsocks', 'tag': 'vpn-in', 'listen': '0.0.0.0',
                  'listen_port': 18443, 'network': 'tcp',
                  'method': '2022-blake3-aes-256-gcm', 'password': key}],
    'outbounds': [{'type': 'direct', 'tag': 'internet'}],
    'route': {
        'default_domain_resolver': 'resolver',
        'rules': [
            {'action': 'resolve', 'server': 'resolver', 'strategy': 'ipv4_only'},
            {'ip_is_private': True, 'action': 'reject'},
            {'ip_cidr': ['5.253.63.18/32', '::ffff:5.253.63.18/128', '0.0.0.0/8',
                         '100.64.0.0/10', '198.18.0.0/15', '169.254.0.0/16', '224.0.0.0/3'], 'action': 'reject'},
            {'port': [25, 465, 587], 'action': 'reject'},
        ],
        'final': 'internet',
    },
}
client = {
    'version': 1, 'name': 'Codotok VPS · Netherlands', 'server': '5.253.63.18',
    'serverPort': 18443, 'method': '2022-blake3-aes-256-gcm', 'password': key,
    'routing': {'mode': 'allTraffic', 'bypassRussianDomains': True,
                'directDomains': ['codotok.sale'], 'directIPCIDRs': [], 'vpnDomains': [],
                'routeCodingClients': False},
}
for path, value in ((config, server), (profile, client)):
    with path.open('x', encoding='utf-8') as handle:
        json.dump(value, handle, indent=2)
        handle.write('\n')
    path.chmod(0o600)
print('Dedicated server configuration and FoxyVPN profile created; secret values omitted.')
