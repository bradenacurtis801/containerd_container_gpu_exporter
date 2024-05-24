#!/bin/bash -e

Help() {
    echo -e "Usage: <p2g.bash> [options] <No options required>"
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

for pid in $my_pids; do
    p2g_util=$(nvidia-smi pmon -c 1 | grep $pid | awk '{print $1, $2, $4, $5}')
    p2g_usage=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | grep $pid | awk '{print $3, $4}')

    # Use crictl to find the container name by PID
    container_info=$(sudo crictl ps --quiet | xargs sudo crictl inspect | grep -A 10 "\"pid\": $pid" | grep -E '\"name\"|\"pid\"')
    container_name=$(echo "$container_info" | grep "\"name\"" | awk -F '"' '{print $4}')
    
    if [ ! -z "$container_name" ]; then
        echo -e PID: $pid
        echo -e CONTAINER_NAME: $container_name
        echo -e GPU util: $p2g_util
        echo -e GPU usage: $p2g_usage
        echo -e "\n"
    else
        echo -e "\n"
    fi
done
