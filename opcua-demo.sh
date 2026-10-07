#!/bin/sh

# Parse flags and positional args
DEBUG=0
CONNECTOR=gateway
POS_ARGS=""
EXPECT_CONNECTOR=0
for arg in "$@"; do
    if [ "$EXPECT_CONNECTOR" = "1" ]; then
        CONNECTOR="$arg"
        EXPECT_CONNECTOR=0
        continue
    fi
    case "$arg" in
        --debug|-v) DEBUG=1 ;;
        --connector) EXPECT_CONNECTOR=1 ;;
        --connector=*) CONNECTOR="${arg#--connector=}" ;;
        *) POS_ARGS="$POS_ARGS $arg" ;;
    esac
done
eval set -- $POS_ARGS

COMMAND="${1}"
DEVICE_NAME="${2:-ThinEdge-cooling-line3}"

# Where the compose files, protocol, dashboard and tedge-dot config are downloaded from.
# Override to try a branch, e.g.
# BLUEPRINT_BASE_URL=https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/<branch>
BLUEPRINT_BASE_URL="${BLUEPRINT_BASE_URL:-https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main}"

# tedge-dot: the thin-edge.io OT connector (https://github.com/thin-edge/tedge-dot), installed
# from the thin-edge.io community repository with the apt software type.
TEDGE_DOT_PACKAGE=tedge-dot-rs
TEDGE_DOT_VERSION="${TEDGE_DOT_VERSION:-0.0.13}"
# Configuration types the tedge-dot variant pushes; each is stored in the configuration repository
# as <type>-<device-name>.
TEDGE_DOT_CONFIG_TYPES="tedge-configuration-plugin tedge-dot-opcua-pump"
# Where the connector config lives on the device: tedge-dot reads every *.toml in this directory
# and reloads by itself when one changes.
TEDGE_DOT_CONFIG_PATH=/etc/tedge/plugins/ot/opcua-pump.toml

if [ "$DEBUG" = "1" ]; then
    STDERR=/dev/stderr
else
    STDERR=/dev/null
fi

usage() {
    echo "Usage: $0 <start|stop> [device-name] [--connector gateway|tedge-dot] [--debug]"
    echo ""
    echo "  start [device-name]  Set up and start the OPC-UA demo (default: ThinEdge-cooling-line3)"
    echo "  stop  [device-name]  Tear down the OPC-UA demo and remove all artifacts"
    echo ""
    echo "Options:"
    echo "  --connector <name>   What reads the OPC-UA server (start only):"
    echo "                         gateway    Cumulocity OPC-UA Device Gateway container (default)"
    echo "                         tedge-dot  thin-edge.io OT connector (tedge-dot), installed as a package"
    echo "  --debug, -v          Show error output from c8y commands (hidden by default)"
    exit 1
}

