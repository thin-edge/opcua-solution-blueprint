#!/bin/sh

COMMAND="${1}"
DEVICE_NAME="${2:-ThinEdge-cooling-line3}"

usage() {
    echo "Usage: $0 <start|stop> [device-name]"
    echo ""
    echo "  start [device-name]  Set up and start the OPC-UA demo (default: ThinEdge-cooling-line3)"
    echo "  stop  [device-name]  Tear down the OPC-UA demo and remove all artifacts"
    exit 1
}

###############################################################################
# START
###############################################################################
start_demo() {
    echo "Starting OPC-UA demo for device: $DEVICE_NAME"

    # Check if device already exists
    result=$(c8y inventory find --name "$DEVICE_NAME" --type thin-edge.io 2>/dev/null)
    if [ -n "$result" ]; then
        echo "Error: Device '$DEVICE_NAME' already exists. Please choose a different name."
        exit 1
    fi

    # Start Demo Container
    c8y tedge demo start "$DEVICE_NAME" --features nopki

    # Create Software opcua-server only if it doesn't exist
    if [ -z "$(c8y software find --name opcua-server-$DEVICE_NAME 2>/dev/null)" ]; then
        echo "Creating software opcua-server-$DEVICE_NAME..."
        c8y software create -f --name "opcua-server-$DEVICE_NAME" \
        --softwareType container-group \
        --description "OPC-UA Demo Server to simulate an industrial pump" | \
        c8y software versions create -f --version 0.0.1 \
        --url https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/software/docker-compose-opcua-demo-server.yml
    else
        echo "Software opcua-server-$DEVICE_NAME already exists, skipping creation."
    fi

    # Create Software opcua-device-gateway only if it doesn't exist
    if [ -z "$(c8y software find --name opcua-device-gateway-$DEVICE_NAME 2>/dev/null)" ]; then
        echo "Creating software opcua-device-gateway-$DEVICE_NAME..."
        c8y software create -f \
        --name "opcua-device-gateway-$DEVICE_NAME" \
        --softwareType container-group \
        --description "Cumulocity OPC-UA Device Gateway" | \
        c8y software versions create -f \
        --version demo-container \
        --url https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/software/docker-compose-opcua-device-gateway-demo-container.yml
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
        gateway=$(c8y inventory find --name OPCUAGateway --owner "device_$DEVICE_NAME" 2>/dev/null | jq -r .id)
        if [ -n "$gateway" ]; then
            echo "OPCUAGateway found (ID: $gateway), creating OPC-UA server managed object..."
            OPCSERVER_DEVICE_ID=$(wget -q https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/opcserver.json -O - \
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
    pump_result=$(c8y inventory find --name "Pump01-$DEVICE_NAME" --type c8y_OpcuaDeviceType 2>/dev/null)
    if [ -z "$pump_result" ]; then
        echo "Creating device protocol Pump01-$DEVICE_NAME..."
        wget -q https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/device-protocols/opcua-pump-device-protocol.json -O - \
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
        --owner "device_$DEVICE_NAME" 2>/dev/null | \
        jq -r .id | head -1)

        if [ -z "$deviceId" ] || [ "$deviceId" = "null" ]; then
            echo "Pump01 device not found yet, waiting 5 seconds..."
            deviceId=""
            sleep 5
        else
            echo "Pump01 device found with ID: $deviceId"
            wget -q https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/dashboard/dashboardPumpMO.json -O - \
            | sed "s/###DASHBOARD_DEVICE_ID###/${deviceId}/g" \
            | sed "s/###DEVICE_NAME###/${DEVICE_NAME}/g" \
            | c8y inventory children create -f --id "$deviceId" --global --childType addition --template input.value
        fi
    done

    echo "Done. OPC-UA demo for '$DEVICE_NAME' is up and running."
}

###############################################################################
# STOP
###############################################################################
stop_demo() {
    echo "Removing OPC-UA demo for device: $DEVICE_NAME"

    # Step 1: Find root device by name
    echo "Looking up root device $DEVICE_NAME..."
    root_device=$(c8y inventory find --name "$DEVICE_NAME" --type thin-edge.io 2>/dev/null | jq -r .id | head -1)
    if [ -z "$root_device" ] || [ "$root_device" = "null" ]; then
        echo "Error: Root device '$DEVICE_NAME' not found."
        exit 1
    fi
    echo "Root device found with ID: $root_device"

    # Step 2: Find OPCUAGateway as child device of root
    echo "Looking up OPCUAGateway (child of root device)..."
    gateway=$(c8y inventory children list --id "$root_device" --childType device 2>/dev/null | \
        jq -r 'select(.name == "OPCUAGateway") | .id' | head -1)

    if [ -n "$gateway" ] && [ "$gateway" != "null" ]; then
        echo "OPCUAGateway found with ID: $gateway"

        # Step 3: Find opcserver as child device of OPCUAGateway
        echo "Looking up OPC-UA server (child of OPCUAGateway)..."
        opcserver=$(c8y inventory children list --id "$gateway" --childType device 2>/dev/null | \
            jq -r .id | head -1)

        if [ -n "$opcserver" ] && [ "$opcserver" != "null" ]; then
            echo "Deleting OPC-UA server (ID: $opcserver) via opcua-mgmt-service..."
            c8y api DELETE -f "/service/opcua-mgmt-service/server/${gateway}/${opcserver}"
            echo "OPC-UA server deleted."
        else
            echo "No OPC-UA server child device found under OPCUAGateway, skipping."
        fi
    else
        echo "OPCUAGateway not found as child of root device, skipping OPC-UA server deletion."
    fi

    # Delete device protocol Pump01-$DEVICE_NAME
    echo "Deleting device protocol Pump01-$DEVICE_NAME..."
    protocol_id=$(c8y inventory find --name "Pump01-$DEVICE_NAME" --type c8y_OpcuaDeviceType 2>/dev/null | jq -r .id)
    if [ -n "$protocol_id" ] && [ "$protocol_id" != "null" ]; then
        c8y inventory delete -f --id "$protocol_id"
        echo "Device protocol deleted (ID: $protocol_id)."
    else
        echo "Device protocol Pump01-$DEVICE_NAME not found, skipping."
    fi

    # Delete software opcua-server-$DEVICE_NAME
    echo "Deleting software opcua-server-$DEVICE_NAME..."
    c8y software delete -f --id "opcua-server-$DEVICE_NAME" 2>/dev/null && \
        echo "Software opcua-server-$DEVICE_NAME deleted." || \
        echo "Software opcua-server-$DEVICE_NAME not found, skipping."

    # Delete software opcua-device-gateway-$DEVICE_NAME
    echo "Deleting software opcua-device-gateway-$DEVICE_NAME..."
    c8y software delete -f --id "opcua-device-gateway-$DEVICE_NAME" 2>/dev/null && \
        echo "Software opcua-device-gateway-$DEVICE_NAME deleted." || \
        echo "Software opcua-device-gateway-$DEVICE_NAME not found, skipping."

    # Delete the top level device and demo container
    echo "Deleting demo for $DEVICE_NAME..."
    c8y tedge demo delete -f "$DEVICE_NAME"

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
