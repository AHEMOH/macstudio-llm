#!/usr/bin/env bash
# Launched by com.local.mqtt.bridge — publishes runtime telemetry to MQTT with
# Home Assistant autodiscovery and handles model-switch commands. Runs as root
# (this plist has no UserName): it reads `launchctl print system/*` and shells
# out to `setup.sh --set-model` to switch the main model. Stdlib python3 only.
set -eu

CONF=/usr/local/etc/macstudio.conf
[ -r "$CONF" ] && . "$CONF"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export MQTT_HOST="${MQTT_HOST:-}"
export MQTT_PORT="${MQTT_PORT:-1883}"
export MQTT_USER="${MQTT_USER:-}"
export MQTT_PASS="${MQTT_PASS:-}"
export MQTT_TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-macstudio}"
export MQTT_DISCOVERY_PREFIX="${MQTT_DISCOVERY_PREFIX:-homeassistant}"
export MQTT_PUBLISH_INTERVAL_SEC="${MQTT_PUBLISH_INTERVAL_SEC:-10}"

exec /usr/bin/python3 /usr/local/libexec/mqtt-bridge.py
