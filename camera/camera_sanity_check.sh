#!/bin/sh

# --- CONFIGURATION ---
DEFAULT_TARGETS="192.168.1.101 192.168.1.102"
CAM_USER="admin"
PASS="${CAMERA_PASS:-}"

# --- RECOMMENDED STANDARDS ---
REC_DNS_PRIMARY="8.8.8.8"
REC_DNS_SECONDARY="1.1.1.1"

REC_INTEGRATE="
    CGI:enable:true CGI:certificateType:digest
    ONVIF:enable:true ONVIF:certificateType:digest/WSSE
    ISAPI:enable:true
"

REC_NTP="
    hostName:time.windows.com portNo:123
    addressingFormatType:hostname synchronizeInterval:1440
"

REC_TIME_MODE="NTP"
REC_TIME_ZONE="CST-10:00:00DST01:00:00,M10.1.0/02:00:00,M4.1.0/03:00:00"

REC_VIDEO="
    Video:videoCodecType:H.265 Video:videoResolutionWidth:1920
    Video:videoResolutionHeight:1080 Video:videoQualityControlType:VBR
    Video:constantBitRate:2048 Video:fixedQuality:100
    Video:vbrUpperCap:2048 Video:maxFrameRate:2500
    Video:GovLength:25 Video:keyFrameInterval:1000
    Video:smoothing:1 Video:H265Profile:Main
    SmartCodec:enabled:false SVC:enabled:false
"

REC_IMAGE="
    ImageFlip:enabled:false IrcutFilter:IrcutFilterType:auto
    IrcutFilter:nightToDayFilterLevel:2 IrcutFilter:eventType:IO
    IrcutFilter:IrcutFilterAction:day Exposure:ExposureType:auto
    Exposure:enabled:false powerLineFrequency:powerLineFrequencyMode:50hz
    PTZ:enabled:true FocusConfiguration:focusStyle:SEMIAUTOMATIC
    FocusConfiguration:focusLimited:600 LensInitialization:enabled:false
    DSS:enabled:false DSS:DSSLevel:*2 IrLight:mode:auto
    IrLight:brightnessLimit:100 ZoomLimit:ZoomLimitRatio:25
    Iris:IrisLevel:160 Iris:maxIrisLevelLimit:100
    Iris:minIrisLevelLimit:0 CaptureMode:mode:close
    ImageFreeze:enabled:false proportionalpan:enabled:true
    LaserLight:mode:manual LaserLight:brightnessLevel:0
    LaserLight:laserangle:0 WDR:mode:close
    WDR:WDRLevel:50 BLC:enabled:false
    NoiseReduce:mode:general NoiseReduce:generalLevel:50
    WhiteBalance:WhiteBalanceStyle:auto WhiteBalance:WhiteBalanceRed:50
    WhiteBalance:WhiteBalanceBlue:50 Sharpness:SharpnessLevel:85
    Gain:GainLevel:0 Gain:GainLimit:25
    Shutter:ShutterLevel:1/25 Shutter:maxShutterLevelLimit:1/600
    Shutter:minShutterLevelLimit:1/30000 Color:brightnessLevel:50
    Color:contrastLevel:75 Color:saturationLevel:50
    Dehaze:DehazeMode:close HLC:enabled:false
    HLC:HLCLevel:0 EIS:enabled:false
"

# --- COLORS ---
Color_Off='\033[0m'
BRed='\033[1;31m'
BGreen='\033[1;32m'
BYellow='\033[1;33m'
BBlue='\033[1;34m'
BPurple='\033[1;35m'

print_info() { printf "${BBlue}[INFO]${Color_Off} %b\n" "$1"; }
print_success() { printf "${BGreen}[SUCCESS]${Color_Off} %b\n" "$1"; }
print_warning() { printf "${BYellow}[WARNING]${Color_Off} %b\n" "$1"; }
print_error() { printf "${BRed}[ERROR]${Color_Off} %b\n" "$1"; }
print_action() { printf "${BPurple}[ACTION REQUIRED]${Color_Off} %b\n" "$1"; }

