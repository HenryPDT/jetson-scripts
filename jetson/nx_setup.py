import requests
import urllib3
import time
import os

# Suppress insecure request warnings for self-signed certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ==========================================
# LOGGING HELPERS (Matches shell script format)
# ==========================================
C_OFF = '\033[0m'
B_RED = '\033[1;31m'
B_GREEN = '\033[1;32m'
B_YELLOW = '\033[1;33m'
B_BLUE = '\033[1;34m'
B_PURPLE = '\033[1;35m'

def print_info(msg): echo(f"{B_BLUE}[INFO]{C_OFF} {msg}")
def print_success(msg): echo(f"{B_GREEN}[SUCCESS]{C_OFF} {msg}")
def print_warning(msg): echo(f"{B_YELLOW}[WARNING]{C_OFF} {msg}")
def print_error(msg): echo(f"{B_RED}[ERROR]{C_OFF} {msg}")
def echo(msg): print(msg)

# ==========================================
# CONFIGURATION VARIABLES
# ==========================================
# This name is ONLY used if the script needs to initialize a NEW system.
SYSTEM_NAME = os.environ.get("NX_SYSTEM_NAME")
DEFAULT_NAME = os.environ.get("NX_DEFAULT_NAME", "New_Device")

FACTORY_ADMIN_USER = "admin"
FACTORY_ADMIN_PASS = "admin"
NEW_ADMIN_PASSWORD = os.environ.get("NX_ADMIN_PASS")

CLOUD_USER = os.environ.get("NX_CLOUD_USER")
CLOUD_PASS = os.environ.get("NX_CLOUD_PASS")
CLOUD_URL = os.environ.get("NX_CLOUD_URL", "https://nxvms.com")

# Validate required variables
missing_vars = []
if not NEW_ADMIN_PASSWORD: missing_vars.append("NX_ADMIN_PASS")
if not CLOUD_USER: missing_vars.append("NX_CLOUD_USER")
if not CLOUD_PASS: missing_vars.append("NX_CLOUD_PASS")

if missing_vars:
    print_error(f"Missing required environment variables: {', '.join(missing_vars)}")
    print_info("These must be set via environment variables or the .secrets file in the calling script.")
    exit(1)

# ==========================================
# STEP 1: DETECT SERVER PORT & STATE
# ==========================================
print_info("Checking Server Status (Waiting for ports to open)...")
ports_to_try = [7001, 7011]
active_port = None
is_cloud_connected = False
server_module_info = {}

# The service might be "active" but the API port can take several seconds to open
MAX_ATTEMPTS = 5
for attempt in range(1, MAX_ATTEMPTS + 1):
    for port in ports_to_try:
        try:
            test_url = f"https://localhost:{port}/api/moduleInformation"
            response = requests.get(test_url, verify=False, timeout=3)
            if response.status_code == 200:
                active_port = port
                server_module_info = response.json().get('reply', {})
                
                # Check if cloudSystemId is populated
                cloud_id = server_module_info.get('cloudSystemId', "")
                if cloud_id != "":
                    is_cloud_connected = True
                break
        except requests.exceptions.RequestException:
            continue
    
    if active_port:
        break
    
    if attempt < MAX_ATTEMPTS:
        print_info(f"  Attempt {attempt}/{MAX_ATTEMPTS}: Server not ready yet. Retrying in 2s...")
        time.sleep(2)

if not active_port:
    print_error("Could not connect to Nx Server on 7001 or 7011 after 30 seconds.")
    print_info("Please ensure the service is running and not stuck in a crash loop.")
    exit(1)

SERVER_URL = f"https://localhost:{active_port}"
print_success(f"Server found active on port: {active_port}")

# ==========================================
# STEP 2: CHECK LOCAL AUTHENTICATION STATE
# ==========================================
needs_local_setup = False
local_token = None

# Try logging in with the DESIRED password
check_auth = requests.post(f"{SERVER_URL}/rest/v2/login/sessions",
    json={"username": "admin", "password": NEW_ADMIN_PASSWORD},
    verify=False
)

if check_auth.status_code == 200:
    print_success("Local system is already initialized with the correct password.")
    local_token = check_auth.json().get('token')