###############################################################################
# START
###############################################################################
start_demo() {
    case "$CONNECTOR" in
        gateway|tedge-dot) ;;
        *) echo "Error: unknown connector '$CONNECTOR' (expected gateway or tedge-dot)"; usage ;;
    esac
    echo "Starting OPC-UA demo for device: $DEVICE_NAME (connector: $CONNECTOR)"

    # Check if device already exists
    result=$(c8y inventory find --name "$DEVICE_NAME" --type thin-edge.io 2>$STDERR)
    if [ -n "$result" ]; then
        echo "Error: Device '$DEVICE_NAME' already exists. Please choose a different name."
        exit 1
    fi

    # Start Demo Container
    c8y tedge demo start "$DEVICE_NAME" --features nopki
    # The device's identity can take a few seconds to appear after the bootstrap.
    tries=0
    until [ -n "$(c8y identity get --name "$DEVICE_NAME" 2>$STDERR | jq -r '.managedObject.id // empty')" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 12 ]; then
            echo "Error: device '$DEVICE_NAME' was not registered in Cumulocity; check the 'c8y tedge demo start' output above."
            exit 1
        fi
        sleep 5
    done

    # Create Software opcua-server only if it doesn't exist
    if [ -z "$(c8y software get --id opcua-server-$DEVICE_NAME 2>$STDERR)" ]; then
        echo "Creating software opcua-server-$DEVICE_NAME..."
        c8y software create -f --name "opcua-server-$DEVICE_NAME" \
        --softwareType container-group \
        --description "OPC-UA Demo Server to simulate an industrial pump" | \
        c8y software versions create -f --version 0.0.1 \
        --url ${BLUEPRINT_BASE_URL}/software/docker-compose-opcua-demo-server.yml
    else
        echo "Software opcua-server-$DEVICE_NAME already exists, skipping creation."
    fi

    if [ "$CONNECTOR" = "tedge-dot" ]; then
        sleep 2
        c8y software versions install -f \
        --device "$DEVICE_NAME" \
        --software "opcua-server-$DEVICE_NAME" \
        --version 0.0.1
        start_tedge_dot
        return
    fi

    # Create Software opcua-device-gateway only if it doesn't exist
    if [ -z "$(c8y software get --id opcua-device-gateway-$DEVICE_NAME 2>$STDERR)" ]; then
        echo "Creating software opcua-device-gateway-$DEVICE_NAME..."
        c8y software create -f \
        --name "opcua-device-gateway-$DEVICE_NAME" \
        --softwareType container-group \
        --description "Cumulocity OPC-UA Device Gateway" | \
        c8y software versions create -f \
        --version demo-container \
        --url ${BLUEPRINT_BASE_URL}/software/docker-compose-opcua-device-gateway-demo-container.yml
    else
        echo "Software opcua-device-gateway-$DEVICE_NAME already exists, skipping creation."
    fi

    sleep 2

    # Install software on device
    c8y software versions install -f \
    --device "$DEVICE_NAME" \
    --software "opcua-server-$DEVICE_NAME" \
    --version 0.0.1

    c8y software versions install -f \
    --device "$DEVICE_NAME" \
    --software "opcua-device-gateway-$DEVICE_NAME" \
    --version demo-container

    # Wait for OPCUAGateway to appear as child of root device
    echo "Waiting for OPCUAGateway to be created..."
    while true; do
        gateway=$(c8y inventory find --name OPCUAGateway --owner "device_$DEVICE_NAME" 2>$STDERR | jq -r .id)
        if [ -n "$gateway" ]; then
            echo "OPCUAGateway found (ID: $gateway), creating OPC-UA server managed object..."
            OPCSERVER_DEVICE_ID=$(wget -q ${BLUEPRINT_BASE_URL}/opcserver.json -O - \
                | sed "s/###OWNER###/device_$DEVICE_NAME/g" \
                | c8y inventory children create -f --id "$gateway" --childType device --global --template input.value \
                | jq -r .id)
            echo "OPCSERVER created with ID: $OPCSERVER_DEVICE_ID"
            sleep 2
            break
        fi
        echo "OPCUAGateway not found yet, waiting 5 seconds..."
        sleep 5
    done

    # Create device protocol only if it doesn't exist
    pump_result=$(c8y inventory find --name "Pump01-$DEVICE_NAME" --type c8y_OpcuaDeviceType 2>$STDERR)
    if [ -z "$pump_result" ]; then
        echo "Creating device protocol Pump01-$DEVICE_NAME..."
        wget -q ${BLUEPRINT_BASE_URL}/device-protocols/opcua-pump-device-protocol.json -O - \
        | sed "s/###OPCSERVER_DEVICE_ID###/$OPCSERVER_DEVICE_ID/g" \
        | sed "s/###DEVICE_NAME###/$DEVICE_NAME/g" \
        | c8y inventory create -f --name "Pump01-$DEVICE_NAME" --type c8y_OpcuaDeviceType --template input.value
    else
        echo "Device protocol Pump01-$DEVICE_NAME already exists, skipping creation."
    fi

    # Wait for the Pump01 OPC-UA device to be created and deploy the dashboard
    echo "Waiting for Pump01 device to be created..."
    deviceId=""
    while [ -z "$deviceId" ]; do
        deviceId=$(c8y inventory list \
        --type c8y_OpcuaDevice \
        --owner "device_$DEVICE_NAME" 2>$STDERR | \
        jq -r .id | head -1)

        if [ -z "$deviceId" ] || [ "$deviceId" = "null" ]; then
            echo "Pump01 device not found yet, waiting 5 seconds..."
            deviceId=""
            sleep 5
        else
            echo "Pump01 device found with ID: $deviceId"
            wget -q ${BLUEPRINT_BASE_URL}/dashboard/dashboardPumpMO.json -O - \
            | sed "s/###DASHBOARD_DEVICE_ID###/${deviceId}/g" \
            | sed "s/###DEVICE_NAME###/${DEVICE_NAME}/g" \
            | c8y inventory children create -f --id "$deviceId" --global --childType addition --template input.value
        fi
    done

    echo "Done. OPC-UA demo for '$DEVICE_NAME' is up and running."
}

