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
TEDGE_DOT_VERSION="${TEDGE_DOT_VERSION:-0.0.11}"

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
    if [ -z "$(c8y identity get --name "$DEVICE_NAME" 2>$STDERR | jq -r '.managedObject.id // empty')" ]; then
        echo "Error: device '$DEVICE_NAME' was not registered in Cumulocity; check the 'c8y tedge demo start' output above."
        exit 1
    fi

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

    # The connector config and the measurement units, installed on the device by
    # tedge-dot/setup-opcua-pump.sh (runs as tedge, like the service; no root needed).
    setup_url="${BLUEPRINT_BASE_URL}/tedge-dot/setup-opcua-pump.sh"
    echo "Deploying the tedge-dot OPC-UA config (waiting for the operation)..."
    op=$(c8y operations create -f \
    --device "$DEVICE_NAME" \
    --description "Deploy tedge-dot OPC-UA pump config" \
    --template "{c8y_Command: {text: '(curl -fsSL $setup_url || wget -qO- $setup_url) | sh -s -- ${BLUEPRINT_BASE_URL}'}}" 2>$STDERR | jq -r '.id // empty')
    wait_operation "Deploying the tedge-dot config" "$op" 5m

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
