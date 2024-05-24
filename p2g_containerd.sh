#!/bin/bash -e

Help() {
    echo -e "Usage: <p2g_containerd.sh> [options] <No options required>"
    echo -e ""
    echo -e "Output description:"
    echo -e "PID: PID that uses the GPU"
    echo -e "CONTAINER_NAME: Container name that uses the GPU"
    echo -e "GPU util: {GPU id} {PID} {SM utilization} {GPU Memory utilization}"
    echo -e "GPU usage: GPU usage of the memory"
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    Help
    exit 0
fi

my_pids=$(nvidia-smi | sed '1,/Processes:/d' | awk '{print $5}' | grep -v 'PID' | grep -v '|' | awk '!NF || !seen[$0]++')

echo "Detected PIDs using the GPU: $my_pids"

# Use crictl to find the container name by PID
container_info=$(sudo crictl ps -a --quiet | xargs sudo crictl inspect --output json)

# Output the JSON for analysis
echo "$container_info" > container_info.json

for pid in $my_pids; do
    p2g_util=$(nvidia-smi pmon -c 1 | grep $pid | awk '{print $1, $2, $4, $5}')
    p2g_usage=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | grep $pid | awk '{print $3, $4}')

    # Debug output
    echo "Inspecting PID: $pid"
    echo "GPU util: $p2g_util"
    echo "GPU usage: $p2g_usage"

    # Parse container info to find the matching PID and extract relevant fields
    container_details=$(echo "$container_info" | jq --arg pid "$pid" 'select(.info.pid == ($pid | tonumber)) | {name: .info.config.metadata.name, image: .info.config.image.user_specified_image}')

    if [ ! -z "$container_details" ]; then
        container_name=$(echo "$container_details" | jq -r '.name')
        image_name=$(echo "$container_details" | jq -r '.image')
        
        echo -e PID: $pid
        echo -e CONTAINER_NAME: $container_name
        echo -e IMAGE: $image_name
        echo -e GPU util: $p2g_util
        echo -e GPU usage: $p2g_usage
        echo -e "\n"
    else
        echo -e "No container found for PID: $pid\n"
    fi
done