else:
    # Desired password didn't work. Check if it's still at factory default.
    factory_auth = requests.post(f"{SERVER_URL}/rest/v2/login/sessions",
        json={"username": FACTORY_ADMIN_USER, "password": FACTORY_ADMIN_PASS},
        verify=False
    )
    if factory_auth.status_code == 200:
        print_warning("System is at factory defaults. Local setup is required.")
        needs_local_setup = True
        local_token = factory_auth.json().get('token')
    else:
        print_error("Cannot log in with factory default OR the desired new password.")
        print_info("The system may have been initialized with an unknown password. Aborting.")
        exit(1)

# ==========================================
# STEP 3: EXECUTE LOCAL SETUP (If needed)
# ==========================================
if needs_local_setup:
    if not SYSTEM_NAME:
        # Prompt user for a system name if not provided via environment
        prompt = f"{B_PURPLE}[INPUT REQUIRED]{C_OFF} Enter a name for this NX Witness System (or press Enter for default: {DEFAULT_NAME}): "
        try:
            SYSTEM_NAME = input(prompt).strip()
        except EOFError:
            SYSTEM_NAME = DEFAULT_NAME
            
        if not SYSTEM_NAME:
            SYSTEM_NAME = DEFAULT_NAME

    print_info(f"Initializing local system as '{SYSTEM_NAME}'...")
    setup_payload = {
        "name": SYSTEM_NAME,
        "settingsPreset": "recommended",
        "settings": {
            "autoDiscoveryEnabled": False,
            "cameraSettingsOptimization": False,
            "statisticsAllowed": False
        },
        "local": {
            "password": NEW_ADMIN_PASSWORD
        }
    }

    setup_req = requests.post(f"{SERVER_URL}/rest/v2/system/setup",
        json=setup_payload,
        headers={"Authorization": f"Bearer {local_token}"},
        verify=False 
    )

    if setup_req.status_code == 200:
        print_success(f"Local system fully initialized as '{SYSTEM_NAME}'.")
        time.sleep(2) # Let database stabilize
        
        # Re-authenticate to get a fresh token with the new password
        re_login = requests.post(f"{SERVER_URL}/rest/v2/login/sessions",
            json={"username": "admin", "password": NEW_ADMIN_PASSWORD},
            verify=False
        )
        local_token = re_login.json().get('token')
        
        # Rename the physical server node to match the System Name
        print_info(f"Renaming server node to '{SYSTEM_NAME}'...")
        rename_req = requests.patch(f"{SERVER_URL}/rest/v2/servers/this",
            json={"name": SYSTEM_NAME},
            headers={"Authorization": f"Bearer {local_token}"},
            verify=False
        )
        if rename_req.status_code == 200:
            print_success("Server node renamed successfully.")
        else:
            print_warning(f"Failed to rename server node. Status: {rename_req.status_code}")
            
    else:
        print_error(f"FAILED to initialize local system. Status: {setup_req.status_code}")
        print_info(setup_req.text)
        exit(1)
else:
    print_info("Local setup skipped (already complete).")

# ==========================================
# STEP 3.5: REFRESH SERVER STATE
# ==========================================
# We must fetch fresh data here so the Cloud and Audit steps use the NEW System name and real ID.
time.sleep(1)
mod_resp = requests.get(f"{SERVER_URL}/api/moduleInformation", verify=False)
if mod_resp.status_code == 200:
    server_module_info = mod_resp.json().get('reply', {})

