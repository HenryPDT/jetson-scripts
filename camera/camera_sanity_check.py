import httpx
import xmltodict
import time
import socket
import uuid
import xml.etree.ElementTree as ET
import sys
import os
import getpass

# --- CONFIGURATION ---
DEFAULT_TARGETS = ["192.168.1.101", "192.168.1.102"]
USER = "admin"
PASS = os.getenv("CAMERA_PASS")
if not PASS:
    PASS = getpass.getpass("Enter Camera Password: ")

# --- COLORS ---
Color_Off = '\033[0m'
BRed = '\033[1;31m'
BGreen = '\033[1;32m'
BYellow = '\033[1;33m'
BBlue = '\033[1;34m'
BPurple = '\033[1;35m'

def print_info(msg):
    print(f"{BBlue}[INFO]{Color_Off} {msg}")

def print_success(msg):
    print(f"{BGreen}[SUCCESS]{Color_Off} {msg}")

def print_warning(msg):
    print(f"{BYellow}[WARNING]{Color_Off} {msg}")

def print_error(msg):
    print(f"{BRed}[ERROR]{Color_Off} {msg}")

def print_action(msg):
    print(f"{BPurple}[ACTION REQUIRED]{Color_Off} {msg}")

# --- RECOMMENDED STANDARDS ---
RECOMMENDED_DNS = {
    "PrimaryDNS": "8.8.8.8",
    "SecondaryDNS": "1.1.1.1"
}

RECOMMENDED_INTEGRATE = {
    "CGI": {"enable": "true", "certificateType": "digest"},
    "ONVIF": {"enable": "true", "certificateType": "digest/WSSE"},
    "ISAPI": {"enable": "true"}
}

RECOMMENDED_NTP = {
    "hostName": "time.windows.com",
    "portNo": "123",
    "addressingFormatType": "hostname",
    "synchronizeInterval": "1440"
}

RECOMMENDED_TIME = {
    "timeMode": "NTP",
    "timeZone": "CST-10:00:00DST01:00:00,M10.1.0/02:00:00,M4.1.0/03:00:00"
}

RECOMMENDED_VIDEO = {
    "videoCodecType": "H.265",
    "videoResolutionWidth": "1920",
    "videoResolutionHeight": "1080",
    "videoQualityControlType": "VBR",
    "constantBitRate": "2048",
    "fixedQuality": "100",
    "vbrUpperCap": "2048",
    "maxFrameRate": "2500",
    "GovLength": "25",
    "keyFrameInterval": "1000",
    "smoothing": "1",
    "H265Profile": "Main",
    "SmartCodec": {"enabled": "false"},
    "SVC": {"enabled": "false"}
}

RECOMMENDED_IMAGE = {
    "ImageFlip": {"enabled": "false"},
    "IrcutFilter": {
        "IrcutFilterType": "auto",
        "nightToDayFilterLevel": "2",
        "EventTrigger": {
            "eventType": "IO",
            "IrcutFilterAction": "day"
        }
    },
    "Exposure": {
        "ExposureType": "auto",
        "OverexposeSuppress": {"enabled": "false"}
    },
    "powerLineFrequency": {"powerLineFrequencyMode": "50hz"},
    "PTZ": {"enabled": "true"},
    "FocusConfiguration": {"focusStyle": "SEMIAUTOMATIC", "focusLimited": "600"},
    "LensInitialization": {"enabled": "false"},
    "DSS": {"enabled": "false", "DSSLevel": "*2"},
    "IrLight": {"mode": "auto", "brightnessLimit": "100"},
    "ZoomLimit": {"ZoomLimitRatio": "25"},
    "Iris": {"IrisLevel": "160", "maxIrisLevelLimit": "100", "minIrisLevelLimit": "0"},
    "CaptureMode": {"mode": "close"},
    "ImageFreeze": {"enabled": "false"},
    "proportionalpan": {"enabled": "true"},
    "LaserLight": {
        "mode": "manual",
        "brightnessLevel": "0",
        "laserangle": "0"
    },
    "WDR": {"mode": "close", "WDRLevel": "50"},
    "BLC": {"enabled": "false"},
    "NoiseReduce": {
        "mode": "general",
        "GeneralMode": {"generalLevel": "50"}
    },
    "WhiteBalance": {
        "WhiteBalanceStyle": "auto",
        "WhiteBalanceRed": "50",
        "WhiteBalanceBlue": "50"
    },
    "Sharpness": {"SharpnessLevel": "85"},
    "Gain": {"GainLevel": "0", "GainLimit": "25"},
    "Shutter": {
        "ShutterLevel": "1/25",
        "maxShutterLevelLimit": "1/600",
        "minShutterLevelLimit": "1/30000"
    },
    "Color": {
        "brightnessLevel": "50",
        "contrastLevel": "75",
        "saturationLevel": "50"
    },
    "Dehaze": {"DehazeMode": "close"},
    "HLC": {"enabled": "false", "HLCLevel": "0"},
    "EIS": {"enabled": "false"}
}