# --- Utility Function: Install Required Tools ---
install_required_tools() {
    local missing_tools=""
    
    # Check which tools are missing
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools="$missing_tools $tool"
        fi
    done
    
    # If no tools are missing, return success
    if [ -z "$missing_tools" ]; then
        return 0
    fi
    
    print_info "Installing missing tools:$missing_tools"
    
    local pkg_update=""
    local pkg_install=""

    if command -v opkg >/dev/null 2>&1; then
        pkg_update="opkg update"
        pkg_install="opkg install"
    elif command -v apt-get >/dev/null 2>&1; then
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            pkg_update="sudo apt-get update"
            pkg_install="sudo apt-get install -y"
        else
            pkg_update="apt-get update"
            pkg_install="apt-get install -y"
        fi
    else
        print_error "No supported package manager (opkg, apt-get) found."
        print_action "Please install manually:$missing_tools"
        return 1
    fi

    # Update package list first
    if ! $pkg_update; then
        print_error "Failed to update package list."
        return 1
    fi
    
    # Install missing tools
    if ! $pkg_install $missing_tools; then
        print_error "Failed to install required tools:$missing_tools"
        print_action "Please install manually: ${BYellow}$pkg_update && $pkg_install$missing_tools${Color_Off}"
        return 1
    fi
    
    print_success "Successfully installed:$missing_tools"
    return 0
}

# --- UTILITY: CURL WRAPPER ---
run_curl() {
    curl -s -m 15 --digest -u "$CAM_USER:$PASS" "$@"
}

# --- UTILITY: XML PARSING ---
get_block_tag_value() {
    local xml="$1"
    local block="$2"
    local tag="$3"
    # [> ] ensures we match tags that might have attributes, like <NTPServer version="2.0"...>
    echo "$xml" | awk "/<$block[> ]/,/<\/$block>/" | grep -o "<$tag>[^<]*" | head -n 1 | cut -d'>' -f2
}

