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

# Function to get all child PIDs recursively
get_child_pids() {
    local parent_pid=$1
    local child_pids=$(ps --ppid $parent_pid -o pid=)
    
    for child_pid in $child_pids; do
        echo $child_pid
        get_child_pids $child_pid
    done
}

my_pids=$(nvidia-smi | sed '1,/Processes:/d' | awk '{print $5}' | grep -v 'PID' | grep -v '|' | awk '!NF || !seen[$0]++')

echo "Detected PIDs using the GPU: $my_pids"

# Use crictl to find the container name by PID
container_info=$(sudo crictl ps -a --quiet | xargs sudo crictl inspect --output json)

# Output the JSON for analysis
echo "$container_info" > container_info.json

node_name=$(hostname)

for pid in $my_pids; do
    # Get the entire process tree for the PID
    all_pids=$(echo $pid; get_child_pids $pid)
    
    for sub_pid in $all_pids; do
        p2g_util=$(nvidia-smi pmon -c 1 | grep $sub_pid | awk '{print $1, $2, $4, $5}')
        p2g_usage=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | grep $sub_pid | awk '{print $3, $4}')

        # Debug output
        echo "Inspecting PID: $sub_pid"
        echo "GPU util: $p2g_util"
        echo "GPU usage: $p2g_usage"

        # Parse container info to find the matching PID and extract relevant fields
        container_details=$(echo "$container_info" | jq --arg sub_pid "$sub_pid" -c 'select(.info.pid == ($sub_pid | tonumber)) | {name: .info.config.metadata.name, image: .info.config.image.user_specified_image, labels: .info.config.labels}')

        if [ ! -z "$container_details" ]; then
            container_name=$(echo "$container_details" | jq -r '.name')
            image_name=$(echo "$container_details" | jq -r '.image')
            labels=$(echo "$container_details" | jq -r '.labels')

            # Extract labels
            pod_name=$(echo "$labels" | jq -r '."io.kubernetes.pod.name"')
            namespace=$(echo "$labels" | jq -r '."io.kubernetes.pod.namespace"')
            container_name_label=$(echo "$labels" | jq -r '."io.kubernetes.container.name"')
            
            echo -e NODE_NAME: $node_name
            echo -e POD_NAME: $pod_name
            echo -e NAMESPACE: $namespace
            echo -e CONTAINER_NAME: $container_name_label
            echo -e IMAGE: $image_name
            echo -e PID: $sub_pid
            echo -e GPU util: $p2g_util
            echo -e GPU usage: $p2g_usage
            echo -e "\n"
        else
            echo -e "No container found for PID: $sub_pid\n"

            # Check for parent process if no container found for sub PID
            parent_pid=$(ps -o ppid= -p $sub_pid)
            
            if [ ! -z "$parent_pid" ]; then
                parent_command=$(ps -o cmd= -p $parent_pid)
                echo "Parent process (PID $parent_pid): $parent_command"
                
                # Search container_info for parent PID
                container_for_parent=$(echo "$container_info" | jq --arg parent_pid "$parent_pid" -c 'select(.info.pid == ($parent_pid | tonumber)) | {name: .info.config.metadata.name, image: .info.config.image.user_specified_image, labels: .info.config.labels}')

                if [ ! -z "$container_for_parent" ]; then
                    container_name_for_parent=$(echo "$container_for_parent" | jq -r '.name')
                    image_name_for_parent=$(echo "$container_for_parent" | jq -r '.image')
                    labels_for_parent=$(echo "$container_for_parent" | jq -r '.labels')

                    # Extract labels for parent
                    pod_name=$(echo "$labels_for_parent" | jq -r '."io.kubernetes.pod.name"')
                    namespace=$(echo "$labels_for_parent" | jq -r '."io.kubernetes.pod.namespace"')
                    container_name_label=$(echo "$labels_for_parent" | jq -r '."io.kubernetes.container.name"')
                    
                    echo -e NODE_NAME: $node_name
                    echo -e POD_NAME: $pod_name
                    echo -e NAMESPACE: $namespace
                    echo -e CONTAINER_NAME: $container_name_label
                    echo -e IMAGE: $image_name_for_parent
                    echo -e PID: $parent_pid
                    echo -e GPU util: $p2g_util
                    echo -e GPU usage: $p2g_usage
                    echo -e "\n"
                else
                    echo -e "No container found for parent PID: $parent_pid\n"
                fi
            else
                echo "No parent process found for PID: $sub_pid"
            fi
        fi
    done
done
