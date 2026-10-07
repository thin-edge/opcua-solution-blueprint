#!/bin/sh
# Device side of `opcua-demo.sh start <device> --connector tedge-dot`, run as the tedge user by a
# c8y_Command operation once the tedge-dot package is installed:
#
#   curl -fsSL <base-url>/tedge-dot/setup-opcua-pump.sh | sh -s -- <base-url>
#
# 1. installs the connector config for the demo pump (opcua-pump.toml),
# 2. publishes the measurement units as retained thin-edge.io measurement metadata,
# 3. reloads tedge-dot, which starts a connector for the new file.
set -e

BASE_URL="${1:?usage: setup-opcua-pump.sh <base-url>}"
CONFIG_DIR=/etc/tedge/plugins/ot

fetch() {
    curl -fsSL "$1" 2>/dev/null || wget -qO- "$1"
}

fetch "$BASE_URL/tedge-dot/opcua-pump.toml" > "$CONFIG_DIR/opcua-pump.toml.tmp"
mv "$CONFIG_DIR/opcua-pump.toml.tmp" "$CONFIG_DIR/opcua-pump.toml"

# tedge-dot 0.0.11 carries a point's unit in its samples but not in the measurement it maps them
# to; thin-edge.io 2.x adds units from retained metadata on te/<device>/m/<type>/meta instead.
# Measurement type, fragment and series share the variable's name, as with the OPC-UA gateway.
unit() {
    tedge mqtt pub -r "te/device/Pump01///m/$1/meta" "{\"$1.$1\":{\"unit\":\"$2\"}}"
}
unit operatingLevel "%"
unit flow "l/m"
unit power "W"
unit runHours "h"
unit filterState "%"
unit inflowTemperature "c"
unit bearingTemperature "c"

# The service runs as tedge too, so no privileges are needed to reload it.
pkill -HUP -x tedge-dot
echo "tedge-dot OPC-UA pump config installed"