# --- SADP DISCOVERY ---

def parse_sadp_response(xml_data):
    try:
        root = ET.fromstring(xml_data)
        device_info = {}
        for child in root:
            device_info[child.tag] = child.text
        return device_info
    except Exception:
        return None

def discover_hikvision(timeout=3):
    multicast_group = '239.255.255.250'
    port = 37020
    
    probe_uuid = str(uuid.uuid4()).upper()
    probes = [
        f'<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>{probe_uuid}</Uuid><Types>inquiry</Types></Probe>',
        f'<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>{probe_uuid}</Uuid><Types>inquiry_v32</Types></Probe>'
    ]
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.settimeout(timeout)
    
    # Enable reuse of addresses and ports to avoid "Address already in use" errors
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except AttributeError:
        pass # Some systems don't support SO_REUSEPORT
    
    # Enable broadcast and set multicast TTL
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    
    # Bind to port 37020 - Hikvision replies are hardcoded to this destination port
    try:
        sock.bind(('', port)) 
    except Exception as e:
        print_warning(f"Could not bind to port {port}, discovery might fail: {e}")
    
    devices = {}
    
    print_info(f"Sending SADP probes to {multicast_group}:{port}...")
    
    try:
        for probe in probes:
            sock.sendto(probe.encode('utf-8'), (multicast_group, port))
            sock.sendto(probe.encode('utf-8'), ('255.255.255.255', port))
        
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                data, addr = sock.recvfrom(65535)
                xml_content = data.decode('utf-8', errors='ignore')
                
                if "ProbeMatch" in xml_content:
                    device = parse_sadp_response(xml_content)
                    if device and 'MAC' in device:
                        mac = device['MAC'].upper().replace('-', ':')
                        if mac not in devices:
                            devices[mac] = device
                            print_success(f"Discovered: {device.get('IPv4Address')} - {mac} ({device.get('DeviceType')})")
            except socket.timeout:
                break
            except Exception:
                pass
                
        return list(devices.values())
    finally:
        sock.close()

def get_client():
    # Hikvision requires Content-Type to be explicitly XML for PUT/POST methods
    return httpx.Client(auth=httpx.DigestAuth(USER, PASS), timeout=15.0, headers={"Content-Type": "application/xml"})

def reboot_camera(client, host):
    """Utility to reboot the camera if a change requires it."""
    url = f"http://{host}/ISAPI/System/reboot"
    try:
        response = client.put(url)
        if response.status_code == 200:
            print_success("Reboot command sent successfully.")
            print_warning("IMPORTANT: Please wait 1-2 minutes for the camera to restart, then run this script again to verify final compliance.")
            return True
        else:
            print_error(f"Failed to send reboot command: {response.status_code}")
            return False
    except Exception as e:
        print_error(f"Error during reboot: {e}")
        return False

