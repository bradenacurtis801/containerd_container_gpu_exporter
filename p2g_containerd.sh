#!/bin/bash -e

# Function to display help
Help() {
    echo -e "Usage: <p2g_containerd.sh> [options] <No options required>"
    echo -e ""
    echo -e "Output description:"
    echo -e "PID: PID that uses the GPU"
    echo -e "CONTAINER_NAME: Container name that uses the GPU"
    echo -e "GPU util: {GPU id} {PID} {SM utilization} {GPU Memory utilization}"
    echo -e "GPU usage: GPU usage of the memory"
}

# Function to get the immediate parent PID
get_parent_pid() {
    local pid=$1
    ps -o ppid= -p $pid | tr -d ' '
}

# Function to get immediate child PIDs
get_child_pids() {
    local parent_pid=$1
    ps --ppid $parent_pid -o pid=
}

# Function to get all child PIDs recursively
get_child_pids_all() {
    local parent_pid=$1
    local child_pids=$(ps --ppid $parent_pid -o pid=)
    
    for child_pid in $child_pids; do
        echo $child_pid
        get_child_pids $child_pid
    done
}

# Function to get all ancestor PIDs
get_ancestor_pids() {
    local pid=$1
    local ancestors=()
    while [ "$pid" -ne 1 ]; do
        pid=$(ps -o ppid= -p $pid)
        ancestors+=($pid)
    done
    echo "${ancestors[@]}"
}

# Function to detect PIDs using the GPU
detect_gpu_pids() {
    nvidia-smi | sed '1,/Processes:/d' | awk '{print $5}' | grep -v 'PID' | grep -v '|' | awk '!NF || !seen[$0]++'
}

# Function to get container info
get_container_info() {
    sudo crictl ps -a --quiet | xargs sudo crictl inspect --output json
}

# Function to get GPU utilization
get_gpu_utilization() {
    local pid=$1
    nvidia-smi pmon -c 1 | grep $pid | awk '{print $1, $2, $4, $5}'
}

# Function to get GPU usage
get_gpu_usage() {
    local pid=$1
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | grep $pid | awk '{print $3, $4}'
}

# Function to aggregate GPU usage for a given parent PID
aggregate_gpu_usage() {
    local parent_pid=$1
    local total_gpu_util=0
    local total_gpu_mem_util=0
    local count=0

    local child_pids=$(get_child_pids $parent_pid)
    for pid in $parent_pid $child_pids; do
        local gpu_util
        gpu_util=$(get_gpu_utilization $pid)
        gpu_usage=$(get_gpu_usage $pid)
        if [[ ! -z $gpu_util ]]; then
            local sm_util mem_util
            sm_util=$(echo $gpu_util | awk '{print $3}')
            mem_util=$(echo $gpu_util | awk '{print $4}')
            total_gpu_util=$((total_gpu_util + sm_util))
            total_gpu_mem_util=$((total_gpu_mem_util + mem_util))
            count=$((count + 1))
        fi
    done

    if [[ $count -gt 0 ]]; then
        local avg_gpu_util=$((total_gpu_util / count))
        local avg_gpu_mem_util=$((total_gpu_mem_util / count))
        echo "SM Utilization"
        echo "  percentage: $avg_gpu_util%"
        echo "  value: $total_gpu_util"
        echo "Memory Utilization: "
        echo "  percentage: $avg_gpu_mem_util%"
        echo "  value: $total_gpu_mem_util%"
    else
        echo "No GPU utilization found for PID $parent_pid"
    fi
}

# Function to get container details
get_container_details() {
    local sub_pid=$1
    echo "$container_info" | jq --arg sub_pid "$sub_pid" -c 'select(.info.pid == ($sub_pid | tonumber)) | {name: .info.config.metadata.name, image: .info.config.image.user_specified_image, labels: .info.config.labels}'
}

# Function to print container information
print_container_info() {
    local node_name=$1
    local pod_name=$2
    local namespace=$3
    local container_name=$4
    local image_name=$5
    local pid=$6
    local gpu_util=$7
    local gpu_usage=$8
    
    echo -e NODE_NAME: $node_name
    echo -e POD_NAME: $pod_name
    echo -e NAMESPACE: $namespace
    echo -e CONTAINER_NAME: $container_name
    echo -e IMAGE: $image_name
    echo -e PID: $pid
    echo -e GPU util: $gpu_util
    echo -e GPU usage: $gpu_usage
    echo -e "\n"
}

# Main script execution
main() {
    local verbose=0

    while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do
        case $1 in
            -v | --verbose )
                verbose=1
                ;;
            -h | --help )
                Help
                exit 0
                ;;
        esac
        shift
    done

    my_pids=$(detect_gpu_pids)
    [[ $verbose -eq 1 ]] && echo "Detected PIDs using the GPU: $my_pids"
    
    container_info=$(get_container_info)
    [[ $verbose -eq 1 ]] && echo "$container_info" > container_info.json
    
    node_name=$(hostname)
    
    declare -A pid_map

    for pid in $my_pids; do
        parent_pid=$(get_parent_pid $pid)
        pid_map[$pid]=1
        pid_map[$parent_pid]=1
    done

    matched_pids=()
    for pid in "${!pid_map[@]}"; do
        if echo "$container_info" | grep -q "$pid"; then
            matched_pids+=($pid)
        fi
    done

    unique_matched_pids=($(echo "${matched_pids[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    for pid in "${unique_matched_pids[@]}"; do
        p2g_util=$(get_gpu_utilization $pid)
        p2g_usage=$(get_gpu_usage $pid)
        
        container_details=$(get_container_details $pid)
        if [ ! -z "$container_details" ]; then
            container_name=$(echo "$container_details" | jq -r '.name')
            image_name=$(echo "$container_details" | jq -r '.image')
            labels=$(echo "$container_details" | jq -r '.labels')
            
            pod_name=$(echo "$labels" | jq -r '."io.kubernetes.pod.name"')
            namespace=$(echo "$labels" | jq -r '."io.kubernetes.pod.namespace"')
            container_name_label=$(echo "$labels" | jq -r '."io.kubernetes.container.name"')
            
            print_container_info "$node_name" "$pod_name" "$namespace" "$container_name_label" "$image_name" "$pid" "$p2g_util" "$p2g_usage"
        else
            [[ $verbose -eq 1 ]] && echo -e "No container found for PID: $pid\n"
        fi
    done
}

# Run the main function
main "$@"
