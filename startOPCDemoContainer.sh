#!/bin/sh

# Set device name from command line argument or use default
DEVICE_NAME="${1:-ThinEdge-cooling-line3}"

# Check if device already exists
result=$(c8y inventory find --name $DEVICE_NAME --type thin-edge.io 2>/dev/null)
if [ -n "$result" ]; then
    echo "Error: Device '$DEVICE_NAME' already exists. Please choose a different name."
    exit 1
fi

# Start Demo Container
c8y tedge demo start $DEVICE_NAME

# Create Software opcserver only if it doesn't exist
if [ -z "$(c8y software find --name opcua-server 2>/dev/null)" ]; then
    echo "Creating software opcua-server..."
    c8y software create -f --name opcua-server \
    --softwareType container-group \
    --description "OPC-UA Demo Server to simulate an industrial pump" | \
    c8y software versions create -f --version 0.0.1 \
    --url https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/software/docker-compose-opcua-demo-server.yml
else
    echo "Software opcua-server already exists, skipping creation."
fi

# Deploy Software opc-ua gateway only if it doesn't exist
if [ -z "$(c8y software find --name opcua-device-gateway 2>/dev/null)" ]; then
    echo "Creating software opcua-device-gateway..."
    c8y software create -f \
    --name opcua-device-gateway \
    --softwareType container-group \
    --description "Cumulocity OPC-UA Device Gateway" | \
    c8y software versions create -f \
    --version demo-container \
    --url https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/software/docker-compose-opcua-device-gateway-demo-container.yml
else
    echo "Software opcua-device-gateway already exists, skipping creation."
fi

sleep 2
# Install software on device
c8y software versions install -f \
--device $DEVICE_NAME \
--software opcua-server \
--version 0.0.1

c8y software versions install -f \
--device $DEVICE_NAME \
--software opcua-device-gateway \
--version demo-container

# Install device protocol only if it doesn't exist
pump_result=$(c8y inventory find --name "Pump01" --type c8y_OpcuaDeviceType 2>/dev/null)
if [ -z "$pump_result" ]; then
    echo "Creating device type Pump01..."
    wget -q https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/device-protocols/opcua-pump-device-protocol.json -O - | c8y inventory create -f --name "Pump01" --type c8y_OpcuaDeviceType --template input.value
else
    echo "Device type Pump01 already exists, skipping creation."
fi

# Wait for OPCUAGateway to exist before creating child device
echo "Waiting for OPCUAGateway to be created..."
while true; do
    gateway=$(c8y inventory find --name OPCUAGateway --owner device_$DEVICE_NAME 2>/dev/null |  jq -r .id)
    if [ -n "$gateway" ]; then
        echo "OPCUAGateway found, creating child device..."
        wget -q https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/opcserver.json -O -  | sed "s/###OWNER###/device_$DEVICE_NAME/g" | c8y inventory children create -f --id "$gateway"  --childType device --global --template input.value
        break
    fi
    echo "OPCUAGateway not found yet, waiting 5 seconds..."
    sleep 5
done

# Wait for Pump01 device to be created
echo "Waiting for Pump01 device to be created..."
deviceId=""
while [ -z "$deviceId" ]; do
    deviceId=$(c8y inventory list \
    --type c8y_OpcuaDevice \
    --owner device_$DEVICE_NAME 2>/dev/null | \
    jq -r .id)
    
    if [ -z "$deviceId" ] || [ "$deviceId" = "null" ]; then
        echo "Pump01 device not found yet, waiting 5 seconds..."
        deviceId=""
        sleep 5
    else
        echo "Pump01 device found with ID: $deviceId"
        wget -q https://raw.githubusercontent.com/thin-edge/opcua-solution-blueprint/refs/heads/main/dashboard/dashboardPumpMO.json -O - |\
        sed "s/###DASHBOARD_DEVICE_ID###/${deviceId}/g" | \
        c8y inventory children create -f --id $deviceId --global --childType addition --template input.value
    fi
done

# Import the dashboard and replace the placeholder ###DASHBOARD_DEVICE_ID### with the actual device id of Pump01