def verify_dns_config(client, host):
    """Prerequisite 0: Ensure DNS is set so the camera can find the NTP server."""
    url = f"http://{host}/ISAPI/System/Network/interfaces/1"
    max_attempts = 5

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            if response.status_code != 200:
                print_error(f"Failed to get DNS config from {host} (Status: {response.status_code})")
                if "ResponseStatus" in response.text:
                    err = xmltodict.parse(response.text).get("ResponseStatus", {})
                    print_error(f"Reason: {err.get('statusString')} ({err.get('subStatusCode')})")
                return False

            data = xmltodict.parse(response.text)
            if 'NetworkInterface' not in data:
                print_error(f"Unexpected XML structure from {host}: {list(data.keys())}")
                return False

            ip_settings = data['NetworkInterface']['IPAddress']
            current_p = ip_settings.get('PrimaryDNS', {}).get('ipAddress', '0.0.0.0')
            current_s = ip_settings.get('SecondaryDNS', {}).get('ipAddress', '0.0.0.0')

            if attempt == 1:
                print_info(f"Checking DNS: Primary={current_p}, Secondary={current_s}")

            mismatches = []
            if current_p != RECOMMENDED_DNS["PrimaryDNS"]: mismatches.append(("PrimaryDNS", current_p, RECOMMENDED_DNS["PrimaryDNS"]))
            if current_s != RECOMMENDED_DNS["SecondaryDNS"]: mismatches.append(("SecondaryDNS", current_s, RECOMMENDED_DNS["SecondaryDNS"]))

            if not mismatches:
                if attempt == 1: print_success("DNS Configuration is correct.")
                else: print_success("DNS Configuration updated and verified successfully.")
                return True

            if attempt == 1:
                print_warning("DNS settings are incorrect. Updating automatically...")
            else:
                print_warning(f"DNS Verification failed. Re-applying (Attempt {attempt} of {max_attempts})...")

            for field, old, new in mismatches:
                print(f"   - {field}: {old} -> {new}")

            if 'PrimaryDNS' not in data['NetworkInterface']['IPAddress']: data['NetworkInterface']['IPAddress']['PrimaryDNS'] = {}
            data['NetworkInterface']['IPAddress']['PrimaryDNS']['ipAddress'] = RECOMMENDED_DNS["PrimaryDNS"]

            if 'SecondaryDNS' not in data['NetworkInterface']['IPAddress']: data['NetworkInterface']['IPAddress']['SecondaryDNS'] = {}
            data['NetworkInterface']['IPAddress']['SecondaryDNS']['ipAddress'] = RECOMMENDED_DNS["SecondaryDNS"]

            client.put(url, content=xmltodict.unparse(data))
        except Exception as e:
            print_error(f"Failed to verify DNS: {e}")
            return False

    print_error(f"Failed to fully apply DNS settings after {max_attempts} attempts.")
    return False

def verify_integration_config(client, host):
    """Prerequisite 1: Ensure Integration Protocols (ONVIF/ISAPI/CGI) are enabled."""
    url = f"http://{host}/ISAPI/System/Network/Integrate"
    max_attempts = 5

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            if response.status_code != 200:
                print_error(f"Failed to get Integration config (Status: {response.status_code})")
                return False

            data = xmltodict.parse(response.text)
            if 'Integrate' not in data:
                print_error(f"Unexpected XML structure: {list(data.keys())}")
                return False

            current = data['Integrate']

            mismatches = []
            status_lines = []
            for protocol, recommended_vals in RECOMMENDED_INTEGRATE.items():
                if protocol in current:
                    p_status = current[protocol].get('enable', 'false')
                    status_lines.append(f"{protocol}={p_status}")
                    for key, recommended_val in recommended_vals.items():
                        # Only check keys that exist in the camera's config (except 'enable' which we always want)
                        if key in current[protocol] or key == 'enable':
                            actual = current[protocol].get(key)
                            if actual != recommended_val:
                                mismatches.append((protocol, key, actual, recommended_val))

            if attempt == 1:
                print_info(f"Integration Protocols: {', '.join(status_lines)}")

            if not mismatches:
                if attempt == 1: print_success("Integration protocols are correctly configured.")
                else: print_success("Integration settings updated and verified successfully.")
                return True

            if attempt == 1:
                print_warning("Integration settings are incorrect. Updating automatically...")
            else:
                print_warning(f"Integration Verification failed. Re-applying (Attempt {attempt} of {max_attempts})...")

            for protocol, key, old, new in mismatches:
                print(f"   - {protocol}/{key}: {old} -> {new}")

            for protocol, recommended_vals in RECOMMENDED_INTEGRATE.items():
                if protocol in data['Integrate']:
                    for key, expected_val in recommended_vals.items():
                        if key in data['Integrate'][protocol] or key == 'enable':
                            data['Integrate'][protocol][key] = expected_val

            client.put(url, content=xmltodict.unparse(data))
        except Exception as e:
            print_error(f"Failed to verify Integration: {e}")
            return False

    print_error(f"Failed to fully apply Integration settings after {max_attempts} attempts.")
    return False

