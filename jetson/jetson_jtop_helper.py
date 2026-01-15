#!/usr/bin/env python3
import json
import sys
import argparse
import time
from jtop import jtop, JtopException

def get_jetson_info(enable_clocks=False, set_nvpmodel=None):
    data = {}
    try:
        with jtop() as jetson:
            # Management Actions (need to be done before reading stats if we want to see change)
            if jetson.ok():
                if enable_clocks:
                    try:
                        jetson.jetson_clocks = True
                        jetson.jetson_clocks.boot = True
                        data['clocks_action'] = "Enabled jetson_clocks and set to boot"
                    except Exception as e:
                        data['clocks_action_error'] = str(e)

                if set_nvpmodel is not None:
                    try:
                        # Try to convert to int if possible, otherwise use string
                        try:
                            val = int(set_nvpmodel)
                        except ValueError:
                            val = set_nvpmodel
                        
                        jetson.nvpmodel = val
                        time.sleep(1) # Wait for change to reflect
                        data['nvpmodel_action'] = f"Set nvpmodel to {val}"
                    except Exception as e:
                        data['nvpmodel_action_error'] = str(e)

            if jetson.ok():
                # Board Info
                board = jetson.board
                data['board'] = {
                    'model': board.get('hardware', {}).get('Model', 'Unknown'),
                    'serial': board.get('hardware', {}).get('Serial Number', 'Unknown'),
                    'l4t': board.get('hardware', {}).get('L4T', 'Unknown'),
                    'jetpack': board.get('hardware', {}).get('Jetpack', 'Unknown'),
                    'module': board.get('hardware', {}).get('Module', 'Unknown')
                }

                # SDK Libraries
                data['libraries'] = board.get('libraries', {})

                # NVP Model (Power Mode)
                data['nvpmodel'] = {
                    'name': jetson.nvpmodel.name if jetson.nvpmodel else "Unknown",
                    'id': jetson.nvpmodel.id if jetson.nvpmodel else -1,
                    'models': jetson.nvpmodel.models if jetson.nvpmodel else []
                }

                # Jetson Clocks
                if jetson.jetson_clocks:
                    data['jetson_clocks'] = {
                        'active': bool(jetson.jetson_clocks),
                        'status': jetson.jetson_clocks.status,
                        'boot': jetson.jetson_clocks.boot
                    }
                else:
                    data['jetson_clocks'] = {"active": False, "status": "inactive", "boot": False}

                # CPU Info
                cpu_info = jetson.cpu
                data['cpu'] = {
                    'total_user': round(cpu_info.get('total', {}).get('user', 0), 1),
                    'total_system': round(cpu_info.get('total', {}).get('system', 0), 1),
                    'total_idle': round(cpu_info.get('total', {}).get('idle', 0), 1),
                    'online_cores': sum(1 for c in cpu_info.get('cpu', []) if c.get('online', False))
                }

                # GPU Info
                gpu_info = jetson.gpu
                data['gpu'] = {
                    'load': gpu_info.get('status', {}).get('load', 0),
                    'curr_freq': gpu_info.get('freq', {}).get('cur', 0),
                    'max_freq': gpu_info.get('freq', {}).get('max', 0)
                }

                # Engines (DLA, NVENC, NVDEC)
                data['engines'] = {}
                engines = jetson.engine
                for group, items in engines.items():
                    data['engines'][group] = {}
                    for engine_name, info in items.items():
                        data['engines'][group][engine_name] = {
                            'online': info.get('online', False),
                            'cur': info.get('cur', 0)
                        }

                # RAM Info
                memory = jetson.memory
                data['ram'] = {
                    'total': memory.get('RAM', {}).get('tot', 0),
                    'used': memory.get('RAM', {}).get('used', 0),
                    'free': memory.get('RAM', {}).get('free', 0)
                }

                # SWAP Info
                data['swap'] = {
                    'total': memory.get('SWAP', {}).get('tot', 0),
                    'used': memory.get('SWAP', {}).get('used', 0)
                }

                # Thermal Info
                temp_info = jetson.temperature
                data['temperature'] = {k: round(v['temp'], 1) for k, v in temp_info.items() if v.get('online', False)}

                # Fan Info
                fan_info = jetson.fan
                fan_speed = fan_info.get('speed', [0])[0] if isinstance(fan_info.get('speed'), list) else fan_info.get('speed', 0)
                fan_profile = fan_info.get('profile', 'Unknown')
                if fan_profile == "Unknown":
                    fan_profile = fan_info.get('governor', fan_info.get('control', 'Unknown'))

                data['fan'] = {
                    'speed': fan_speed,
                    'profile': fan_profile
                }

                # GPU Processes
                data['processes'] = []
                for p in jetson.processes:
                    # p is a list: [PID, User, GPU, Type, Priority, State, CPU%, RAM, GPU_MEM, Name]
                    if len(p) >= 10:
                        data['processes'].append({
                            'pid': p[0],
                            'user': p[1],
                            'gpu_mem': p[8],
                            'name': p[9]
                        })

                # Disk Info
                disk_info = jetson.disk
                data['disk'] = {
                    'total': disk_info.get('total', 0),
                    'used': disk_info.get('used', 0),
                    'available': disk_info.get('available', 0)
                }

                return data
            else:
                return {"error": "jtop is not ok (service might not be running)"}
    except JtopException as e:
        return {"error": f"JtopException: {str(e)}"}
    except Exception as e:
        return {"error": f"Unexpected error: {str(e)}"}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--enable-clocks", action="store_true", help="Enable jetson_clocks and set to boot")
    parser.add_argument("--set-nvpmodel", type=str, help="Set NVP Model by name or ID")
    args = parser.parse_args()

    result = get_jetson_info(enable_clocks=args.enable_clocks, set_nvpmodel=args.set_nvpmodel)
    print(json.dumps(result, indent=2))
