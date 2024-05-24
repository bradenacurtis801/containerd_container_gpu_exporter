import time
import subprocess
from prometheus_client.core import GaugeMetricFamily, REGISTRY, CounterMetricFamily
from prometheus_client import start_http_server

class CustomCollector(object):
    
    def __init__(self):
        self.results_dict = {
            "container_running_gpu_pid": 0,
            "container_name": "",
            "container_used_gpu_id": 0,
            "container_utilization_gpu_percent": 0,
            "container_gpu_memory_used_MiB": 0,
            "container_total_gpu_used": 0,
        }

    def run_bash_script(self):
        result = subprocess.run("crictl ps --quiet", stdout=subprocess.PIPE, shell=True)
        container_ids = result.stdout.decode('utf-8').split()
        metrics_output = []

        for container_id in container_ids:
            # Fetch PID and container name
            inspect_result = subprocess.run(f"crictl inspect {container_id}", stdout=subprocess.PIPE, shell=True)
            inspect_data = yaml.safe_load(inspect_result.stdout.decode('utf-8'))
            pid = inspect_data['info']['pid']
            name = inspect_data['info']['metadata']['name']

            # Fetch GPU utilization data
            gpu_usage_result = subprocess.run(f"nvidia-smi --query-compute-apps=pid,utilization.gpu,memory.used --format=csv,noheader,nounits -i {pid}", stdout=subprocess.PIPE, shell=True)
            gpu_usage_data = gpu_usage_result.stdout.decode('utf-8').strip().split('\n')

            for line in gpu_usage_data:
                if line:
                    metrics_output.append(f"PID: {pid}\nCONTAINER_NAME: {name}\nGPU util: {line}\n")
        
        return "\n\n".join(metrics_output)

    def split_list(self, list_a, chunk_size):
        segmented_list = []
        for i in range(0, len(list_a), chunk_size):
            segmented_list.append(list_a[i:i + chunk_size])
        return segmented_list

    def parse_bash_results(self, runnning_process):
        multi_gpu_result_list = []
        for idx, container in enumerate(runnning_process.split("\n\n")):
            if not container:
                continue 
            elif len("".join(container.split(" "))) == 0:
                continue
            elif "PID: " not in container:
                continue

            container_gpu_pid = container.split('PID: ')[1].split("\n")[0]
            container_name = container.split('CONTAINER_NAME: ')[1].split("\n")[0]
            container_gpu_util = container.split('GPU util: ')[1].split("\n")[0].split(',')
            container_gpu_ids = [0]  # Since we fetch data by PID, assume GPU ID 0 for simplicity
            container_util_per_gpu = [container_gpu_util[1]]
            container_usage_per_gpu = [container_gpu_util[2]]
            container_total_gpu_used = 1

            for gpu_id, gpu_util, gpu_usage in zip(container_gpu_ids, container_util_per_gpu, container_usage_per_gpu):
                metrics_resutls = self.results_dict.copy()
                metrics_resutls["container_running_gpu_pid"] = container_gpu_pid
                metrics_resutls["container_name"] = container_name
                metrics_resutls["container_used_gpu_id"] = gpu_id
                metrics_resutls["container_utilization_gpu_percent"] = gpu_util
                metrics_resutls["container_gpu_memory_used_MiB"] = gpu_usage
                metrics_resutls["container_total_gpu_used"] = container_total_gpu_used
                multi_gpu_result_list.append(metrics_resutls)

        return multi_gpu_result_list

    def collect(self):
        labels = ["container_name", "gpu"]
        
        for result_dict in self.parse_bash_results(self.run_bash_script()):
            container_name = str(result_dict["container_name"])
            gpu_id = str(result_dict["container_used_gpu_id"])

            gauge_pid = GaugeMetricFamily('container_running_gpu_pid', 'What pid is the gpu container', labels=labels)
            gauge_pid.add_metric([container_name, gpu_id], value=int(result_dict['container_running_gpu_pid']))
            yield gauge_pid

            gauge_name = GaugeMetricFamily('container_name', 'Container name', labels=labels)
            gauge_name.add_metric([container_name, gpu_id], value=1)
            yield gauge_name

            gauge_gpu_id = GaugeMetricFamily('container_used_gpu_id', 'Container used gpu', labels=labels)
            gauge_gpu_id.add_metric([container_name, gpu_id], value=int(result_dict['container_used_gpu_id']))
            yield gauge_gpu_id

            gauge_util = GaugeMetricFamily('container_utilization_gpu_percent', 'Help text', labels=labels)
            gauge_util.add_metric([container_name, gpu_id], value=int(result_dict['container_utilization_gpu_percent']))
            yield gauge_util

            gauge_usage = GaugeMetricFamily('container_gpu_memory_used_MiB', 'Help text', labels=labels)
            gauge_usage.add_metric([container_name, gpu_id], value=int(result_dict['container_gpu_memory_used_MiB']))
            yield gauge_usage

            counter_gpu = CounterMetricFamily('container_total_gpu_used', 'Help text', labels=labels)
            counter_gpu.add_metric([container_name, gpu_id], value=int(result_dict['container_total_gpu_used']))
            yield counter_gpu


if __name__ == "__main__":
    port = 9066
    frequency = 0.5
    
    REGISTRY.unregister(GC_COLLECTOR)
    REGISTRY.unregister(PLATFORM_COLLECTOR)
    REGISTRY.unregister(PROCESS_COLLECTOR)
    start_http_server(port)
    REGISTRY.register(CustomCollector())
    while True:
        time.sleep(frequency)