def verify_onvif_user(client, host):
    """Prerequisite 2: Ensure at least one ONVIF administrator exists."""
    url = f"http://{host}/ISAPI/Security/ONVIF/users"
    max_attempts = 5

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            if response.status_code != 200:
                if attempt == 1: print_info("ONVIF User management not supported or ONVIF is disabled.")
                return True

            data = xmltodict.parse(response.text)
            users = data.get('UserList', {}).get('User', [])
            if isinstance(users, dict):
                users = [users]

            has_admin = any(u.get('userType') == 'administrator' for u in users)

            if has_admin:
                if attempt == 1:
                    admin_user = next(u.get('userName') for u in users if u.get('userType') == 'administrator')
                    print_success(f"ONVIF Administrator exists (User: {admin_user}).")
                else:
                    print_success(f"ONVIF Administrator created and verified successfully.")
                return True

            if attempt == 1:
                print_warning(f"No ONVIF Administrator found. Creating user '{USER}' automatically...")
            else:
                print_warning(f"ONVIF Verification failed. Retrying (Attempt {attempt} of {max_attempts})...")

            user_data = {
                "@version": "2.0",
                "@xmlns": "http://www.hikvision.com/ver20/XMLSchema",
                "id": "0",
                "userName": USER,
                "password": PASS,
                "userType": "administrator"
            }
            payload_a = {"UserList": {"User": user_data}}
            post_response = client.post(url, content=xmltodict.unparse(payload_a))
            if post_response.status_code != 200:
                payload_b = {"User": user_data}
                post_response = client.post(url, content=xmltodict.unparse(payload_b))

            if post_response.status_code != 200:
                print_error(f"Failed to create ONVIF user: {post_response.status_code}")

        except Exception as e:
            print_info(f"Could not verify ONVIF users: {e}")
            return True

    print_error(f"Failed to create ONVIF user after {max_attempts} attempts.")
    return False

def verify_video_config(client, host):
    """Prerequisite 3: Ensure Video quality and codec are correct."""
    url = f"http://{host}/ISAPI/Streaming/channels/101"
    max_attempts = 5
    user_agreed = False

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            if response.status_code != 200:
                print_error(f"Failed to get Video config (Status: {response.status_code})")
                return False

            data = xmltodict.parse(response.text)
            if 'StreamingChannel' not in data or 'Video' not in data['StreamingChannel']:
                print_error(f"Unexpected XML structure for Video: {list(data.keys())}")
                return False

            current_video = data['StreamingChannel']['Video']

            if attempt == 1:
                print_info(f"Checking Video (101): {current_video.get('videoResolutionWidth')}x{current_video.get('videoResolutionHeight')}, {current_video.get('videoCodecType')}")

            mismatches = []
            for key, expected in RECOMMENDED_VIDEO.items():
                current_val = current_video.get(key)
                if current_val is None: continue
                if isinstance(expected, dict):
                    for sub_key, sub_val in expected.items():
                        actual = current_val.get(sub_key)
                        if str(actual) != str(sub_val):
                            mismatches.append(f"{key}/{sub_key}: {actual} -> {sub_val}")
                elif str(current_val) != str(expected):
                    mismatches.append(f"{key}: {current_val} -> {expected}")

            if not mismatches:
                if attempt == 1: print_success("Video settings (101) are correct.")
                else: print_success("Video settings (101) updated and verified successfully.")
                return True

            if not user_agreed:
                print_warning(f"Video settings (101) have {len(mismatches)} mismatches found.")
                for m in mismatches:
                    print(f"   - {m}")
                if input("Apply recommended Video settings? (y/n): ").lower() != 'y':
                    print_info("Skipping Video settings update.")
                    return True
                user_agreed = True
            else:
                print_warning(f"Video Verification failed. {len(mismatches)} mismatches remain. Re-applying (Attempt {attempt} of {max_attempts})...")
                for m in mismatches:
                    print(f"   - {m}")

            for key, expected in RECOMMENDED_VIDEO.items():
                if isinstance(expected, dict):
                    if key not in data['StreamingChannel']['Video']: continue
                    for sub_key, sub_val in expected.items():
                        if sub_key in data['StreamingChannel']['Video'][key]:
                            data['StreamingChannel']['Video'][key][sub_key] = str(sub_val)
                else:
                    if key in data['StreamingChannel']['Video']:
                        data['StreamingChannel']['Video'][key] = str(expected)
            
            put_response = client.put(url, content=xmltodict.unparse(data))
            
            if put_response.status_code == 200:
                res_data = xmltodict.parse(put_response.text)
                sub_status = res_data.get('ResponseStatus', {}).get('subStatusCode')
                
                if sub_status == 'rebootRequired':
                    print_warning("Reboot Required to apply these video settings.")
                    if input("Reboot camera now? (y/n): ").lower() == 'y':
                        reboot_camera(client, host)
                        return False 
                    return True
            else:
                print_error(f"Failed to update video settings: {put_response.status_code}")

        except Exception as e:
            print_error(f"Failed to verify Video config: {e}")
            return False

    print_error(f"Failed to fully apply Video settings after {max_attempts} attempts.")
    return False