set_xml_value() {
    local file="$1"
    local block="$2"
    local tag="$3"
    local val="$4"

    if [ -z "$block" ]; then
        sed -i "s|<${tag}>[^<]*</${tag}>|<${tag}>${val}</${tag}>|g" "$file"
    else
        awk -v b="$block" -v t="$tag" -v v="$val" '
            BEGIN { found=0; in_block=0 }
            $0 ~ "<" b "[> ]" { in_block=1 }
            $0 ~ "</" b ">" {
                if (in_block && !found) { print "      <" t ">" v "</" t ">" }
                in_block=0
            }
            in_block && $0 ~ "<" t "([> ])" {
                sub(">[^<]*</" t ">", ">" v "</" t ">")
                found=1
            }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# --- PREREQUISITE 0: DNS ---
verify_dns_config() {
    local host="$1"
    local url="http://${host}/ISAPI/System/Network/interfaces/1"
    local tmp_file="/tmp/hik_dns_${host}.xml"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")

        if [ "$http_code" != "200" ]; then
            print_error "Failed to get DNS config from $host (Status: $http_code)"
            return 1
        fi

        local current_p current_s mismatches=0 mismatch_text=""
        current_p=$(get_block_tag_value "$(cat "$tmp_file")" "PrimaryDNS" "ipAddress")
        current_s=$(get_block_tag_value "$(cat "$tmp_file")" "SecondaryDNS" "ipAddress")

        current_p=${current_p:-0.0.0.0}
        current_s=${current_s:-0.0.0.0}

        if [ "$attempt" -eq 1 ]; then
            print_info "Checking DNS: Primary=$current_p, Secondary=$current_s"
        fi

        if [ "$current_p" != "$REC_DNS_PRIMARY" ]; then
            mismatch_text="$mismatch_text\n   - PrimaryDNS: $current_p -> $REC_DNS_PRIMARY"
            set_xml_value "$tmp_file" "PrimaryDNS" "ipAddress" "$REC_DNS_PRIMARY"
            mismatches=$((mismatches+1))
        fi
        if [ "$current_s" != "$REC_DNS_SECONDARY" ]; then
            mismatch_text="$mismatch_text\n   - SecondaryDNS: $current_s -> $REC_DNS_SECONDARY"
            set_xml_value "$tmp_file" "SecondaryDNS" "ipAddress" "$REC_DNS_SECONDARY"
            mismatches=$((mismatches+1))
        fi

        if [ "$mismatches" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then print_success "DNS Configuration is correct."
            else print_success "DNS Configuration updated and verified successfully."
            fi
            return 0
        fi

        if [ "$attempt" -eq 1 ]; then
            print_warning "DNS settings are incorrect. Updating automatically..."
            printf "%b\n" "$mismatch_text"
        else
            print_warning "DNS Verification failed. Re-applying (Attempt $attempt of $max_attempts)..."
            printf "%b\n" "$mismatch_text"
        fi

        local put_code
        put_code=$(run_curl -o /dev/null -w "%{http_code}" -X PUT -d "@$tmp_file" -H "Content-Type: application/xml" "$url")
        if [ "$put_code" != "200" ]; then
            print_error "Failed to update DNS (Status: $put_code)"
            return 1
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to fully apply DNS settings after $max_attempts attempts."
    return 1
}

# --- PREREQUISITE 1: INTEGRATION ---
verify_integration_config() {
    local host="$1"
    local url="http://${host}/ISAPI/System/Network/Integrate"
    local tmp_file="/tmp/hik_integrate_${host}.xml"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")
        if [ "$http_code" != "200" ]; then
            print_error "Failed to get Integration config (Status: $http_code)"
            return 1
        fi

        local mismatches=0 mismatch_text=""
        local cgi_en onvif_en isapi_en
        cgi_en=$(get_block_tag_value "$(cat "$tmp_file")" "CGI" "enable")
        onvif_en=$(get_block_tag_value "$(cat "$tmp_file")" "ONVIF" "enable")
        isapi_en=$(get_block_tag_value "$(cat "$tmp_file")" "ISAPI" "enable")

        if [ "$attempt" -eq 1 ]; then
            print_info "Integration Protocols: CGI=$cgi_en, ONVIF=$onvif_en, ISAPI=$isapi_en"
        fi

        for item in $REC_INTEGRATE; do
            local block="${item%%:*}"
            local rest="${item#*:}"
            local tag="${rest%%:*}"
            local expected="${rest#*:}"

            if ! grep -q "<$block[> ]" "$tmp_file"; then continue; fi

            if [ "$tag" != "enable" ] && ! awk "/<$block[> ]/,/<\/$block>/" "$tmp_file" | grep -q "<$tag[> ]"; then
                continue
            fi

            local actual
            actual=$(get_block_tag_value "$(cat "$tmp_file")" "$block" "$tag")
            if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
                mismatch_text="$mismatch_text\n   - $block/$tag: $actual -> $expected"
                set_xml_value "$tmp_file" "$block" "$tag" "$expected"
                mismatches=$((mismatches+1))
            fi
        done

        if [ "$mismatches" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then print_success "Integration protocols correctly configured."
            else print_success "Integration settings updated and verified successfully."
            fi
            return 0
        fi

        if [ "$attempt" -eq 1 ]; then
            print_warning "Integration settings incorrect. Updating automatically..."
            printf "%b\n" "$mismatch_text"
        else
            print_warning "Integration Verification failed. Re-applying (Attempt $attempt of $max_attempts)..."
            printf "%b\n" "$mismatch_text"
        fi

        local put_code
        put_code=$(run_curl -o /dev/null -w "%{http_code}" -X PUT -d "@$tmp_file" -H "Content-Type: application/xml" "$url")
        if [ "$put_code" != "200" ]; then
            print_error "Failed to update Integration (Status: $put_code)"
            return 1
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to fully apply Integration settings after $max_attempts attempts."
    return 1
}

# --- PREREQUISITE 2: ONVIF USER ---
verify_onvif_user() {
    local host="$1"
    local url="http://${host}/ISAPI/Security/ONVIF/users"
    local tmp_file="/tmp/hik_onvif_${host}.xml"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")

        if [ "$http_code" != "200" ]; then
            if [ "$attempt" -eq 1 ]; then print_info "ONVIF User management not supported or disabled."; fi
            return 0
        fi

        if grep -q "<userType>administrator</userType>" "$tmp_file"; then
            if [ "$attempt" -eq 1 ]; then print_success "ONVIF Administrator exists."
            else print_success "ONVIF Administrator created and verified successfully."
            fi
            return 0
        fi

        if [ "$attempt" -eq 1 ]; then
            print_warning "No ONVIF Administrator found. Creating user '$CAM_USER'..."
        else
            print_warning "ONVIF Verification failed. Retrying (Attempt $attempt of $max_attempts)..."
        fi

        local payload_file="/tmp/hik_onvif_add_${host}.xml"
        cat <<EOF > "$payload_file"
<UserList>
    <User version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <id>0</id>
        <userName>$CAM_USER</userName>
        <password>$PASS</password>
        <userType>administrator</userType>
    </User>
</UserList>
EOF
        local post_code
        post_code=$(run_curl -o /dev/null -w "%{http_code}" -X POST -d "@$payload_file" -H "Content-Type: application/xml" "$url")

        if [ "$post_code" != "200" ]; then
            cat <<EOF > "$payload_file"
<User version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
    <id>0</id>
    <userName>$CAM_USER</userName>
    <password>$PASS</password>
    <userType>administrator</userType>
</User>
EOF
            post_code=$(run_curl -o /dev/null -w "%{http_code}" -X POST -d "@$payload_file" -H "Content-Type: application/xml" "$url")
        fi

        if [ "$post_code" != "200" ]; then
            print_error "Failed to create ONVIF user (Status: $post_code)"
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to create ONVIF user after $max_attempts attempts."
    return 1
}

# --- PREREQUISITE 3: NTP SETTINGS ---
verify_ntp_config() {
    local host="$1"
    local url="http://${host}/ISAPI/System/time/ntpServers/1"
    local tmp_file="/tmp/hik_ntp_${host}.xml"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")

        if [ "$http_code" != "200" ]; then
            print_error "Failed to get NTP config (Status: $http_code)"
            return 1
        fi

        local current_host
        current_host=$(get_block_tag_value "$(cat "$tmp_file")" "NTPServer" "hostName")

        if [ "$attempt" -eq 1 ]; then
            print_info "Checking NTP: Server=$current_host"
        fi

        local mismatches=0 mismatch_text=""

        for item in $REC_NTP; do
            local key="${item%%:*}"
            local expected_val="${item#*:}"
            local actual_val
            actual_val=$(get_block_tag_value "$(cat "$tmp_file")" "NTPServer" "$key")

            if [ -n "$actual_val" ] && [ "$actual_val" != "$expected_val" ]; then
                mismatch_text="$mismatch_text\n   - $key: $actual_val -> $expected_val"
                set_xml_value "$tmp_file" "NTPServer" "$key" "$expected_val"
                mismatches=$((mismatches+1))
            fi
        done

        if [ "$mismatches" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then print_success "NTP Configuration is correct."
            else print_success "NTP Configuration updated and verified successfully."
            fi
            return 0
        fi

        if [ "$attempt" -eq 1 ]; then
            print_warning "NTP Configuration is incorrect. Updating automatically..."
            printf "%b\n" "$mismatch_text"
        else
            print_warning "NTP Verification failed. Re-applying (Attempt $attempt of $max_attempts)..."
            printf "%b\n" "$mismatch_text"
        fi

        local put_code
        put_code=$(run_curl -o /dev/null -w "%{http_code}" -X PUT -d "@$tmp_file" -H "Content-Type: application/xml" "$url")
        if [ "$put_code" != "200" ]; then
            print_error "Failed to update NTP (Status: $put_code)"
            return 1
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to fully apply NTP settings after $max_attempts attempts."
    return 1
}

# --- PREREQUISITE 4: TEST NTP ---
test_ntp_connection() {
    local host="$1"
    print_info "Testing NTP connection..."
    local url="http://${host}/ISAPI/System/time/ntpServers/test"
    local payload="/tmp/hik_ntp_test_${host}.xml"

    local ntp_host="time.windows.com"
    local ntp_port="123"
    local ntp_fmt="hostname"
    
    for item in $REC_NTP; do
        local k="${item%%:*}"
        local v="${item#*:}"
        case "$k" in
            hostName) ntp_host="$v" ;;
            portNo) ntp_port="$v" ;;
            addressingFormatType) ntp_fmt="$v" ;;
        esac
    done
    
    cat <<EOF > "$payload"
<NTPTestDescription version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
    <addressingFormatType>$ntp_fmt</addressingFormatType>
    <hostName>$ntp_host</hostName>
    <portNo>$ntp_port</portNo>
</NTPTestDescription>
EOF

    local resp_file="/tmp/hik_ntp_test_resp_${host}.xml"
    local http_code
    http_code=$(run_curl -o "$resp_file" -w "%{http_code}" -X POST -d "@$payload" -H "Content-Type: application/xml" "$url")
    
    if [ "$http_code" = "200" ]; then
        local err_code
        err_code=$(awk '/<NTPTestResult[> ]/,/<\/NTPTestResult>/' "$resp_file" | grep -o "<errorCode>[^<]*" | head -n 1 | cut -d'>' -f2)
        if [ "$err_code" = "0" ]; then
            print_success "NTP Test Successful."
            return 0
        else
            local desc
            desc=$(awk '/<NTPTestResult[> ]/,/<\/NTPTestResult>/' "$resp_file" | grep -o "<errorDescription>[^<]*" | head -n 1 | cut -d'>' -f2)
            print_error "NTP Test Failed: $desc (Error Code: $err_code)"
            return 1
        fi
    else
        print_error "Failed to test NTP connection (Status: $http_code)"
        return 1
    fi
}

# --- PREREQUISITE 5: SYNC TIME ---
sync_time_and_timezone() {
    local host="$1"
    local url="http://${host}/ISAPI/System/time"
    local tmp_file="/tmp/hik_time_${host}.xml"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")

        if [ "$http_code" != "200" ]; then
            print_error "Failed to get Time config from $host (Status: $http_code)"
            return 1
        fi

        local cur_mode cur_zone mismatches=0 mismatch_text=""
        cur_mode=$(get_block_tag_value "$(cat "$tmp_file")" "Time" "timeMode")
        cur_zone=$(get_block_tag_value "$(cat "$tmp_file")" "Time" "timeZone")

        if [ "$attempt" -eq 1 ]; then
            print_info "Checking Time: Zone=$cur_zone, Mode=$cur_mode"
        fi

        if [ "$cur_mode" != "$REC_TIME_MODE" ]; then
            mismatch_text="$mismatch_text\n   - timeMode: $cur_mode -> $REC_TIME_MODE"
            set_xml_value "$tmp_file" "Time" "timeMode" "$REC_TIME_MODE"
            mismatches=$((mismatches+1))
        fi

        if [ "$cur_zone" != "$REC_TIME_ZONE" ]; then
            mismatch_text="$mismatch_text\n   - timeZone: $cur_zone -> $REC_TIME_ZONE"
            set_xml_value "$tmp_file" "Time" "timeZone" "$REC_TIME_ZONE"
            mismatches=$((mismatches+1))
        fi

        if [ "$mismatches" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then print_success "Time and Timezone are already correct."
            else print_success "Time and Timezone synced and verified successfully."
            fi
            return 0
        fi

        if [ "$attempt" -eq 1 ]; then
            print_warning "Time/Timezone mismatch. Syncing automatically..."
            printf "%b\n" "$mismatch_text"
        else
            print_warning "Time Verification failed. Re-applying (Attempt $attempt of $max_attempts)..."
            printf "%b\n" "$mismatch_text"
        fi

        local put_code
        put_code=$(run_curl -o /dev/null -w "%{http_code}" -X PUT -d "@$tmp_file" -H "Content-Type: application/xml" "$url")
        if [ "$put_code" != "200" ]; then
            print_error "Failed to sync time (Status: $put_code)"
            return 1
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to fully apply Time settings after $max_attempts attempts."
    return 1
}

# --- PREREQUISITE 6: VIDEO SETTINGS ---
verify_video_config() {
    local host="$1"
    local url="http://${host}/ISAPI/Streaming/channels/101"
    local tmp_file="/tmp/hik_video_${host}.xml"
    local max_attempts=5
    local attempt=1
    local user_agreed="false"

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")

        if [ "$http_code" != "200" ]; then
            print_error "Failed to get Video config (Status: $http_code)"
            return 1
        fi

        local w h codec mismatches=0 mismatch_text=""
        w=$(get_block_tag_value "$(cat "$tmp_file")" "Video" "videoResolutionWidth")
        h=$(get_block_tag_value "$(cat "$tmp_file")" "Video" "videoResolutionHeight")
        codec=$(get_block_tag_value "$(cat "$tmp_file")" "Video" "videoCodecType")

        if [ "$attempt" -eq 1 ]; then
            print_info "Checking Video (101): ${w}x${h}, ${codec}"
        fi

        for item in $REC_VIDEO; do
            local block="${item%%:*}"
            local rest="${item#*:}"
            local key="${rest%%:*}"
            local expected_val="${rest#*:}"
            local actual_val

            if [ "$block" = "Video" ]; then
                actual_val=$(get_block_tag_value "$(cat "$tmp_file")" "$block" "$key")
            else
                actual_val=$(awk "/<$block[> ]/,/<\/$block>/" "$tmp_file" | grep -o "<$key>[^<]*" | head -n 1 | cut -d'>' -f2)
            fi

            if [ -n "$actual_val" ] && [ "$actual_val" != "$expected_val" ]; then
                mismatch_text="$mismatch_text\n   - $block/$key: $actual_val -> $expected_val"
                set_xml_value "$tmp_file" "$block" "$key" "$expected_val"
                mismatches=$((mismatches+1))
            fi
        done

        if [ "$mismatches" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then print_success "Video settings (101) are correct."
            else print_success "Video settings (101) updated and verified successfully (Attempt $attempt)."
            fi
            return 0
        fi

        if [ "$user_agreed" = "false" ]; then
            print_warning "Video settings (101) have $mismatches mismatches found."
            printf "%b\n" "$mismatch_text"
            printf "Apply recommended Video settings? (y/n): "
            read -r apply_vid
            apply_vid=$(echo "$apply_vid" | tr '[A-Z]' '[a-z]')
            if [ "$apply_vid" != 'y' ]; then
                print_info "Skipping Video settings update."
                return 0
            fi
            user_agreed="true"
        else
            print_warning "Video Verification failed. $mismatches mismatches remain. Re-applying (Attempt $attempt of $max_attempts)..."
            printf "%b\n" "$mismatch_text"
        fi

        local put_resp="/tmp/hik_video_put_${host}.xml"
        local put_code
        put_code=$(run_curl -o "$put_resp" -w "%{http_code}" -X PUT -d "@$tmp_file" -H "Content-Type: application/xml" "$url")

        if [ "$put_code" = "200" ]; then
            if grep -q "<subStatusCode>rebootRequired</subStatusCode>" "$put_resp"; then
                print_warning "Reboot Required to apply these video settings."
                printf "Reboot camera now? (y/n): "
                read -r reboot_cam
                reboot_cam=$(echo "$reboot_cam" | tr '[A-Z]' '[a-z]')
                if [ "$reboot_cam" = 'y' ]; then
                    run_curl -X PUT -H "Content-Type: application/xml" "http://${host}/ISAPI/System/reboot" >/dev/null
                    print_success "Reboot command sent. Please wait 1-2 minutes."
                    return 1
                fi
                return 0
            fi
        else
            print_error "Failed to update video settings (Status: $put_code)"
            return 1
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to fully apply Video settings after $max_attempts attempts."
    return 1
}

# --- PREREQUISITE 7: IMAGE SETTINGS ---
verify_image_config() {
    local host="$1"
    local url="http://${host}/ISAPI/Image/channels/1"
    local tmp_file="/tmp/hik_image_${host}.xml"
    local max_attempts=5
    local attempt=1
    local user_agreed="false"

    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(run_curl -o "$tmp_file" -w "%{http_code}" "$url")

        if [ "$http_code" != "200" ]; then
            print_error "Failed to get Image config (Status: $http_code)"
            return 1
        fi

        if [ "$attempt" -eq 1 ]; then
            print_info "Checking Image Settings (1)..."
        fi

        local ircut_expected="2"
        if awk "/<IrcutFilter[> ]/,/<\/IrcutFilter>/" "$tmp_file" | grep -q "<EventTrigger[> ]"; then
            ircut_expected="4"
        fi

        local mismatches=0 mismatch_text=""
        local blocks_to_update=""

        for item in $REC_IMAGE; do
            local block="${item%%:*}"
            local rest="${item#*:}"
            local tag="${rest%%:*}"
            local expected="${rest#*:}"

            if [ "$block" = "IrcutFilter" ] && [ "$tag" = "nightToDayFilterLevel" ]; then
                expected="$ircut_expected"
            fi

            if ! grep -q "<$block[> ]" "$tmp_file"; then continue; fi
            if ! awk "/<$block[> ]/,/<\/$block>/" "$tmp_file" | grep -q "<$tag[> ]"; then continue; fi

            local actual
            actual=$(awk "/<$block[> ]/,/<\/$block>/" "$tmp_file" | grep -o "<$tag>[^<]*" | head -n 1 | cut -d'>' -f2)

            if [ "$actual" != "$expected" ]; then
                mismatch_text="$mismatch_text\n   - $block/$tag: ${actual:-[missing]} -> $expected"
                mismatches=$((mismatches+1))
                if ! echo " $blocks_to_update " | grep -q " $block "; then
                    blocks_to_update="$blocks_to_update $block"
                fi
            fi
        done

        if [ "$mismatches" -eq 0 ]; then
            if [ "$attempt" -eq 1 ]; then print_success "Image settings (1) are correct."
            else print_success "Image settings (1) updated and verified successfully."
            fi
            return 0
        fi

        if [ "$user_agreed" = "false" ]; then
            print_warning "Image settings (1) have $mismatches mismatches found."
            printf "%b\n" "$mismatch_text"
            printf "Apply recommended Image settings? (y/n): "
            read -r apply_img
            apply_img=$(echo "$apply_img" | tr '[A-Z]' '[a-z]')
            if [ "$apply_img" != 'y' ]; then
                print_info "Skipping Image settings update."
                return 0
            fi
            user_agreed="true"
        else
            print_warning "Image Verification failed. $mismatches mismatches remain. Re-applying (Attempt $attempt of $max_attempts)..."
            printf "%b\n" "$mismatch_text"
        fi

        local success="true"
        for block in $blocks_to_update; do
            local payload_file="/tmp/hik_update_${block}_${host}.xml"
            awk "/<$block[> ]/,/<\/$block>/" "$tmp_file" > "$payload_file"

            if ! grep -q 'xmlns="http://www.hikvision.com/ver20/XMLSchema"' "$payload_file"; then
                sed -i "s|<$block>|<$block version=\"2.0\" xmlns=\"http://www.hikvision.com/ver20/XMLSchema\">|" "$payload_file"
            fi

            for item in $REC_IMAGE; do
                local i_block="${item%%:*}"
                local rest="${item#*:}"
                local i_tag="${rest%%:*}"
                local i_expected="${rest#*:}"
                if [ "$i_block" = "$block" ]; then
                    if [ "$i_block" = "IrcutFilter" ] && [ "$i_tag" = "nightToDayFilterLevel" ]; then
                        i_expected="$ircut_expected"
                    fi

                    if grep -q "<$i_tag[> ]" "$payload_file"; then
                        set_xml_value "$payload_file" "" "$i_tag" "$i_expected"
                    fi
                fi
            done

            local first_char rest_chars endpoint_key
            first_char=$(printf '%s' "$block" | cut -c 1 | tr '[A-Z]' '[a-z]')
            rest_chars=$(printf '%s' "$block" | cut -c 2-)

            case "$block" in
                WDR|BLC|PTZ|HLC|EIS|DSS) endpoint_key="$block" ;;
                *) endpoint_key="${first_char}${rest_chars}" ;;
            esac

            local sub_url="http://${host}/ISAPI/Image/channels/1/${endpoint_key}"
            local put_code
            put_code=$(run_curl -o /dev/null -w "%{http_code}" -X PUT -d "@$payload_file" -H "Content-Type: application/xml" "$sub_url")

            if [ "$put_code" != "200" ]; then
                local sub_url_exact="http://${host}/ISAPI/Image/channels/1/${block}"
                put_code=$(run_curl -o /dev/null -w "%{http_code}" -X PUT -d "@$payload_file" -H "Content-Type: application/xml" "$sub_url_exact")
                if [ "$put_code" != "200" ]; then
                    print_error "Failed to update $block (Status: $put_code)"
                    success="false"
                fi
            fi
        done

        if [ "$success" = "false" ]; then
            print_error "Some Image settings failed to apply."
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    print_error "Failed to fully apply Image settings after $max_attempts attempts."
    return 1
}

# --- NETWORK DISCOVERY ---
run_sadp_discovery() {
    local uuid probe scan_res
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "11112222-3333-4444-5555-666677778888")
    uuid=$(echo "$uuid" | tr '[a-z]' '[A-Z]')
    probe="<?xml version=\"1.0\" encoding=\"utf-8\"?><Probe><Uuid>${uuid}</Uuid><Types>inquiry</Types></Probe>"

    if command -v socat >/dev/null 2>&1; then
        print_info "Scanning network using SADP (socat)..."
        
        # Check if we are on a router with br-lan to ensure we scan the correct interface
        local socat_opts_base="broadcast,sp=37020"
        local socat_opts="$socat_opts_base"
        if [ -d "/sys/class/net/br-lan" ]; then
            socat_opts="${socat_opts},so-bindtodevice=br-lan"
            print_info "Routing issue detected: Binding discovery to 'br-lan' interface."
        fi

        local stderr_log="/tmp/socat_err.log"
        scan_res=$(echo "$probe" | socat -T 5 -t 5 - UDP-DATAGRAM:239.255.255.250:37020,${socat_opts} 2>"$stderr_log")

        # Fallback if so-bindtodevice is unsupported on this socat build (e.g. OpenWrt minimal builds)
        if [ -z "$scan_res" ] && grep -qiE "unknown option|not found|unrecognized" "$stderr_log" && [ "$socat_opts" != "$socat_opts_base" ]; then
            print_warning "Interface binding unsupported by this socat. Retrying without binding..."
            scan_res=$(echo "$probe" | socat -T 5 -t 5 - UDP-DATAGRAM:239.255.255.250:37020,${socat_opts_base} 2>"$stderr_log")
        fi

        # If we failed to get a response and a command threw an error, output it for debugging
        if [ -z "$scan_res" ] && [ -s "$stderr_log" ]; then
            local err_msg
            err_msg=$(head -n 2 "$stderr_log" | tr '\n' ' ' | sed 's/ *$//')
            if [ -n "$err_msg" ]; then
                print_info "SADP Debug: $err_msg"
            fi
        fi
    else
        print_warning "SADP Discovery requires 'socat'. Skipping network scan."
        return 1
    fi

    > /tmp/sadp_results.txt
    if [ -n "$scan_res" ]; then
        echo "$scan_res" | awk -F'[<>]' '
            /<ProbeMatch/ { in_probe=1; mac=""; ip=""; type=""; status=""; port=""; ver="" }
            /<\/ProbeMatch>/ {
                if (ip != "" && !seen[mac]) {
                    seen[mac]=1; print ip "\t" mac "\t" type "\t" status "\t" port "\t" ver
                }
                in_probe=0
            }
            in_probe && /<MAC>/ { mac=$3; gsub(/-/, ":", mac); mac=toupper(mac) }
            in_probe && /<IPv4Address>/ { ip=$3 }
            in_probe && /<DeviceType>/ { type=$3 }
            in_probe && /<Activated>/ { status=($3=="true"?"Active":"Inactive") }
            in_probe && /<CommandPort>/ { port=$3 }
            in_probe && /<SoftwareVersion>/ { ver=$3 }' > /tmp/sadp_results.txt

        awk -F'\t' '{print "[SUCCESS] Discovered: " $1 " - " $2 " (" $3 ")"}' /tmp/sadp_results.txt | while read -r line; do
            printf "${BGreen}%s${Color_Off}\n" "$line"
        done
    fi
}