# ==========================================
# STEP 4: CLOUD BINDING (If needed)
# ==========================================
if not is_cloud_connected:
    print_info("Authenticating with Nx Cloud...")
    
    # Get Cloud OAuth Token
    cloud_oauth_req = requests.post(f"{CLOUD_URL}/cdb/oauth2/token",
        json={
            "grant_type": "password",
            "response_type": "token",
            "client_id": "3rdParty",
            "scope": f"{CLOUD_URL} cloudSystemId=*",
            "username": CLOUD_USER,
            "password": CLOUD_PASS
        }
    )

    if cloud_oauth_req.status_code != 200:
        print_error("FAILED to authenticate with cloud. Check credentials.")
        exit(1)

    cloud_access_token = cloud_oauth_req.json()['access_token']

    # Reserve system in the Cloud using the freshly fetched System Name
    print_info("Binding system to Cloud...")
    cloud_bind_req = requests.post(f"{CLOUD_URL}/cdb/system/bind",
        json={"name": server_module_info.get('systemName', SYSTEM_NAME), "customization": "default"},
        headers={"Authorization": f"Bearer {cloud_access_token}"}
    )

    if cloud_bind_req.status_code != 200:
        print_error("FAILED to reserve system in the cloud.")
        print_info(cloud_bind_req.text)
        exit(1)

    cloud_data = cloud_bind_req.json()
    print_success(f"Cloud reservation successful. Cloud System ID: {cloud_data['id']}")

    # Finalize local link
    print_info("Finalizing link to local server...")
    cloud_bind_payload = {
        "systemId": cloud_data["id"],
        "authKey": cloud_data["authKey"],
        "owner": cloud_data["ownerAccountEmail"]
    }

    final_link_req = requests.post(f"{SERVER_URL}/rest/v2/system/cloudBind",
        json=cloud_bind_payload,
        headers={"Authorization": f"Bearer {local_token}"},
        verify=False
    )

    if final_link_req.status_code == 200:
        print_success("The local server is now connected to Nx Cloud.")
        is_cloud_connected = True
        # Manually inject the cloud ID so the audit shows it without needing a second refresh
        server_module_info['cloudSystemId'] = cloud_data["id"]
    else:
        print_error(f"FAILED to link local server to cloud. Status: {final_link_req.status_code}")
        print_info(final_link_req.text)
else:
    print_info("Cloud setup skipped (already complete).")


# ==========================================
# STEP 5: DEEP SYSTEM AUDIT (LOCALIZED)
# ==========================================
echo(f"\n{B_PURPLE}" + "="*60 + f"{C_OFF}")
echo(f"{B_PURPLE}             NX SYSTEM AUDIT REPORT{C_OFF}")
echo(f"{B_PURPLE}" + "="*60 + f"{C_OFF}")

auth_header = {"Authorization": f"Bearer {local_token}"}

# 1. Fetch Specific Server Node Info & ID
server_specific_info = {}
local_server_id = None

srv_resp = requests.get(f"{SERVER_URL}/rest/v2/servers/this", headers=auth_header, verify=False)
if srv_resp.status_code == 200:
    server_specific_info = srv_resp.json()
    local_server_id = server_specific_info.get('id')

echo(f"{B_BLUE}[ SERVER INFO ]{C_OFF}")
echo(f" System Name:      {server_module_info.get('systemName', 'Unknown')}")
echo(f" Server Node Name: {server_specific_info.get('name', 'Unknown')}")
echo(f" Local System ID:  {server_module_info.get('localSystemId', 'Unknown')}")
echo(f" Cloud System ID:  {server_module_info.get('cloudSystemId', 'Not Connected')}")
echo(f" Server Node ID:   {local_server_id}")
echo(f" Nx Version:       {server_module_info.get('version', 'Unknown')}")
echo(f" Hardware IP/Port: localhost:{active_port}")

# 2. Fetch Attached Cameras (Strictly filtered to THIS server)
echo(f"\n{B_BLUE}[ CAMERAS ON THIS SERVER NODE ]{C_OFF}")

if local_server_id:
    # We pass the local_server_id as a query parameter to filter the results
    cam_resp = requests.get(
        f"{SERVER_URL}/rest/v2/devices", 
        headers=auth_header, 
        params={"serverId": local_server_id}, 
        verify=False
    )

    if cam_resp.status_code == 200:
        cameras = cam_resp.json()
        
        if isinstance(cameras, list) and len(cameras) > 0:
            print_info(f"Total Cameras Found: {len(cameras)}\n")
            for idx, cam in enumerate(cameras, 1):
                cam_name = cam.get("name", "Unknown Camera")
                cam_id = cam.get("id", "Unknown ID").strip('{}')
                cam_status = cam.get("status", "Unknown")
                cam_ip = cam.get("url", "Unknown IP")
                
                # Format output beautifully
                echo(f" {idx}. {cam_name}")
                echo(f"    Status: {cam_status.upper()} | IP: {cam_ip}")
                echo(f"    ID: {cam_id}")
                echo("    " + "-"*40)
        else:
             print_info("No cameras found connected directly to this server node.")
    else:
        print_warning(f"Failed to retrieve camera list. Status: {cam_resp.status_code}")
else:
    print_warning("Could not determine the local Server ID to filter cameras.")

echo(f"{B_PURPLE}" + "="*60 + f"{C_OFF}\n")