def verify_ntp_config(client, host):
    """Prerequisite 4: Ensure NTP Server settings are correct."""
    url = f"http://{host}/ISAPI/System/time/ntpServers/1"
    max_attempts = 5

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            data = xmltodict.parse(response.text)
            current = data['NTPServer']

            if attempt == 1:
                server_host = current.get('hostName')
                print_info(f"Checking NTP: Server={server_host}")

            mismatches = [k for k, v in RECOMMENDED_NTP.items() if current.get(k) != v]

            if not mismatches:
                if attempt == 1: print_success("NTP Configuration is correct.")
                else: print_success("NTP Configuration updated and verified successfully.")
                return True

            if attempt == 1:
                print_warning("NTP Configuration is incorrect. Updating automatically...")
            else:
                print_warning(f"NTP Verification failed. Re-applying (Attempt {attempt} of {max_attempts})...")

            for k in mismatches:
                print(f"   - {k}: {current.get(k)} -> {RECOMMENDED_NTP[k]}")
                data['NTPServer'][k] = RECOMMENDED_NTP[k]

            client.put(url, content=xmltodict.unparse(data))
        except Exception as e:
            print_error(f"Failed to verify NTP: {e}")
            return False

    print_error(f"Failed to fully apply NTP settings after {max_attempts} attempts.")
    return False

def test_ntp_connection(client, host):
    """Prerequisite 5: Trigger the camera's internal NTP test."""
    print_info("Testing NTP connection...")
    url = f"http://{host}/ISAPI/System/time/ntpServers/test"
    payload = {
        "NTPTestDescription": {
            "@version": "2.0",
            "@xmlns": "http://www.hikvision.com/ver20/XMLSchema",
            "addressingFormatType": RECOMMENDED_NTP["addressingFormatType"],
            "hostName": RECOMMENDED_NTP["hostName"],
            "portNo": RECOMMENDED_NTP["portNo"]
        }
    }
    try:
        response = client.post(url, content=xmltodict.unparse(payload))
        result = xmltodict.parse(response.text)
        
        error_code = result['NTPTestResult']['errorCode']
        if error_code == "0":
            print_success("NTP Test Successful.")
            return True
        else:
            desc = result['NTPTestResult']['errorDescription']
            print_error(f"NTP Test Failed: {desc} (Error Code: {error_code})")
            return False
    except Exception as e:
        print_error(f"Failed to test NTP connection: {e}")
        return False