###############################################################################
# START, tedge-dot connector instead of the OPC-UA Device Gateway
###############################################################################
# Run "$@" until it prints something, at most 5 times: a call that prints nothing failed, most
# often a dropped connection to the tenant. Prints the output; fails when every try did.
retry() {
    tries=0
    while :; do
        out=$("$@")
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 5 ] && return 1
        echo "  no answer from the tenant, asking again..." >&2
        sleep 5
    done
}

lookup_device_id() {
    c8y identity get --name "$DEVICE_NAME" 2>$STDERR | jq -r '.managedObject.id // empty'
}

# The managed object id of the demo device; stops when the tenant does not answer.
device_id() {
    if ! retry lookup_device_id; then
        echo "Error: cannot look up device '$DEVICE_NAME' in Cumulocity." >&2
        exit 1
    fi
}

create_config() {
    c8y configuration create -f --name "$3" --configurationType "$1" \
        --description "tedge-dot OPC-UA demo ($DEVICE_NAME)" --file "$2" 2>$STDERR | jq -r '.id // empty'
}

send_config_op() {
    c8y configuration send -f --device "$DEVICE_NAME" --configuration "$1" 2>$STDERR | jq -r '.id // empty'
}

# Upload file $2 as configuration type $1 to the configuration repository and send it to the
# device, waiting for the operation.
send_config() {
    name="$1-$DEVICE_NAME"
    c8y configuration list --name "$name" 2>$STDERR | jq -r '.id // empty' | while read -r old; do
        c8y configuration delete -f --id "$old" >/dev/null 2>$STDERR
    done
    if ! cfg=$(retry create_config "$1" "$2" "$name"); then
        echo "Error: cannot upload configuration $name"
        exit 1
    fi
    echo "Sending configuration $1 (waiting for the operation)..."
    op=$(retry send_config_op "$cfg")
    wait_operation "Configuration $1" "$op" 5m
}

upload_config_op() {
    c8y operations create -f --device "$1" --description "Get configuration $2" \
        --data "{\"c8y_UploadConfigFile\":{\"type\":\"$2\"}}" 2>$STDERR | jq -r '.id // empty'
}

uploaded_event() {
    c8y events list --device "$1" --type "$2" --pageSize 20 2>$STDERR \
        | jq -r --arg op "$3" 'select(.c8y_IsBinary.name | endswith("-" + $op)) | .id' | head -n 1
}