# --- CLEANUP TRAP ---
cleanup() {
    rm -f /tmp/hik_*.xml /tmp/sadp_results.txt /tmp/socat_err.log
}
trap cleanup EXIT

main() {
    # Restrict temp file permissions (owner-only read/write)
    umask 077

    print_info "Starting Hikvision Camera Setup & Sanity Check..."

    # Ensure essential tools are installed (socat for discovery, curl for ISAPI)
    install_required_tools socat curl

    if [ -z "$PASS" ]; then
        printf "Enter Camera Password: "
        stty -echo
        read -r PASS
        stty echo
        printf "\n"
    fi

    run_sadp_discovery

    local target_ips=""
    local default_str="$DEFAULT_TARGETS"
    local found_count=0
    if [ -f /tmp/sadp_results.txt ]; then
        found_count=$(wc -l < /tmp/sadp_results.txt)
        found_count=$((found_count + 0))
    fi

    if [ "$found_count" -eq 0 ]; then
        print_warning "No devices discovered on the network."
        printf "Use configured default targets (%s)? (y/n): " "$default_str"
        read -r use_def
        use_def=$(echo "$use_def" | tr '[A-Z]' '[a-z]')
        if [ "$use_def" = 'y' ]; then
            target_ips="$DEFAULT_TARGETS"
        fi
    else
        printf "\nTotal discovered: %d\n" "$found_count"
        echo "--------------------------------------------------------------------------------------------------------------"
        printf "%-6s %-15s %-18s %-20s %-8s %-6s %s\n" "Index" "IPv4 Address" "MAC Address" "Device Type" "Status" "Port" "Software Version"
        echo "--------------------------------------------------------------------------------------------------------------"
        awk -F'\t' '{printf "%-6d %-15s %-18s %-20s %-8s %-6s %s\n", NR, $1, $2, $3, $4, $5, $6}' /tmp/sadp_results.txt
        echo
        printf "Enter index, 'all' for all active, or 'skip' for defaults (%s): " "$default_str"
        read -r choice
        
        choice=$(echo "$choice" | tr '[A-Z]' '[a-z]' | awk '{$1=$1;print}')
        if [ "$choice" = "all" ]; then
            target_ips=$(awk -F'\t' '$4=="Active" {print $1}' /tmp/sadp_results.txt | tr '\n' ' ')
        elif echo "$choice" | grep -Eq '^[0-9]+$'; then
            if [ "$choice" -ge 1 ] && [ "$choice" -le "$found_count" ]; then
                target_ips=$(sed -n "${choice}p" /tmp/sadp_results.txt | awk -F'\t' '{print $1}')
            fi
        elif [ "$choice" = "skip" ] || [ -z "$choice" ]; then
            target_ips="$DEFAULT_TARGETS"
        else
            print_warning "Invalid choice. Defaulting to configured targets."
            target_ips="$DEFAULT_TARGETS"
        fi
    fi

    if [ -z "$target_ips" ]; then
        print_info "No targets selected. Exiting."
        exit 0
    fi

    for target in $target_ips; do
        echo
        echo "============================================================"
        echo "Starting sanity check for $target"
        echo "============================================================"
        
        verify_dns_config "$target" || continue
        verify_integration_config "$target" || continue
        verify_onvif_user "$target" || continue
        verify_ntp_config "$target" || continue
        test_ntp_connection "$target" || continue
        sync_time_and_timezone "$target"
        verify_video_config "$target" || continue
        verify_image_config "$target" || continue
        
        print_success "CAMERA COMPLIANCE CHECK COMPLETE FOR $target."
    done
}

main