def sync_time_and_timezone(client, host):
    """Final Step: Ensure Timezone and Mode are correct."""
    url = f"http://{host}/ISAPI/System/time"
    max_attempts = 5

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            data = xmltodict.parse(response.text)
            current = data['Time']

            if attempt == 1:
                print_info(f"Checking Time: Zone={current.get('timeZone')}, Mode={current.get('timeMode')}")

            mismatches = [k for k, v in RECOMMENDED_TIME.items() if current.get(k) != v]

            if not mismatches:
                if attempt == 1: print_success("Time and Timezone are already correct.")
                else: print_success("Time and Timezone synced and verified successfully.")
                return True

            if attempt == 1:
                print_warning("Time/Timezone mismatch. Syncing automatically...")
            else:
                print_warning(f"Time Verification failed. Re-applying (Attempt {attempt} of {max_attempts})...")

            for k in mismatches:
                print(f"   - {k}: {current.get(k)} -> {RECOMMENDED_TIME[k]}")
                data['Time'][k] = RECOMMENDED_TIME[k]

            client.put(url, content=xmltodict.unparse(data))
        except Exception as e:
            print_error(f"Failed to sync time: {e}")
            return False

    print_error(f"Failed to fully apply Time settings after {max_attempts} attempts.")
    return False

def verify_image_config(client, host):
    """Prerequisite 6: Ensure Image settings are correct."""
    url = f"http://{host}/ISAPI/Image/channels/1"
    max_attempts = 5
    user_agreed = False

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.get(url)
            data = xmltodict.parse(response.text)
            current_image = data['ImageChannel']

            if attempt == 1:
                print_info(f"Checking Image Settings (1)...")

            if "IrcutFilter" in current_image:
                if "EventTrigger" in current_image["IrcutFilter"]:
                    RECOMMENDED_IMAGE["IrcutFilter"]["nightToDayFilterLevel"] = "4"
                else:
                    RECOMMENDED_IMAGE["IrcutFilter"]["nightToDayFilterLevel"] = "2"

            mismatches = []
            for key, expected in RECOMMENDED_IMAGE.items():
                if key not in current_image: continue

                current_val = current_image[key]
                if isinstance(expected, dict):
                    for sub_key, sub_val in expected.items():
                        if sub_key not in current_val: continue

                        if isinstance(sub_val, dict):
                            for sub_sub_key, sub_sub_val in sub_val.items():
                                if sub_sub_key not in current_val[sub_key]: continue
                                actual = current_val[sub_key][sub_sub_key]
                                if str(actual) != str(sub_sub_val):
                                    mismatches.append(f"{key}/{sub_key}/{sub_sub_key}: {actual} -> {sub_sub_val}")
                        else:
                            actual = current_val[sub_key]
                            if str(actual) != str(sub_val):
                                mismatches.append(f"{key}/{sub_key}: {actual} -> {sub_val}")
                else:
                    if str(current_val) != str(expected):
                        mismatches.append(f"{key}: {current_val} -> {expected}")

            if not mismatches:
                if attempt == 1: print_success("Image settings (1) are correct.")
                else: print_success("Image settings (1) updated and verified successfully.")
                return True

            if not user_agreed:
                print_warning(f"Image settings (1) have {len(mismatches)} mismatches found.")
                for m in mismatches:
                    print(f"   - {m}")
                if input("Apply recommended Image settings? (y/n): ").lower() != 'y':
                    print_info("Skipping Image settings update.")
                    return True
                user_agreed = True
            else:
                print_warning(f"Image Verification failed. {len(mismatches)} mismatches remain. Re-applying (Attempt {attempt} of {max_attempts})...")
                for m in mismatches:
                    print(f"   - {m}")

            success = True
            keys_to_update = set()
            for m in mismatches:
                key = m.split('/')[0].split(':')[0]
                keys_to_update.add(key)

            for key in keys_to_update:
                expected = RECOMMENDED_IMAGE[key]
                payload_dict = {key: {"@version": "2.0", "@xmlns": "http://www.hikvision.com/ver20/XMLSchema"}}

                if isinstance(expected, dict):
                    current_val = data['ImageChannel'][key]
                    for sub_key, sub_val in expected.items():
                        if sub_key not in current_val: continue
                        if isinstance(sub_val, dict):
                            payload_dict[key][sub_key] = {}
                            for sub_sub_key, sub_sub_val in sub_val.items():
                                if sub_sub_key not in current_val[sub_key]: continue
                                payload_dict[key][sub_key][sub_sub_key] = str(sub_sub_val)
                        else:
                            payload_dict[key][sub_key] = str(sub_val)
                else:
                    payload_dict[key] = str(expected)

                xml_payload = xmltodict.unparse(payload_dict)
                endpoint_key = key[0].lower() + key[1:]
                if key in ["WDR", "BLC", "PTZ", "HLC", "EIS", "DSS"]: endpoint_key = key

                sub_url = f"http://{host}/ISAPI/Image/channels/1/{endpoint_key}"
                put_res = client.put(sub_url, content=xml_payload)

                if put_res.status_code != 200:
                    sub_url_exact = f"http://{host}/ISAPI/Image/channels/1/{key}"
                    put_res_exact = client.put(sub_url_exact, content=xml_payload)
                    if put_res_exact.status_code != 200:
                        print_error(f"Failed to update {key} (Status {put_res.status_code})")
                        success = False

            if not success:
                print_error("Some Image settings failed to apply.")

        except Exception as e:
            print_error(f"Failed to verify Image settings: {e}")
            return False

    print_error(f"Failed to fully apply Image settings after {max_attempts} attempts.")
    return False

