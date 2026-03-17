# AGENTS.md - OpenClash Configuration Repository

## Overview

This repository contains OpenClash configuration files for proxy tunneling. It is NOT a code project - it contains only configuration files (YAML/INI) for OpenClash/Meta kernel. OpenClash is a Clash kernel implementation for OpenWrt that provides proxy functionality with advanced routing capabilities.

## File Structure

| File | Description |
|------|-------------|
| `config.yaml` | Basic OpenClash config (no DNS leak protection) |
| `configdns.yaml` | OpenClash config with DNS leak protection |
| `v2.ini` | Enhanced V2Ray config with full protocol support + DNS protection |
| `nodnsleak.ini` | Basic V2Ray config with DNS leak protection |

## Quick Start

1. Choose the appropriate config file for your needs
2. Replace placeholder subscription URLs with your actual机场 (airport) subscription
3. Validate the configuration syntax
4. Import into OpenClash dashboard
5. Test connectivity before production use

## Validation Commands

Always validate configuration files before committing or deploying:

```bash
# Validate YAML syntax (using Python)
python3 -c "import yaml; yaml.safe_load(open('config.yaml'))"

# Validate YAML syntax (using yq if installed)
yq validate config.yaml

# Validate INI syntax (using Python)
python3 -c "import configparser; c = configparser.ConfigParser(); c.read('v2.ini')"

# Check for common issues
python3 -c "
import yaml
with open('config.yaml') as f:
    data = yaml.safe_load(f)
    print('Valid YAML - Keys:', list(data.keys()))
"
```

## Configuration Conventions

### YAML Config Files (config.yaml, configdns.yaml)

- Use 2 spaces for indentation (NO tabs)
- Provider URLs must be quoted: `url: "https://..."`
- Use inline hash notation for simple proxies: `{name: 直连, type: direct}`
- Comments start with `#`
- Keep rulesets minimal - only include what you need
- Reference: https://wiki.metacubex.one/handbook/syntax/

### INI Config Files (v2.ini, nodnsleak.ini)

- Use backticks (\`) as delimiters in proxy_group definitions
- Format: `name`type`[]options
- ruleset format: `name,[]TYPE,value` or `name,https://...`
- Use semicolon (`;`) for comments
- Enable rule generator: `enable_rule_generator=true`
- Custom rulesets must be defined before proxy groups that use them

### Proxy Provider Configuration

```yaml
proxy-providers:
  Airport1:
    url: "机场订阅填到这里，两端引号不要去掉"
    type: http
    interval: 86400
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
    proxy: 直连
```

### Proxy Group Naming

- Use emoji prefixes: 🚀 (node selection), ♻️ (auto), 🌍 (all nodes)
- Country flags: 🇭🇰 🇹🇼 🇸🇬 🇯🇵 🇺🇸 🇰🇷 etc.
- Protocol labels: Hy2 节点, VLESS Reality, TUIC 节点, Trojan 节点

### Rule Precedence

Rules are evaluated top-to-bottom. Order matters:

1. DOMAIN-SUFFIX rules (specific domains) - most specific
2. DOMAIN rules
3. IP-CIDR rules
4. GEOIP rules (with no-resolve for domain requests)
5. FINAL (catch-all) - should be last resort

### DNS Configuration

- DNS leak protection prevents your DNS queries from bypassing the tunnel
- configdns.yaml includes strict DNS rules for China domains
- Foreign domains should be proxied to prevent DNS leaks

## DNS Leak Protection

For DNS leak protection, use `configdns.yaml` or the `*.ini` files which include:
- Strict DNS rules preventing DNS leaks
- China domain/IP whitelisting
- Foreign domain proxying
- FakeIP mode for better compatibility

## OpenClash References

- Official Wiki: https://wiki.metacubex.one/
- Clash Meta Syntax: https://wiki.metacubex.one/handbook/syntax/
- ACL4SSR Rules: https://github.com/ACL4SSR/ACL4SSR

## Git Workflow

1. Make changes to config files
2. Validate syntax before committing
3. Test with OpenClash before production use
4. Do not commit sensitive subscription URLs
5. Use descriptive commit messages

## Common Issues

- **DNS Leaks**: Use configdns.yaml or .ini files
- **Subscription Not Updating**: Check interval settings (minimum 3600)
- **Nodes Not Showing**: Verify subscription URL is correct
- **Rules Not Working**: Check rule precedence and ensure no conflicts
- **Panel Not Accessible**: Uncomment external-controller settings in YAML files
- **Performance Issues**: Keep rulesets minimal, avoid overly complex regex

## Supported Protocols

The configuration files support various proxy protocols:

- **VMess**: Standard V2Ray protocol
- **VLESS**: Lightweight V2Ray protocol with support for Reality
- **Trojan**: TLS-based proxy protocol
- **Shadowsocks (SS)**: Classic encrypted proxy, including SS2022
- **Hysteria2 (Hy2)**: High-performance UDP-based protocol
- **TUIC**: Modern QUIC-based protocol

## Best Practices

1. Always validate config before importing to OpenClash
2. Test new configurations in a staging environment first
3. Keep subscription URLs private - never commit them
4. Use health checks with reasonable intervals (300+ seconds)
5. Monitor logs during initial setup to identify issues
6. Backup working configurations before making changes

## Notes

- These configs use `global-client-fingerprint: chrome` for better compatibility
- Mixed port: 7890 (HTTP/SOCKS5 proxy)
- IPv6 is disabled by default
- Sniffer is enabled for HTTP/TLS traffic
- Keep-alive settings optimize long-lived connections
- Custom rulesets must be defined before proxy groups that reference them
- Health check interval should be at least 300 seconds to avoid overwhelming the test URL