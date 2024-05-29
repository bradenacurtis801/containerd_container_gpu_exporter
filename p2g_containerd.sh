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

# Function to get all child PIDs recursively
get_child_pids() {
    local parent_pid=$1
    local child_pids=$(ps --ppid $parent_pid -o pid=)
    
    for child_pid in $child_pids; do
        echo $child_pid
        get_child_pids $child_pid
    done
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
    if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
        Help
        exit 0
    fi
    
    my_pids=$(detect_gpu_pids)
    echo "Detected PIDs using the GPU: $my_pids"
    
    container_info=$(get_container_info)
    echo "$container_info" > container_info.json
    
    node_name=$(hostname)
    
    for pid in $my_pids; do
        all_pids=$(echo $pid; get_child_pids $pid)
        
        for sub_pid in $all_pids; do
            p2g_util=$(get_gpu_utilization $sub_pid)
            p2g_usage=$(get_gpu_usage $sub_pid)
            
            echo "Inspecting PID: $sub_pid"
            echo "GPU util: $p2g_util"
            echo "GPU usage: $p2g_usage"
            
            container_details=$(get_container_details $sub_pid)
            
            if [ ! -z "$container_details" ]; then
                container_name=$(echo "$container_details" | jq -r '.name')
                image_name=$(echo "$container_details" | jq -r '.image')
                labels=$(echo "$container_details" | jq -r '.labels')
                
                pod_name=$(echo "$labels" | jq -r '."io.kubernetes.pod.name"')
                namespace=$(echo "$labels" | jq -r '."io.kubernetes.pod.namespace"')
                container_name_label=$(echo "$labels" | jq -r '."io.kubernetes.container.name"')
                
                print_container_info "$node_name" "$pod_name" "$namespace" "$container_name_label" "$image_name" "$sub_pid" "$p2g_util" "$p2g_usage"
            else
                echo -e "No container found for PID: $sub_pid\n"
                
                parent_pid=$(ps -o ppid= -p $sub_pid)
                
                if [ ! -z "$parent_pid" ]; then
                    parent_command=$(ps -o cmd= -p $parent_pid)
                    echo "Parent process (PID $parent_pid): $parent_command"
                    
                    container_for_parent=$(get_container_details $parent_pid)
                    
                    if [ ! -z "$container_for_parent" ]; then
                        container_name_for_parent=$(echo "$container_for_parent" | jq -r '.name')
                        image_name_for_parent=$(echo "$container_for_parent" | jq -r '.image')
                        labels_for_parent=$(echo "$container_for_parent" | jq -r '.labels')
                        
                        pod_name=$(echo "$labels_for_parent" | jq -r '."io.kubernetes.pod.name"')
                        namespace=$(echo "$labels_for_parent" | jq -r '."io.kubernetes.pod.namespace"')
                        container_name_label=$(echo "$labels_for_parent" | jq -r '."io.kubernetes.container.name"')
                        
                        print_container_info "$node_name" "$pod_name" "$namespace" "$container_name_label" "$image_name_for_parent" "$parent_pid" "$p2g_util" "$p2g_usage"
                    else
                        echo -e "No container found for parent PID: $parent_pid\n"
                    fi
                else
                    echo "No parent process found for PID: $sub_pid"
                fi
            fi
        done
    done
}

# Run the main function
main "$@"