# Fetch the device's configuration $1 into file $2: the device uploads it (c8y_UploadConfigFile)
# as a binary attached to an event, named after the operation.
fetch_config() {
    dev=$(device_id) || exit 1
    echo "Fetching configuration $1 from the device (waiting for the operation)..."
    op=$(retry upload_config_op "$dev" "$1")
    wait_operation "Fetching $1" "$op" 2m
    tries=0
    until event=$(retry uploaded_event "$dev" "$1" "$op") \
        && c8y events downloadBinary --id "$event" --outputFileRaw "$2" >/dev/null 2>$STDERR \
        && [ -s "$2" ]; do
        tries=$((tries + 1))
        if [ "$tries" -ge 5 ]; then
            echo "Error: cannot download configuration $1 from the device"
            exit 1
        fi
        sleep 5
    done
}

# Wait until the device lists configuration type $1 (after its plugin list was updated). A failed
# lookup counts as "not yet".
wait_config_type() {
    # The device needs a few seconds to apply the list and report its types: checking at once
    # only adds calls to the tenant.
    sleep 10
    dev=$(device_id) || exit 1
    tries=0
    until c8y inventory get --id "$dev" 2>$STDERR \
        | jq -e --arg t "$1" '.c8y_SupportedConfigurations | index($t)' >/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 24 ]; then
            echo "Error: the device does not list configuration type $1."
            exit 1
        fi
        sleep 5
    done
}

# Wait for operation $2 and stop unless it ended SUCCESSFUL. A wait that returns nothing (a
# dropped connection to the tenant) is retried: the operation itself goes on regardless.
wait_operation() {
    if [ -z "$2" ]; then
        echo "Error: $1: the operation could not be created."
        exit 1
    fi
    attempt=0
    while :; do
        result=$(c8y operations wait --id "$2" --duration "$3" --status SUCCESSFUL --status FAILED 2>$STDERR)
        status=$(printf '%s\n' "$result" | jq -r '.status // empty' 2>/dev/null)
        [ -n "$status" ] && break
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 5 ]; then
            echo "Error: $1: no result for operation $2 (check it in Device Management)."
            exit 1
        fi
        echo "  $1: no answer from the tenant, asking again..."
        sleep 5
    done
    if [ "$status" = "SUCCESSFUL" ]; then
        echo "  $1: done"
        return
    fi
    echo "Error: $1 did not succeed (operation $2, status $status): $(printf '%s\n' "$result" | jq -r '.failureReason // empty' 2>/dev/null)"
    exit 1
}