def run_sanity_check(host):
    with get_client() as client:
        try:
            if not verify_dns_config(client, host): return
            if not verify_integration_config(client, host): return
            if not verify_onvif_user(client, host): return
            if not verify_ntp_config(client, host): return
            if not test_ntp_connection(client, host): return
            sync_time_and_timezone(client, host)
            if not verify_video_config(client, host): return
            if not verify_image_config(client, host): return
            print_success(f"CAMERA COMPLIANCE CHECK COMPLETE FOR {host}.")
        except Exception as e:
            print_error(f"An error occurred on {host}: {e}")

def main():
    print_info("Starting Hikvision Camera Setup & Sanity Check...")
    found_devices = discover_hikvision()
    
    targets = []
    default_str = ", ".join(DEFAULT_TARGETS)
    
    if not found_devices:
        print_warning("No devices discovered on the network.")
        if input(f"Use configured default targets ({default_str})? (y/n): ").lower() == 'y':
            targets = DEFAULT_TARGETS
    else:
        print(f"\nTotal discovered: {len(found_devices)}")
        print("-" * 110)
        print(f"{'Index':<6} {'IPv4 Address':<15} {'MAC Address':<18} {'Device Type':<20} {'Status':<8} {'Port':<6} {'Software Version'}")
        print("-" * 110)
        for i, dev in enumerate(found_devices):
            ipv4 = dev.get('IPv4Address', 'N/A')
            mac = dev.get('MAC', 'N/A').upper().replace('-', ':')
            dtype = dev.get('DeviceType', 'N/A')
            status = "Active" if dev.get('Activated') == 'true' else "Inactive"
            port = dev.get('CommandPort', 'N/A')
            version = dev.get('SoftwareVersion', 'N/A')
            print(f"{i+1:<6} {ipv4:<15} {mac:<18} {dtype:<20} {status:<8} {port:<6} {version}")
            
        choice = input(f"\nEnter index, 'all' for all active, or 'skip' for defaults ({default_str}): ").strip().lower()
        if choice == 'all':
            targets = [dev.get('IPv4Address') for dev in found_devices if dev.get('Activated') == 'true' and dev.get('IPv4Address')]
        elif choice.isdigit() and 1 <= int(choice) <= len(found_devices):
            targets = [found_devices[int(choice)-1].get('IPv4Address')]
        elif choice == 'skip' or not choice:
            targets = DEFAULT_TARGETS
        else:
            print_warning("Invalid choice. Defaulting to configured targets.")
            targets = DEFAULT_TARGETS

    for target in targets:
        print(f"\n{'='*60}\nStarting sanity check for {target}\n{'='*60}")
        run_sanity_check(target)

if __name__ == "__main__":
    main()