start_tedge_dot() {
    # The apt package from the community repository: the software name must be the package
    # name, so this entry is shared between demos and not removed by `stop`.
    if [ -z "$(c8y software get --id "$TEDGE_DOT_PACKAGE" 2>$STDERR)" ]; then
        echo "Creating software $TEDGE_DOT_PACKAGE..."
        c8y software create -f --name "$TEDGE_DOT_PACKAGE" \
        --softwareType apt \
        --description "thin-edge.io OT connector (Modbus, OPC UA, CAN, SNMP, ...)" >/dev/null
    fi
    if [ -z "$(c8y software versions list --software "$TEDGE_DOT_PACKAGE" 2>$STDERR | jq -r "select(.c8y_Software.version == \"$TEDGE_DOT_VERSION\") | .id")" ]; then
        c8y software versions create -f --software "$TEDGE_DOT_PACKAGE" --version "$TEDGE_DOT_VERSION" >/dev/null
    fi

    echo "Installing $TEDGE_DOT_PACKAGE $TEDGE_DOT_VERSION (waiting for the operation)..."
    op=$(c8y software versions install -f \
    --device "$DEVICE_NAME" \
    --software "$TEDGE_DOT_PACKAGE" \
    --version "$TEDGE_DOT_VERSION" 2>$STDERR | jq -r '.id // empty')
    wait_operation "Installing $TEDGE_DOT_PACKAGE" "$op" 10m

    # The connector config reaches the device through configuration management, so the device
    # fetches it from Cumulocity:
    #   1. the device's list of configuration types (tedge-configuration-plugin) is fetched, the
    #      connector config is added to it, and the list is sent back;
    #   2. the connector config itself is sent. tedge-dot notices the new file and loads it.
    dir=$(mktemp -d)
    fetch_config tedge-configuration-plugin "$dir/tedge-configuration-plugin.toml"
    if grep -q "^type *= *[\"']tedge-dot-opcua-pump[\"']" "$dir/tedge-configuration-plugin.toml"; then
        echo "The device already manages tedge-dot-opcua-pump."
    else
        cat >>"$dir/tedge-configuration-plugin.toml" <<EOF

# tedge-dot OPC-UA demo: the connector configuration (added by opcua-demo.sh)
[[files]]
path = '$TEDGE_DOT_CONFIG_PATH'
type = 'tedge-dot-opcua-pump'
user = 'tedge'
group = 'tedge'
mode = 0o644
EOF
        send_config tedge-configuration-plugin "$dir/tedge-configuration-plugin.toml"
    fi
    wait_config_type tedge-dot-opcua-pump
    if ! wget -q "${BLUEPRINT_BASE_URL}/tedge-dot/opcua-pump.toml" -O "$dir/opcua-pump.toml"; then
        echo "Error: cannot download ${BLUEPRINT_BASE_URL}/tedge-dot/opcua-pump.toml"
        exit 1
    fi
    send_config tedge-dot-opcua-pump "$dir/opcua-pump.toml"
    rm -rf "$dir"

    # Pump01 is registered by the connector's flows as a child device of the main device.
    echo "Waiting for Pump01 device to be created..."
    deviceId=""
    tries=0
    while [ -z "$deviceId" ]; do
        deviceId=$(c8y identity get --name "$DEVICE_NAME:device:Pump01" --type c8y_Serial 2>$STDERR | jq -r '.managedObject.id // empty')
        if [ -z "$deviceId" ]; then
            tries=$((tries + 1))
            if [ "$tries" -gt 60 ]; then
                echo "Error: Pump01 did not appear within 5 minutes; check 'journalctl -u tedge-dot' on the device."
                exit 1
            fi
            echo "Pump01 device not found yet, waiting 5 seconds..."
            sleep 5
        fi
    done
    echo "Pump01 device found with ID: $deviceId"
    wget -q ${BLUEPRINT_BASE_URL}/dashboard/dashboardPumpMO.json -O - \
    | sed "s/###DASHBOARD_DEVICE_ID###/${deviceId}/g" \
    | sed "s/###DEVICE_NAME###/${DEVICE_NAME}/g" \
    | c8y inventory children create -f --id "$deviceId" --global --childType addition --template input.value >/dev/null
    echo "Pump Dashboard - $DEVICE_NAME created."

    echo "Done. OPC-UA demo for '$DEVICE_NAME' is up and running, read by tedge-dot."
}

###############################################################################
# STOP
###############################################################################
stop_demo() {
    echo "Removing OPC-UA demo for device: $DEVICE_NAME"

    # Step 1: Find root device by name
    echo "Looking up root device $DEVICE_NAME..."
    root_device=$(c8y inventory find --name "$DEVICE_NAME" --type thin-edge.io 2>$STDERR | jq -r .id | head -1)
    if [ -z "$root_device" ] || [ "$root_device" = "null" ]; then
        echo "Error: Root device '$DEVICE_NAME' not found."
        exit 1
    fi
    echo "Root device found with ID: $root_device"

    # Step 2: Find OPCUAGateway as child device of root
    echo "Looking up OPCUAGateway (child of root device)..."
    gateway=$(c8y inventory children list --id "$root_device" --childType device 2>$STDERR | \
        jq -r 'select(.name == "OPCUAGateway") | .id' | head -1)

    if [ -n "$gateway" ] && [ "$gateway" != "null" ]; then
        echo "OPCUAGateway found with ID: $gateway"

        # Step 3: Find opcserver as child device of OPCUAGateway
        echo "Looking up OPC-UA server (child of OPCUAGateway)..."
        opcserver=$(c8y inventory children list --id "$gateway" --childType device 2>$STDERR | \
            jq -r .id | head -1)

        if [ -n "$opcserver" ] && [ "$opcserver" != "null" ]; then
            # Step 4: Find and delete Pump device as child of opcserver
            echo "Looking up Pump device (child of OPC-UA server)..."
            pump_device=$(c8y inventory children list --id "$opcserver" --childType device 2>$STDERR | \
                jq -r .id | head -1)

            if [ -n "$pump_device" ] && [ "$pump_device" != "null" ]; then
                echo "Deleting Pump device (ID: $pump_device)..."
                c8y inventory delete -f --id "$pump_device"
                echo "Pump device deleted."
            else
                echo "No Pump device found under OPC-UA server, skipping."
            fi

            # Step 5: Delete OPC-UA server via opcua-mgmt-service
            echo "Deleting OPC-UA server (ID: $opcserver) via opcua-mgmt-service..."
            c8y api DELETE -f "/service/opcua-mgmt-service/server/${gateway}/${opcserver}"
            echo "OPC-UA server deleted."
        else
            echo "No OPC-UA server child device found under OPCUAGateway, skipping."
        fi
    else
        echo "OPCUAGateway not found as child of root device, skipping OPC-UA server deletion."
    fi

    # tedge-dot variant: Pump01 is a child device registered by the connector
    pump_tedge_dot=$(c8y identity get --name "$DEVICE_NAME:device:Pump01" --type c8y_Serial 2>$STDERR | jq -r '.managedObject.id // empty')
    if [ -n "$pump_tedge_dot" ]; then
        echo "Deleting tedge-dot Pump01 device (ID: $pump_tedge_dot)..."
        c8y inventory delete -f --id "$pump_tedge_dot"
    fi

    # tedge-dot variant: its entries in the configuration repository
    for type in $TEDGE_DOT_CONFIG_TYPES; do
        c8y configuration list --name "$type-$DEVICE_NAME" 2>$STDERR | jq -r '.id // empty' | while read -r cfg; do
            echo "Deleting configuration $type-$DEVICE_NAME..."
            c8y configuration delete -f --id "$cfg" >/dev/null
        done
    done

    # Delete device protocol Pump01-$DEVICE_NAME
    echo "Deleting device protocol Pump01-$DEVICE_NAME..."
    protocol_id=$(c8y inventory find --name "Pump01-$DEVICE_NAME" --type c8y_OpcuaDeviceType 2>$STDERR | jq -r .id)
    if [ -n "$protocol_id" ] && [ "$protocol_id" != "null" ]; then
        c8y inventory delete -f --id "$protocol_id"
        echo "Device protocol deleted (ID: $protocol_id)."
    else
        echo "Device protocol Pump01-$DEVICE_NAME not found, skipping."
    fi

    # Delete software opcua-server-$DEVICE_NAME
    echo "Deleting software opcua-server-$DEVICE_NAME..."
    c8y software delete -f --id "opcua-server-$DEVICE_NAME" 2>$STDERR && \
        echo "Software opcua-server-$DEVICE_NAME deleted." || \
        echo "Software opcua-server-$DEVICE_NAME not found, skipping."

    # Delete software opcua-device-gateway-$DEVICE_NAME
    echo "Deleting software opcua-device-gateway-$DEVICE_NAME..."
    c8y software delete -f --id "opcua-device-gateway-$DEVICE_NAME" 2>$STDERR && \
        echo "Software opcua-device-gateway-$DEVICE_NAME deleted." || \
        echo "Software opcua-device-gateway-$DEVICE_NAME not found, skipping."

    # Delete the top level device and demo container
    echo "Deleting demo for $DEVICE_NAME..."
    c8y tedge demo delete  "$DEVICE_NAME"

    echo "Done. OPC-UA demo for '$DEVICE_NAME' has been removed."
}

###############################################################################
# MAIN
###############################################################################
case "$COMMAND" in
    start) start_demo ;;
    stop)  stop_demo ;;
    *)     usage ;;
esac
