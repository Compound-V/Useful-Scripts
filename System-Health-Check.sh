#!/bin/bash

# Enhanced Universal System Health Check v5.0
# Comprehensive Hardware & Software Diagnostics with Root Cause Analysis
# Compatible with Debian-based systems

# Color definitions with fallback

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m' 
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly PURPLE='\033[0;35m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly NC='\033[0m'
    readonly CHECK="✓"
    readonly CROSS="✗"
    readonly WARN="⚠"
    readonly INFO="ℹ"
    readonly FIX="🔧"
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' PURPLE='' BOLD='' DIM='' NC=''
    readonly CHECK="[OK]" CROSS="[FAIL]" WARN="[WARN]" INFO="[INFO]" FIX="[FIX]"
fi

# Global tracking variables
declare -i TOTAL_TESTS=0 PASSED_TESTS=0 FAILED_TESTS=0 WARNING_TESTS=0 SKIPPED_TESTS=0
declare -a CRITICAL_ISSUES=() HIGH_ISSUES=() MEDIUM_ISSUES=() INFO_ITEMS=() DETAILED_ERRORS=()
declare -A TEST_RESULTS=() FIX_SUGGESTIONS=() HARDWARE_INFO=()
readonly START_TIME=$(date +%s)

# Hardware database for driver recommendations
declare -A HARDWARE_DRIVERS=(
    # Bluetooth hardware
    ["8087:0025"]="firmware-iwlwifi bluez-firmware"
    ["8087:0026"]="firmware-iwlwifi bluez-firmware"  
    ["8087:0029"]="firmware-iwlwifi bluez-firmware"
    ["04ca:3015"]="firmware-brcm80211"
    ["0cf3:e007"]="firmware-atheros"
    ["13d3:3491"]="firmware-atheros"
    
    # WiFi hardware
    ["8086:24f3"]="firmware-iwlwifi"
    ["8086:095a"]="firmware-iwlwifi"
    ["10ec:b822"]="firmware-realtek"
    ["10ec:c821"]="firmware-realtek"
    ["14e4:43a0"]="firmware-brcm80211"
    ["14e4:4328"]="firmware-brcm80211"
    
    # Audio hardware
    ["8086:9d70"]="alsa-firmware-loaders"
    ["8086:a170"]="alsa-firmware-loaders"
    ["10de:0e0f"]="alsa-base"
    ["1022:1457"]="alsa-base"
    
    # Graphics hardware  
    ["8086:9bca"]="firmware-misc-nonfree"
    ["1002:15dd"]="firmware-amd-graphics"
    ["10de:1c03"]="nvidia-driver firmware-misc-nonfree"
    
    # Touchpad/Input
    ["04f3:0c4b"]="xserver-xorg-input-synaptics"
    ["1267:0017"]="xserver-xorg-input-elantech"
    
    # Ethernet hardware
    ["1969:e091"]="firmware-atheros"
    ["14e4:1686"]="firmware-brcm80211"
    ["10ec:8168"]="firmware-realtek"
)

# Common error patterns and fixes
declare -A ERROR_PATTERNS=(
    ["Bluetooth.*Reading supported features failed"]="bluetooth_features_failed"
    ["Bluetooth.*SCO.*failed"]="bluetooth_sco_failed"
    ["hci.*timeout"]="bluetooth_hci_timeout"
    ["snd_hda_intel.*spurious response"]="audio_spurious_response"
    ["i2c_hid_acpi.*incorrect report"]="touchpad_hid_error"
    ["iwlwifi.*firmware.*failed"]="wifi_firmware_failed"
    ["i915.*GPU.*hung"]="gpu_hang"
    ["ata.*failed command"]="storage_ata_error"
    ["usb.*device descriptor read.*error"]="usb_device_error"
    ["thermal.*throttling"]="thermal_throttling"
    ["CPU.*over temperature"]="cpu_overheat"
    ["oom-killer"]="memory_oom"
    ["journal has been rotated"]="journal_rotated"
    ["Failed to start.*service"]="service_start_failed"
    ["mount.*unknown filesystem type"]="filesystem_error"
)

# Debian package alternatives for common issues
declare -A DEBIAN_FIX_PACKAGES=(
    ["broadcom-wifi"]="firmware-brcm80211 broadcom-sta-dkms"
    ["intel-wifi"]="firmware-iwlwifi"
    ["realtek-wifi"]="firmware-realtek"
    ["nvidia-graphics"]="nvidia-driver nvidia-settings"
    ["amd-graphics"]="firmware-amd-graphics"
    ["bluetooth"]="bluez-firmware bluetooth"
    ["audio"]="alsa-base alsa-utils pulseaudio"
    ["printer"]="printer-driver-all cups"
    ["scanner"]="sane-airscan sane-utils"
    ["touchpad"]="xserver-xorg-input-synaptics xserver-xorg-input-libinput"
)

# Helper functions
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ $EUID -eq 0 ]]; }
safe_timeout() { timeout "${1:-10}" "${@:2}" 2>/dev/null || return 1; }
safe_calc() { awk "BEGIN {printf \"%.1f\", $1}" 2>/dev/null || echo "0"; }
sanitize_output() {
    echo "$1" | tr -d '[:space:]' | grep -oE '[0-9]*'
}
log_result() {
    local status="$1" category="$2" test_name="$3" message="$4" priority="${5:-medium}" details="${6:-}"
    
    TEST_RESULTS["$category::$test_name"]="$status::$message::$priority"
    ((TOTAL_TESTS++))
    
    case "$status" in
        "PASS") 
            ((PASSED_TESTS++))
            [[ "$priority" == "info" ]] && INFO_ITEMS+=("$category: $message")
            ;;
        "FAIL") 
            ((FAILED_TESTS++))
            case "$priority" in
                "critical") CRITICAL_ISSUES+=("$category: $message") ;;
                "high") HIGH_ISSUES+=("$category: $message") ;;
                *) MEDIUM_ISSUES+=("$category: $message") ;;
            esac
            [[ -n "$details" ]] && DETAILED_ERRORS+=("$category: $test_name - $details")
            ;;
        "WARN") 
            ((WARNING_TESTS++))
            case "$priority" in
                "high") HIGH_ISSUES+=("$category: $message") ;;
                *) MEDIUM_ISSUES+=("$category: $message") ;;
            esac
            [[ -n "$details" ]] && DETAILED_ERRORS+=("$category: $test_name - $details")
            ;;
        "SKIP") ((SKIPPED_TESTS++)) ;;
    esac
}

print_test_result() {
    local status="$1" test_name="$2" result="$3" details="$4" fix_key="${5:-}"
    local icon color
    
    case "$status" in
        "PASS") icon="${GREEN}${CHECK}${NC}" ;;
        "FAIL") icon="${RED}${CROSS}${NC}" ;;
        "WARN") icon="${YELLOW}${WARN}${NC}" ;;
        "SKIP") icon="${DIM}${INFO}${NC}" ;;
        *) icon="${CYAN}${INFO}${NC}" ;;
    esac
    
    printf "  %b %-40s %b\n" "$icon" "$test_name" "$result"
    [[ -n "$details" ]] && printf "    %b${DIM}%s${NC}\n" "" "$details"
    
    if [[ -n "$fix_key" && -n "${FIX_SUGGESTIONS[$fix_key]}" ]]; then
        printf "    %b${CYAN}${FIX} Fix: %s${NC}\n" "" "${FIX_SUGGESTIONS[$fix_key]}"
    fi
}

print_section_header() {
    local title="$1" description="$2"
    echo
    printf "${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$title"
    [[ -n "$description" ]] && printf "${DIM}%s${NC}\n" "$description"
    echo
}

print_main_header() {
    local hostname kernel os_info current_user timestamp
    hostname=$(hostname 2>/dev/null || echo "unknown")
    kernel=$(uname -sr 2>/dev/null || echo "unknown")
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown Linux")
    current_user=$(whoami 2>/dev/null || echo "unknown")
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
    
    echo
    printf "${BOLD}${PURPLE}╭─────────────────────────────────────────────────────────╮${NC}\n"
    printf "${BOLD}${PURPLE}│${NC}         ${BOLD}COMPREHENSIVE SYSTEM HEALTH CHECK v5.0${NC}          ${BOLD}${PURPLE}│${NC}\n"
    printf "${BOLD}${PURPLE}╰─────────────────────────────────────────────────────────╯${NC}\n"
    echo
    printf "${BOLD}System Information:${NC}\n"
    printf "  Host: %s\n" "$hostname"
    printf "  OS: %s\n" "$os_info"
    printf "  Kernel: %s\n" "$kernel" 
    printf "  User: %s | Scan Time: %s\n" "$current_user" "$timestamp"
    echo
    
    if [[ $EUID -ne 0 ]]; then
        printf "${YELLOW}${WARN} Running in user mode. Some checks require sudo for full analysis.${NC}\n"
        echo
    else
        printf "${GREEN}${CHECK} Running with administrative privileges.${NC}\n"
        echo
    fi
}

detect_hardware() {
    local hw_type="$1"
    local hw_info=""
    
    case "$hw_type" in
        "bluetooth")
            if command_exists lsusb; then
                hw_info=$(lsusb 2>/dev/null | grep -iE "(bluetooth|bt)" | head -3)
            fi
            if [[ -z "$hw_info" ]] && command_exists lspci; then
                hw_info=$(lspci 2>/dev/null | grep -iE "(bluetooth|bt)" | head -3)
            fi
            ;;
        "wifi")
            if command_exists lspci; then
                hw_info=$(lspci 2>/dev/null | grep -iE "(wireless|wifi|802\.11|network)" | head -3)
            fi
            ;;
        "audio")
            if command_exists lspci; then
                hw_info=$(lspci 2>/dev/null | grep -iE "(audio|sound)" | head -3)
            fi
            ;;
        "touchpad")
            if command_exists xinput; then
                hw_info=$(xinput list 2>/dev/null | grep -iE "(touchpad|synaptics|elan)" | head -3)
            fi
            ;;
        "gpu")
            if command_exists lspci; then
                hw_info=$(lspci 2>/dev/null | grep -iE "(vga|3d|display)" | head -3)
            fi
            ;;
        "storage")
            if command_exists lsblk; then
                hw_info=$(lsblk -d -o NAME,MODEL,SIZE,ROTA 2>/dev/null | grep -v "NAME" | head -5)
            fi
            ;;
    esac
    
    HARDWARE_INFO["$hw_type"]="$hw_info"
    echo "$hw_info"
}

get_hardware_ids() {
    local hw_type="$1"
    local ids=""
    
    case "$hw_type" in
        "bluetooth"|"wifi"|"audio"|"gpu")
            if command_exists lspci; then
                ids=$(lspci -nn 2>/dev/null | grep -iE "$hw_type" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tr -d '[]' | head -3)
            fi
            if [[ -z "$ids" ]] && command_exists lsusb; then
                ids=$(lsusb 2>/dev/null | grep -iE "$hw_type" | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}' | head -3)
            fi
            ;;
    esac
    
    echo "$ids"
}

analyze_error_pattern() {
    local error_text="$1"
    local category="$2"
    local fixes=""
    
    for pattern in "${!ERROR_PATTERNS[@]}"; do
        if echo "$error_text" | grep -qE "$pattern"; then
            case "${ERROR_PATTERNS[$pattern]}" in
                "bluetooth_features_failed")
                    local bt_hw bt_ids
                    bt_hw=$(detect_hardware "bluetooth")
                    bt_ids=$(get_hardware_ids "bluetooth")
                    fixes="Root Cause: Bluetooth controller firmware/driver issue"$'\n'
                    fixes+="Hardware Detected: $bt_hw"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Update Bluetooth firmware: sudo apt install bluez-firmware"$'\n'
                    fixes+="2. Reset Bluetooth: sudo systemctl restart bluetooth"$'\n'
                    fixes+="3. Reinstall Bluetooth stack: sudo apt install --reinstall bluez"$'\n'
                    
                    if [[ -n "$bt_ids" ]]; then
                        for id in $bt_ids; do
                            if [[ -n "${HARDWARE_DRIVERS[$id]}" ]]; then
                                fixes+="4. Install specific driver: sudo apt install ${HARDWARE_DRIVERS[$id]}"$'\n'
                            fi
                        done
                    fi
                    fixes+="5. Add kernel parameter: btusb.enable_autosuspend=0 to GRUB"
                    ;;
                    
                "touchpad_hid_error")
                    local tp_hw
                    tp_hw=$(detect_hardware "touchpad")
                    fixes="Root Cause: I2C HID touchpad communication error"$'\n'
                    fixes+="Hardware: $tp_hw"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Install HID drivers: sudo apt install xserver-xorg-input-synaptics"$'\n'
                    fixes+="2. Update kernel: sudo apt upgrade linux-generic"$'\n'
                    fixes+="3. Add kernel parameter: i2c_hid.use_polling_mode=1 to GRUB"$'\n'
                    fixes+="4. Check BIOS settings: Disable 'Fast Boot' and enable 'Legacy USB'"
                    ;;
                    
                "audio_spurious_response")
                    local audio_hw
                    audio_hw=$(detect_hardware "audio")
                    fixes="Root Cause: Audio codec communication timeout/error"$'\n'
                    fixes+="Hardware: $audio_hw"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Install audio firmware: sudo apt install alsa-firmware-loaders"$'\n'
                    fixes+="2. Reset audio: sudo alsa force-reload"$'\n'
                    fixes+="3. Add model parameter to /etc/modprobe.d/alsa-base.conf"$'\n'
                    fixes+="   options snd-hda-intel model=auto"
                    ;;
                    
                "wifi_firmware_failed")
                    local wifi_hw wifi_ids
                    wifi_hw=$(detect_hardware "wifi")
                    wifi_ids=$(get_hardware_ids "wifi")
                    fixes="Root Cause: WiFi firmware missing or incompatible"$'\n'
                    fixes+="Hardware Detected: $wifi_hw"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Install WiFi firmware: sudo apt install firmware-iwlwifi firmware-realtek"$'\n'
                    fixes+="2. Check kernel modules: sudo modprobe -r iwlwifi && sudo modprobe iwlwifi"$'\n'
                    
                    if [[ -n "$wifi_ids" ]]; then
                        for id in $wifi_ids; do
                            if [[ -n "${HARDWARE_DRIVERS[$id]}" ]]; then
                                fixes+="3. Install specific driver: sudo apt install ${HARDWARE_DRIVERS[$id]}"$'\n'
                            fi
                        done
                    fi
                    fixes+="4. Check: dmesg | grep -i firmware for specific errors"
                    ;;
                    
                "storage_ata_error")
                    local storage_hw
                    storage_hw=$(detect_hardware "storage")
                    fixes="Root Cause: Storage device communication error"$'\n'
                    fixes+="Hardware: $storage_hw"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Check cables and connections"$'\n'
                    fixes+="2. Update storage controller drivers"$'\n'
                    fixes+="3. Check disk health: sudo smartctl -a /dev/sdX"$'\n'
                    fixes+="4. Backup data immediately if disk is failing"$'\n'
                    fixes+="5. Check kernel parameters: add libata.force=noncq to GRUB"
                    ;;
                    
                "thermal_throttling"|"cpu_overheat")
                    fixes="Root Cause: CPU overheating leading to performance throttling"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Clean dust from heatsinks and fans"$'\n'
                    fixes+="2. Improve case ventilation"$'\n'
                    fixes+="3. Replace thermal paste on CPU"$'\n'
                    fixes+="4. Check fan operation and replace if necessary"$'\n'
                    fixes+="5. Adjust power settings: sudo apt install cpufrequtils"$'\n'
                    fixes+="6. Monitor temperatures: sudo apt install lm-sensors && sudo sensors-detect"
                    ;;
                    
                "memory_oom")
                    fixes="Root Cause: Out of Memory condition - system ran out of RAM and swap"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Add more physical RAM if possible"$'\n'
                    fixes+="2. Increase swap space: sudo fallocate -l 2G /swapfile"$'\n'
                    fixes+="3. Identify memory-hog processes: ps aux --sort=-%mem | head -10"$'\n'
                    fixes+="4. Adjust swappiness: echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf"$'\n'
                    fixes+="5. Check for memory leaks in applications"
                    ;;
                    
                *)
                    fixes="Generic hardware/driver issue detected"$'\n'
                    fixes+="1. Update system: sudo apt update && sudo apt full-upgrade"$'\n'
                    fixes+="2. Check hardware: lspci -v"$'\n'
                    fixes+="3. Review kernel logs: dmesg | grep -i error"$'\n'
                    fixes+="4. Install firmware: sudo apt install firmware-misc-nonfree"$'\n'
                    fixes+="5. Check Debian documentation for specific hardware"
                    ;;
            esac
            break
        fi
    done
    
    [[ -z "$fixes" ]] && fixes="No specific fix pattern matched. Check hardware compatibility."
    echo "$fixes"
}

run_boot_hardware_tests() {
    print_section_header "BOOT & HARDWARE ANALYSIS" "Deep hardware analysis with driver recommendations"
    
    local test_name="Boot Error Analysis"
    if command_exists dmesg; then
        local boot_errors error_details
        
        if dmesg -T --level=err,crit,emerg >/dev/null 2>&1; then
            error_details=$(dmesg -T --level=err,crit,emerg 2>/dev/null | tail -10)
        else
            error_details=$(dmesg 2>/dev/null | grep -iE "(error|critical|emergency|panic|failed|fatal)" | tail -10)
        fi
        
        boot_errors=$(echo "$error_details" | wc -l)
        
        if [[ ${boot_errors:-0} -eq 0 ]]; then
            log_result "PASS" "Hardware" "$test_name" "No critical boot errors detected"
            print_test_result "PASS" "$test_name" "Clean boot sequence"
        else
            local fix_recommendations=""
            
            if echo "$error_details" | grep -qiE "bluetooth.*reading supported features failed"; then
                fix_recommendations+="Bluetooth controller issue detected. "
                FIX_SUGGESTIONS["bluetooth_fix"]=$(analyze_error_pattern "$error_details" "bluetooth")
            fi
            
            if echo "$error_details" | grep -qiE "i2c_hid.*incorrect report"; then
                fix_recommendations+="Touchpad I2C communication error. "
                FIX_SUGGESTIONS["touchpad_fix"]=$(analyze_error_pattern "$error_details" "touchpad")
            fi
            
            if echo "$error_details" | grep -qiE "snd_hda|audio|alsa"; then
                fix_recommendations+="Audio subsystem errors detected. "
                FIX_SUGGESTIONS["audio_fix"]=$(analyze_error_pattern "$error_details" "audio")
            fi
            
            if echo "$error_details" | grep -qiE "iwlwifi.*firmware"; then
                fix_recommendations+="WiFi firmware issues detected. "
                FIX_SUGGESTIONS["wifi_fix"]=$(analyze_error_pattern "$error_details" "wifi")
            fi
            
            log_result "FAIL" "Hardware" "$test_name" "$boot_errors hardware errors with driver issues" "high" "$error_details"
            print_test_result "FAIL" "$test_name" "$boot_errors critical errors found" "Hardware compatibility issues detected"
            
            echo "    ${BOLD}${RED}ERROR ANALYSIS:${NC}"
            echo "$error_details" | head -3 | while read -r line; do
                [[ -n "$line" ]] && printf "      ${DIM}→ %s${NC}\n" "$line"
            done
            
            if [[ -n "$fix_recommendations" ]]; then
                echo "    ${BOLD}${CYAN}${FIX} RECOMMENDED ACTIONS:${NC}"
                printf "      ${CYAN}%s${NC}\n" "$fix_recommendations"
            fi
        fi
    else
        log_result "SKIP" "Hardware" "$test_name" "dmesg command not available"
        print_test_result "SKIP" "$test_name" "Unable to check boot messages"
    fi
    
    # Hardware detection
    local test_name="Hardware Compatibility"
    if command_exists lspci || command_exists lsusb; then
        echo "    ${BOLD}${BLUE}HARDWARE DETECTED:${NC}"
        
        # Detect various hardware types
        local hw_types=("wifi" "bluetooth" "audio" "gpu" "storage")
        for hw_type in "${hw_types[@]}"; do
            local hw_info
            hw_info=$(detect_hardware "$hw_type")
            if [[ -n "$hw_info" ]]; then
                printf "    ${CYAN}%s:${NC}\n" "${hw_type^}"
                echo "$hw_info" | while read -r line; do
                    printf "      ${DIM}→ %s${NC}\n" "$line"
                    # Extract hardware IDs for driver recommendations
                    if [[ "$hw_type" != "storage" ]]; then
                        local hw_ids
                        hw_ids=$(get_hardware_ids "$hw_type")
                        for id in $hw_ids; do
                            if [[ -n "${HARDWARE_DRIVERS[$id]}" ]]; then
                                printf "        ${GREEN}${FIX} Recommended driver: %s${NC}\n" "${HARDWARE_DRIVERS[$id]}"
                                FIX_SUGGESTIONS["${hw_type}_driver"]="Install drivers: sudo apt install ${HARDWARE_DRIVERS[$id]}"
                            fi
                        done
                    fi
                done
            fi
        done
        
        log_result "PASS" "Hardware" "$test_name" "Hardware inventory completed" "info"
        print_test_result "PASS" "$test_name" "Hardware catalog available"
    fi
    
    # Memory analysis
    local test_name="Memory Usage"
    if [[ -r /proc/meminfo ]]; then
        local mem_total mem_available mem_used_percent mem_total_gb
        mem_total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
        mem_available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
        
        if [[ -n "$mem_total" && -n "$mem_available" ]]; then
            mem_used_percent=$(safe_calc "(($mem_total - $mem_available) / $mem_total) * 100")
            mem_total_gb=$(safe_calc "$mem_total / 1024 / 1024")
            
            if (( $(awk "BEGIN {print ($mem_used_percent > 90)}") )); then
                FIX_SUGGESTIONS["memory_fix"]="Critical memory usage. 1) Close programs 2) Add swap: sudo fallocate -l 2G /swapfile 3) Check leaks: ps aux --sort=-%mem | head -10"
                log_result "FAIL" "Hardware" "$test_name" "Critical memory usage: ${mem_used_percent}%" "critical"
                print_test_result "FAIL" "$test_name" "${mem_used_percent}% used (CRITICAL)" "Total: ${mem_total_gb}GB" "memory_fix"
            elif (( $(awk "BEGIN {print ($mem_used_percent > 75)}") )); then
                FIX_SUGGESTIONS["memory_warn"]="High memory usage. Close unused apps or check: htop"
                log_result "WARN" "Hardware" "$test_name" "High memory usage: ${mem_used_percent}%" "medium"
                print_test_result "WARN" "$test_name" "${mem_used_percent}% used (High)" "Total: ${mem_total_gb}GB" "memory_warn"
            else
                log_result "PASS" "Hardware" "$test_name" "Memory usage: ${mem_used_percent}% of ${mem_total_gb}GB" "info"
                print_test_result "PASS" "$test_name" "${mem_used_percent}% used" "Total: ${mem_total_gb}GB available"
            fi
        fi
    fi
    
    # CPU load analysis
    local test_name="CPU Load"
    if [[ -r /proc/loadavg ]]; then
        local load_1min cpu_cores load_percent
        load_1min=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
        cpu_cores=$(nproc 2>/dev/null || echo "1")
        
        if [[ -n "$load_1min" ]]; then
            load_percent=$(safe_calc "($load_1min / $cpu_cores) * 100")
            local load_avg=$(awk '{print $1,$2,$3}' /proc/loadavg 2>/dev/null)
            
            if (( $(awk "BEGIN {print ($load_percent > 100)}") )); then
                log_result "FAIL" "Hardware" "$test_name" "High CPU load: ${load_percent}% of ${cpu_cores} cores" "high"
                print_test_result "FAIL" "$test_name" "${load_percent}% load" "Load avg: $load_avg"
            elif (( $(awk "BEGIN {print ($load_percent > 75)}") )); then
                log_result "WARN" "Hardware" "$test_name" "Elevated CPU load: ${load_percent}% of ${cpu_cores} cores"
                print_test_result "WARN" "$test_name" "${load_percent}% load" "Load avg: $load_avg"
            else
                log_result "PASS" "Hardware" "$test_name" "CPU load: ${load_percent}% of ${cpu_cores} cores" "info"
                print_test_result "PASS" "$test_name" "${load_percent}% load" "${cpu_cores} cores, Load avg: $load_avg"
            fi
        fi
    fi
    
    # Temperature monitoring
    local test_name="CPU Temperature"
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp_raw temp_celsius
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        if [[ -n "$temp_raw" && "$temp_raw" -gt 0 ]]; then
            temp_celsius=$((temp_raw / 1000))
            
            if [[ "$temp_celsius" -gt 85 ]]; then
                FIX_SUGGESTIONS["temperature_fix"]="Critical CPU temperature. 1) Clean dust from heatsinks 2) Improve ventilation 3) Replace thermal paste 4) Check fan operation"
                log_result "FAIL" "Hardware" "$test_name" "Critical CPU temperature: ${temp_celsius}°C" "critical"
                print_test_result "FAIL" "$test_name" "${temp_celsius}°C (CRITICAL)" "Immediate attention required" "temperature_fix"
            elif [[ "$temp_celsius" -gt 70 ]]; then
                FIX_SUGGESTIONS["temperature_warn"]="High CPU temperature. Monitor system load and improve cooling"
                log_result "WARN" "Hardware" "$test_name" "High CPU temperature: ${temp_celsius}°C"
                print_test_result "WARN" "$test_name" "${temp_celsius}°C (High)" "Monitor system load" "temperature_warn"
            else
                log_result "PASS" "Hardware" "$test_name" "CPU temperature: ${temp_celsius}°C" "info"
                print_test_result "PASS" "$test_name" "${temp_celsius}°C" "Normal operating temperature"
            fi
        fi
    else
        log_result "SKIP" "Hardware" "$test_name" "Temperature sensors unavailable"
        print_test_result "SKIP" "$test_name" "No thermal sensors found"
    fi
}

run_storage_tests() {
    print_section_header "STORAGE ANALYSIS" "Disk health with specific remediation steps"
    
    local test_name="Disk Space Analysis"
    local critical_mounts=0 warning_mounts=0 total_mounts=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^/dev/ ]]; then
            ((total_mounts++))
            local mount_point usage_percent filesystem
            mount_point=$(echo "$line" | awk '{print $6}')
            usage_percent=$(echo "$line" | awk '{print $5}' | tr -d '%')
            filesystem=$(echo "$line" | awk '{print $1}')
            
            if [[ "$usage_percent" -gt 95 ]]; then
                ((critical_mounts++))
                local cleanup_suggestions=""
                case "$mount_point" in
                    "/")
                        cleanup_suggestions="1) Clean cache: sudo apt clean && sudo apt autoremove 2) Remove old kernels 3) Clean logs: sudo journalctl --vacuum-time=7d"
                        ;;
                    "/home"*)
                        cleanup_suggestions="1) Clean user cache: rm -rf ~/.cache/* 2) Check ~/Downloads/ 3) Remove large files"
                        ;;
                    *)
                        cleanup_suggestions="1) Check largest dirs: sudo du -h $mount_point | sort -h | tail -10"
                        ;;
                esac
                
                FIX_SUGGESTIONS["disk_critical_$mount_point"]="CRITICAL: $mount_point ${usage_percent}% full. $cleanup_suggestions"
                log_result "FAIL" "Storage" "Disk $mount_point" "Critical: ${usage_percent}% full on $filesystem" "critical"
                print_test_result "FAIL" "Disk $mount_point" "${usage_percent}% used (CRITICAL)" "Filesystem: $filesystem" "disk_critical_$mount_point"
                
            elif [[ "$usage_percent" -gt 85 ]]; then
                ((warning_mounts++))
                FIX_SUGGESTIONS["disk_warning_$mount_point"]="High usage. Monitor: df -h $mount_point"
                log_result "WARN" "Storage" "Disk $mount_point" "High usage: ${usage_percent}% full on $filesystem"
                print_test_result "WARN" "Disk $mount_point" "${usage_percent}% used (High)" "Filesystem: $filesystem" "disk_warning_$mount_point"
            else
                log_result "PASS" "Storage" "Disk $mount_point" "Usage: ${usage_percent}% on $filesystem" "info"
                print_test_result "PASS" "Disk $mount_point" "${usage_percent}% used" "Filesystem: $filesystem"
            fi
        fi
    done < <(df -h 2>/dev/null | grep -E '^/dev/')
    
    # Overall disk space summary
    if [[ "$critical_mounts" -gt 0 ]]; then
        log_result "FAIL" "Storage" "$test_name" "$critical_mounts critical, $warning_mounts warning of $total_mounts mounts" "critical"
    elif [[ "$warning_mounts" -gt 0 ]]; then
        log_result "WARN" "Storage" "$test_name" "$warning_mounts high usage of $total_mounts mounts"
    else
        log_result "PASS" "Storage" "$test_name" "All $total_mounts mount points healthy" "info"
    fi
    
    # Inode usage check
    local test_name="Inode Usage"
    local inode_usage
    inode_usage=$(df -i / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ -n "$inode_usage" ]]; then
        if [[ "$inode_usage" -gt 90 ]]; then
            FIX_SUGGESTIONS["inode_fix"]="Critical inode usage. 1) Delete unnecessary small files 2) Clear temporary files 3) Check for too many files in directories"
            log_result "FAIL" "Storage" "$test_name" "Critical inode usage: ${inode_usage}%" "high"
            print_test_result "FAIL" "$test_name" "${inode_usage}% used (CRITICAL)" "Too many small files" "inode_fix"
        elif [[ "$inode_usage" -gt 75 ]]; then
            FIX_SUGGESTIONS["inode_warn"]="High inode usage. Monitor file creation and clean up unnecessary files"
            log_result "WARN" "Storage" "$test_name" "High inode usage: ${inode_usage}%"
            print_test_result "WARN" "$test_name" "${inode_usage}% used (High)" "Monitor file creation" "inode_warn"
        else
            log_result "PASS" "Storage" "$test_name" "Inode usage: ${inode_usage}%" "info"
            print_test_result "PASS" "$test_name" "${inode_usage}% used" "Adequate file descriptors"
        fi
    fi
    
    # SMART disk health
    local test_name="Disk Health (SMART)"
    if is_root && command_exists smartctl; then
        local healthy_drives=0 failed_drives=0 total_drives=0
        
        for dev in $(lsblk -dpno NAME 2>/dev/null | grep -E '/dev/(sd|nvme|hd)' | head -5); do
            if [[ -b "$dev" ]]; then
                ((total_drives++))
                local smart_output drive_name
                drive_name=$(basename "$dev")
                smart_output=$(safe_timeout 15 smartctl -H "$dev" 2>/dev/null)
                
                if echo "$smart_output" | grep -q "PASSED"; then
                    ((healthy_drives++))
                    log_result "PASS" "Storage" "Drive $drive_name" "SMART health OK" "info"
                    print_test_result "PASS" "Drive $drive_name" "SMART: PASSED" "Health check OK"
                elif echo "$smart_output" | grep -q "FAILED"; then
                    ((failed_drives++))
                    FIX_SUGGESTIONS["smart_failed_$drive_name"]="SMART health FAILED. 1) Backup data immediately 2) Replace drive 3) Check cables and connections"
                    log_result "FAIL" "Storage" "Drive $drive_name" "SMART health FAILED" "critical"
                    print_test_result "FAIL" "Drive $drive_name" "SMART: FAILED" "Drive replacement needed" "smart_failed_$drive_name"
                else
                    log_result "WARN" "Storage" "Drive $drive_name" "SMART status unclear"
                    print_test_result "WARN" "Drive $drive_name" "SMART: Unknown" "Unable to determine health"
                fi
            fi
        done
        
        if [[ "$total_drives" -eq 0 ]]; then
            log_result "SKIP" "Storage" "$test_name" "No compatible drives found for SMART check"
            print_test_result "SKIP" "$test_name" "No drives to check"
        elif [[ "$failed_drives" -gt 0 ]]; then
            log_result "FAIL" "Storage" "$test_name" "$failed_drives of $total_drives drives failing" "critical"
        else
            log_result "PASS" "Storage" "$test_name" "All $total_drives drives healthy" "info"
        fi
    elif ! command_exists smartctl; then
        log_result "SKIP" "Storage" "$test_name" "smartctl not installed"
        print_test_result "SKIP" "$test_name" "Install: sudo apt install smartmontools"
    else
        log_result "SKIP" "Storage" "$test_name" "Requires root privileges"
        print_test_result "SKIP" "$test_name" "Run with sudo for disk health check"
    fi
}

run_package_tests() {
    print_section_header "PACKAGE SYSTEM ANALYSIS" "Checking package integrity, updates, and package manager health"
    
    # Package integrity check
    local test_name="Package Integrity"
    if command_exists apt-get; then
        local apt_check_output
        apt_check_output=$(sudo apt-get check 2>&1)
        if [[ $? -eq 0 ]]; then
            log_result "PASS" "Packages" "$test_name" "No broken packages detected"
            print_test_result "PASS" "$test_name" "All packages consistent"
        else
            # Extract package names from error output
            local broken_packages=$(echo "$apt_check_output" | grep -oE "package [^ ]+" | awk '{print $2}' | sort -u | head -5)
            local error_details=$(echo "$apt_check_output" | head -3)
            FIX_SUGGESTIONS["package_fix"]="Broken packages detected. Fix with: sudo apt --fix-broken install && sudo apt autoremove"
            log_result "FAIL" "Packages" "$test_name" "Broken packages detected" "high" "$error_details"
            print_test_result "FAIL" "$test_name" "Package inconsistencies found" "Fix: sudo apt --fix-broken install" "package_fix"
            
            if [[ -n "$broken_packages" ]]; then
                printf "    ${DIM}Affected packages: %s${NC}\n" "$broken_packages"
            fi
            if [[ -n "$error_details" ]]; then
                printf "    ${DIM}Error details: %s${NC}\n" "$(echo "$error_details" | head -1)"
            fi
        fi
    elif command_exists apt; then
        local apt_check_output
        apt_check_output=$(sudo apt check 2>&1)
        if [[ $? -eq 0 ]]; then
            log_result "PASS" "Packages" "$test_name" "No broken packages detected"
            print_test_result "PASS" "$test_name" "All packages consistent"
        else
            local broken_packages=$(echo "$apt_check_output" | grep -oE "package [^ ]+" | awk '{print $2}' | sort -u | head -5)
            local error_details=$(echo "$apt_check_output" | head -3)
            FIX_SUGGESTIONS["package_fix"]="Broken packages detected. Fix with: sudo apt --fix-broken install && sudo apt autoremove"
            log_result "FAIL" "Packages" "$test_name" "Broken packages detected" "high" "$error_details"
            print_test_result "FAIL" "$test_name" "Package inconsistencies found" "Fix: sudo apt install -f" "package_fix"
            
            if [[ -n "$broken_packages" ]]; then
                printf "    ${DIM}Affected packages: %s${NC}\n" "$broken_packages"
            fi
            if [[ -n "$error_details" ]]; then
                printf "    ${DIM}Error details: %s${NC}\n" "$(echo "$error_details" | head -1)"
            fi
        fi
    else
        log_result "SKIP" "Packages" "$test_name" "Package manager not available"
        print_test_result "SKIP" "$test_name" "Unsupported package system"
    fi
    
    # Update availability check
    local test_name="System Updates"
    if command_exists apt; then
        if [[ -d /var/lib/apt/lists ]] && [[ -n "$(ls -A /var/lib/apt/lists/ 2>/dev/null)" ]]; then
            local updates security_updates
            updates=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
            security_updates=$(apt list --upgradable 2>/dev/null | grep -ic "security" || echo "0")
            
            # Fix the syntax error - ensure we're comparing integers
            updates=${updates//[!0-9]/}  # Remove non-numeric characters
            security_updates=${security_updates//[!0-9]/}  # Remove non-numeric characters
            
            if [[ "$updates" -eq 0 ]]; then
                log_result "PASS" "Packages" "$test_name" "System is up to date"
                print_test_result "PASS" "$test_name" "All packages current"
            else
                if [[ "$security_updates" -gt 0 ]]; then
                    FIX_SUGGESTIONS["security_updates"]="Security updates available. Install with: sudo apt update && sudo apt upgrade --only-upgrade-security"
                    log_result "FAIL" "Packages" "$test_name" "$updates total updates ($security_updates security)" "high"
                    print_test_result "FAIL" "$test_name" "$updates updates available" "$security_updates are security updates" "security_updates"
                    
                    # Show security updates
                    local security_packages=$(apt list --upgradable 2>/dev/null | grep -i security | head -3 | awk -F/ '{print $1}')
                    if [[ -n "$security_packages" ]]; then
                        printf "    ${DIM}Security updates: %s${NC}\n" "$security_packages"
                    fi
                else
                    FIX_SUGGESTIONS["regular_updates"]="Updates available. Install with: sudo apt update && sudo apt upgrade"
                    log_result "WARN" "Packages" "$test_name" "$updates packages can be updated"
                    print_test_result "WARN" "$test_name" "$updates updates available" "Non-critical updates" "regular_updates"
                    
                    # Show some update details
                    local update_packages=$(apt list --upgradable 2>/dev/null | head -3 | awk -F/ '{print $1}')
                    if [[ -n "$update_packages" ]]; then
                        printf "    ${DIM}Available updates: %s${NC}\n" "$update_packages"
                    fi
                fi
            fi
        else
            FIX_SUGGESTIONS["update_cache"]="Package cache empty. Update with: sudo apt update"
            log_result "WARN" "Packages" "$test_name" "Package cache empty" "medium"
            print_test_result "WARN" "$test_name" "Cannot check updates" "Run: sudo apt update" "update_cache"
        fi
    fi
    
    # Package manager availability
    local test_name="Package Manager"
    if [[ -f /var/lib/dpkg/lock-frontend ]] && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        log_result "WARN" "Packages" "$test_name" "Package manager locked"
        print_test_result "WARN" "$test_name" "Manager busy" "Another package operation running"
    else
        log_result "PASS" "Packages" "$test_name" "Package manager available"
        print_test_result "PASS" "$test_name" "Ready for operations"
    fi
    
    # Snap packages (Ubuntu specific)
    local test_name="Snap Packages"
    if command_exists snap; then
        local snap_count snap_updates
        snap_count=$(snap list 2>/dev/null | tail -n +2 | wc -l || echo "0")
        
        if [[ "$snap_count" -gt 0 ]]; then
            if safe_timeout 15 snap refresh --list >/dev/null 2>&1; then
                snap_updates=$(snap refresh --list 2>/dev/null | tail -n +2 | wc -l || echo "0")
                if [[ "$snap_updates" -gt 0 ]]; then
                    FIX_SUGGESTIONS["snap_updates"]="Snap updates available. Update with: sudo snap refresh"
                    log_result "WARN" "Packages" "$test_name" "$snap_updates snap updates available"
                    print_test_result "WARN" "$test_name" "$snap_updates updates pending" "$snap_count total snaps" "snap_updates"
                    
                    # Show snap updates
                    local snap_update_list=$(snap refresh --list 2>/dev/null | head -3 | awk '{print $1}')
                    if [[ -n "$snap_update_list" ]]; then
                        printf "    ${DIM}Snap updates: %s${NC}\n" "$snap_update_list"
                    fi
                else
                    log_result "PASS" "Packages" "$test_name" "$snap_count snap packages up to date" "info"
                    print_test_result "PASS" "$test_name" "$snap_count snaps current" "All snap packages updated"
                fi
            else
                log_result "WARN" "Packages" "$test_name" "Cannot check snap updates"
                print_test_result "WARN" "$test_name" "$snap_count snaps installed" "Update check failed"
            fi
        else
            log_result "PASS" "Packages" "$test_name" "No snap packages installed" "info"
            print_test_result "PASS" "$test_name" "No snaps to manage"
        fi
    else
        log_result "SKIP" "Packages" "$test_name" "Snap not available"
        print_test_result "SKIP" "$test_name" "Snap not installed"
    fi
}

run_service_tests() {
    print_section_header "SERVICE ANALYSIS" "Service health with specific remediation steps"
    
    local test_name="Failed Services Analysis"
    if command_exists systemctl; then
        local failed_services_list failed_count
        failed_services_list=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null)
        failed_count=$(echo "$failed_services_list" | grep -c ".service" 2>/dev/null | tr -d '[:space:]') 
        [[ -z "$failed_count" ]] && failed_count=0
        
        if [[ "$failed_count" -eq 0 ]]; then
            log_result "PASS" "Services" "$test_name" "No failed services"
            print_test_result "PASS" "$test_name" "All services operational"
        else
            echo "$failed_services_list" | while read -r line; do
                if [[ -n "$line" ]]; then
                    local service_name
                    service_name=$(echo "$line" | awk '{print $1}')
                    printf "    ${BOLD}${RED}FAILED SERVICE: %s${NC}\n" "$service_name"
                    
                    case "$service_name" in
                        *bluetooth*)
                            printf "      ${CYAN}${FIX} Fix: sudo systemctl restart bluetooth && sudo systemctl enable bluetooth${NC}\n"
                            printf "      ${CYAN}${FIX} If persistent: sudo apt install --reinstall bluez${NC}\n"
                            ;;
                        *network*|*NetworkManager*)
                            printf "      ${CYAN}${FIX} Fix: sudo systemctl restart NetworkManager${NC}\n"
                            printf "      ${CYAN}${FIX} Check config: sudo journalctl -u NetworkManager --since '5 minutes ago'${NC}\n"
                            ;;
                        *user@*)
                            local user_id
                            user_id=$(echo "$service_name" | grep -oE '[0-9]+')
                            printf "      ${CYAN}${FIX} Fix: sudo loginctl terminate-user %s${NC}\n" "$user_id"
                            ;;
                        *)
                            printf "      ${CYAN}${FIX} Generic fix: sudo systemctl restart %s${NC}\n" "$service_name"
                            printf "      ${CYAN}${FIX} Check status: sudo systemctl status %s${NC}\n" "$service_name"
                            ;;
                    esac
                fi
            done
            
            FIX_SUGGESTIONS["failed_services"]="Failed services detected. Check with: systemctl --failed && journalctl -xe"
            log_result "FAIL" "Services" "$test_name" "$failed_count services failed with remediation steps" "high"
        fi
    fi
    
    # System state analysis
    local test_name="System State"
    if command_exists systemctl; then
        local system_state
        system_state=$(systemctl is-system-running 2>/dev/null | tr -d '[:space:]')
        
        case "$system_state" in
            "running")
                log_result "PASS" "Services" "$test_name" "System running normally"
                print_test_result "PASS" "$test_name" "System running normally"
                ;;
            "degraded")
                FIX_SUGGESTIONS["system_degraded"]="System degraded. Check: systemctl --failed && journalctl -p 3 -xb"
                log_result "WARN" "Services" "$test_name" "System degraded (some services failed)"
                print_test_result "WARN" "$test_name" "System degraded" "Some services have issues" "system_degraded"
                ;;
            *)
                FIX_SUGGESTIONS["system_unknown"]="System state problematic. Check: systemctl status && journalctl -b"
                log_result "FAIL" "Services" "$test_name" "System state: $system_state" "high"
                print_test_result "FAIL" "$test_name" "System state: $system_state" "System not operational" "system_unknown"
                ;;
        esac
    fi
    
    # Critical services check
    local -a critical_services=("systemd-resolved" "NetworkManager" "ssh" "systemd-timesyncd" "dbus")
    local healthy_critical=0 total_critical=0
    
    for service in "${critical_services[@]}"; do
        if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^${service}.service"; then
            ((total_critical++))
            local service_state
            service_state=$(systemctl is-active "$service" 2>/dev/null || echo "inactive")
            
            if [[ "$service_state" == "active" ]]; then
                ((healthy_critical++))
                log_result "PASS" "Services" "Service $service" "Active and running" "info"
                print_test_result "PASS" "Service $service" "Active" "Essential service running"
            else
                FIX_SUGGESTIONS["critical_service_$service"]="Critical service $service is $service_state. Fix with: sudo systemctl start $service && sudo systemctl enable $service"
                log_result "FAIL" "Services" "Service $service" "Service $service: $service_state" "high"
                print_test_result "FAIL" "Service $service" "$service_state" "Critical service down" "critical_service_$service"
            fi
        fi
    done
    
    local test_name="Critical Services"
    if [[ "$total_critical" -eq "$healthy_critical" ]]; then
        log_result "PASS" "Services" "$test_name" "All $total_critical critical services healthy" "info"
    else
        local unhealthy=$((total_critical - healthy_critical))
        FIX_SUGGESTIONS["critical_services"]="$unhealthy critical services down. Check with: systemctl list-units --state=failed"
        log_result "FAIL" "Services" "$test_name" "$unhealthy of $total_critical critical services down" "high"
    fi
}

run_network_tests() {
    print_section_header "NETWORK ANALYSIS" "Network diagnostics with specific fixes"
    
    local test_name="Network Interface Analysis"
    if command_exists ip; then
        local interface_info active_interfaces
        interface_info=$(ip -brief addr show 2>/dev/null)
        active_interfaces=$(echo "$interface_info" | grep -c "UP" || echo "0")
        
        if [[ "$active_interfaces" -gt 0 ]]; then
            echo "    ${BOLD}${BLUE}NETWORK INTERFACES:${NC}"
            echo "$interface_info" | grep -v "lo" | while read -r line; do
                if [[ "$line" =~ UP ]]; then
                    local iface ip_addr
                    iface=$(echo "$line" | awk '{print $1}')
                    ip_addr=$(echo "$line" | awk '{print $3}')
                    printf "      ${GREEN}→ %s: %s (UP)${NC}\n" "$iface" "$ip_addr"
                fi
            done
            
            log_result "PASS" "Network" "$test_name" "$active_interfaces active interfaces" "info"
            print_test_result "PASS" "$test_name" "$active_interfaces active interfaces"
        else
            FIX_SUGGESTIONS["no_network"]="No network interfaces active. Check: ip link show && sudo systemctl restart NetworkManager"
            log_result "FAIL" "Network" "$test_name" "No active network interfaces" "critical"
            print_test_result "FAIL" "$test_name" "No interfaces active" "Network unavailable" "no_network"
        fi
    fi
    
    # Gateway connectivity
    local test_name="Gateway Connectivity"
    if command_exists ip; then
        local gateway
        gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        if [[ -n "$gateway" ]]; then
            if safe_timeout 5 ping -c1 -W2 "$gateway" >/dev/null 2>&1; then
                log_result "PASS" "Network" "$test_name" "Gateway reachable: $gateway" "info"
                print_test_result "PASS" "$test_name" "Gateway responding" "IP: $gateway"
            else
                FIX_SUGGESTIONS["gateway_failed"]="Gateway $gateway unreachable. Check: ip route show && ping $gateway"
                log_result "FAIL" "Network" "$test_name" "Gateway unreachable: $gateway" "high"
                print_test_result "FAIL" "$test_name" "Gateway timeout" "IP: $gateway" "gateway_failed"
            fi
        else
            FIX_SUGGESTIONS["no_gateway"]="No default gateway configured. Check: ip route add default via <router-ip>"
            log_result "FAIL" "Network" "$test_name" "No default gateway configured" "high"
            print_test_result "FAIL" "$test_name" "No default route" "Network isolation" "no_gateway"
        fi
    fi
    
    # Internet connectivity test
    local test_name="Internet Connectivity"
    local internet_ok=false
    local test_hosts=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    
    for host in "${test_hosts[@]}"; do
        if safe_timeout 5 ping -c1 -W2 "$host" >/dev/null 2>&1; then
            log_result "PASS" "Network" "$test_name" "Internet reachable via $host" "info"
            print_test_result "PASS" "$test_name" "Internet accessible" "DNS server: $host"
            internet_ok=true
            break
        fi
    done
    
    if [[ "$internet_ok" = false ]]; then
        FIX_SUGGESTIONS["no_internet"]="No internet connectivity. Check: ping 8.8.8.8; sudo systemctl restart NetworkManager; check firewall settings"
        log_result "FAIL" "Network" "$test_name" "No internet connectivity" "high"
        print_test_result "FAIL" "$test_name" "Internet unreachable" "Check network config" "no_internet"
    fi
    
    # DNS resolution
    local test_name="DNS Resolution"
    if [[ "$internet_ok" = true ]]; then
        local test_domains=("google.com" "debian.org" "kernel.org")
        local dns_ok=false
        
        for domain in "${test_domains[@]}"; do
            if safe_timeout 5 nslookup "$domain" >/dev/null 2>&1 || safe_timeout 5 dig "$domain" >/dev/null 2>&1; then
                log_result "PASS" "Network" "$test_name" "DNS resolution working for $domain" "info"
                print_test_result "PASS" "$test_name" "DNS operational" "Resolved: $domain"
                dns_ok=true
                break
            fi
        done
        
        if [[ "$dns_ok" = false ]]; then
            FIX_SUGGESTIONS["dns_failed"]="DNS resolution failed. Check: /etc/resolv.conf; sudo systemctl restart systemd-resolved"
            log_result "FAIL" "Network" "$test_name" "DNS resolution failed for all test domains" "high"
            print_test_result "FAIL" "$test_name" "DNS not working" "Cannot resolve domain names" "dns_failed"
        fi
    else
        log_result "SKIP" "Network" "$test_name" "Skipped due to no internet connectivity"
        print_test_result "SKIP" "$test_name" "No internet for DNS test"
    fi
}

run_security_tests() {
    print_section_header "SECURITY & SYSTEM STATE" "Checking firewall, authentication logs, and system security"
    
    # Firewall status
    local test_name="Firewall Status"
    if command_exists ufw && is_root; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | grep "Status:" | awk '{print $2}' || echo "unknown")
        
        if [[ "$ufw_status" = "active" ]]; then
            local rule_count
            rule_count=$(ufw status numbered 2>/dev/null | grep -c "\[" | tr -d '[:space:]') 
            [[ -z "$rule_count" ]] && rule_count=0
            log_result "PASS" "Security" "$test_name" "UFW active with $rule_count rules"
            print_test_result "PASS" "$test_name" "UFW firewall active" "$rule_count rules configured"
        else
            FIX_SUGGESTIONS["ufw_inactive"]="UFW firewall inactive. Enable with: sudo ufw enable"
            log_result "WARN" "Security" "$test_name" "UFW firewall inactive"
            print_test_result "WARN" "$test_name" "UFW inactive" "Enable: sudo ufw enable" "ufw_inactive"
        fi
    elif command_exists iptables && is_root; then
        local rule_count
        rule_count=$(iptables -L 2>/dev/null | grep -c "^Chain" || echo "0")
        if [[ "$rule_count" -gt 3 ]]; then
            log_result "PASS" "Security" "$test_name" "iptables rules configured"
            print_test_result "PASS" "$test_name" "iptables active" "Custom firewall rules"
        else
            FIX_SUGGESTIONS["minimal_firewall"]="Minimal firewall protection. Consider configuring UFW: sudo apt install ufw && sudo ufw enable"
            log_result "WARN" "Security" "$test_name" "Minimal firewall protection"
            print_test_result "WARN" "$test_name" "Basic iptables only" "Consider configuring UFW" "minimal_firewall"
        fi
    else
        local reason="requires root privileges"
        [[ ! -x "$(command -v ufw)" ]] && [[ ! -x "$(command -v iptables)" ]] && reason="no firewall tools found"
        log_result "SKIP" "Security" "$test_name" "Cannot check firewall ($reason)"
        print_test_result "SKIP" "$test_name" "Firewall check skipped" "$reason"
    fi
    
    # Authentication failures
    local test_name="Authentication Security"
    if is_root && command_exists journalctl; then
        local auth_failures auth_time_window="2 hours ago"
        auth_failures=$(journalctl --since "$auth_time_window" --no-pager 2>/dev/null | 
               grep -icE "authentication failure|failed password|invalid user" | tr -d '[:space:]')
               [[ -z "$auth_failures" ]] && auth_failures=0

        if [[ "$auth_failures" -eq 0 ]]; then
            log_result "PASS" "Security" "$test_name" "No recent authentication failures"
            print_test_result "PASS" "$test_name" "No failed logins" "Clean authentication log"
        elif [[ "$auth_failures" -le 5 ]]; then
            log_result "WARN" "Security" "$test_name" "$auth_failures authentication failures in last 2 hours"
            print_test_result "WARN" "$test_name" "$auth_failures failed attempts" "Monitor authentication logs"
        else
            FIX_SUGGESTIONS["auth_attacks"]="$auth_failures authentication failures detected (potential attack). Check: sudo journalctl --since '2 hours ago' | grep -i 'failed password'"
            log_result "FAIL" "Security" "$test_name" "$auth_failures authentication failures (potential attack)" "high"
            print_test_result "FAIL" "$test_name" "$auth_failures failed attempts" "Possible brute force attack" "auth_attacks"
            
            # Show authentication failure details
            local auth_details=$(journalctl --since "$auth_time_window" --no-pager 2>/dev/null | 
                               grep -iE "authentication failure|failed password|invalid user" | head -3)
            [[ -n "$auth_details" ]] && printf "    ${DIM}%s${NC}\n" "$(echo "$auth_details" | head -1 | cut -c1-80)..."
        fi
    else
        log_result "SKIP" "Security" "$test_name" "Authentication log check requires root"
        print_test_result "SKIP" "$test_name" "Cannot check auth logs"
    fi
    
    # System error analysis
    local test_name="System Error Logs"
    if is_root && command_exists journalctl; then
        local recent_errors error_time_window="1 hour ago"
        recent_errors=$(journalctl -p 3 -b --since "$error_time_window" --no-pager 2>/dev/null | wc -l || echo "0")
        
        if [[ "$recent_errors" -eq 0 ]]; then
            log_result "PASS" "Security" "$test_name" "No recent critical errors"
            print_test_result "PASS" "$test_name" "Clean error logs" "No critical system errors"
        elif [[ "$recent_errors" -le 3 ]]; then
            log_result "WARN" "Security" "$test_name" "$recent_errors critical errors in last hour"
            print_test_result "WARN" "$test_name" "$recent_errors recent errors" "Check: journalctl -p 3 --since '1 hour ago'"
        else
            FIX_SUGGESTIONS["system_errors"]="$recent_errors critical errors detected. Check: journalctl -p 3 -xb --no-pager"
            log_result "FAIL" "Security" "$test_name" "$recent_errors critical errors (system instability)" "high"
            print_test_result "FAIL" "$test_name" "$recent_errors critical errors" "System experiencing issues" "system_errors"
            
            # Show sample errors
            journalctl -p 3 --since "$error_time_window" --no-pager 2>/dev/null | tail -2 | while read -r line; do
                [[ -n "$line" ]] && printf "    ${DIM}→ %s${NC}\n" "$(echo "$line" | cut -c1-80)..."
            done
        fi
    else
        log_result "SKIP" "Security" "$test_name" "System log analysis requires root"
        print_test_result "SKIP" "$test_name" "Cannot analyze system logs"
    fi
    
    # Reboot requirement check
    local test_name="Reboot Status"
    if [[ -f /var/run/reboot-required ]]; then
        local reboot_packages=""
        [[ -f /var/run/reboot-required.pkgs ]] && reboot_packages=$(head -3 /var/run/reboot-required.pkgs | tr '\n' ' ')
        
        FIX_SUGGESTIONS["reboot_required"]="System reboot required for updates. Reboot with: sudo shutdown -r now"
        log_result "WARN" "Security" "$test_name" "System reboot required for updates"
        print_test_result "WARN" "$test_name" "Reboot required" "Packages: ${reboot_packages:-unknown}" "reboot_required"
        
        if [[ -n "$reboot_packages" ]]; then
            printf "    ${DIM}Required for: %s${NC}\n" "$reboot_packages"
        fi
    else
        log_result "PASS" "Security" "$test_name" "No reboot required"
        print_test_result "PASS" "$test_name" "System current" "No pending reboot needed"
    fi
    
    # System uptime analysis
    local test_name="System Uptime"
    if [[ -r /proc/uptime ]]; then
        local uptime_seconds uptime_days uptime_hours
        uptime_seconds=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)
        uptime_days=$((uptime_seconds / 86400))
        uptime_hours=$(( (uptime_seconds % 86400) / 3600 ))
        
        if [[ "$uptime_days" -gt 90 ]]; then
            FIX_SUGGESTIONS["long_uptime"]="System uptime very high: ${uptime_days} days. Consider rebooting for stability and security updates"
            log_result "WARN" "Security" "$test_name" "System uptime very high: ${uptime_days} days"
            print_test_result "WARN" "$test_name" "${uptime_days} days uptime" "Consider rebooting for security updates" "long_uptime"
        elif [[ "$uptime_days" -gt 30 ]]; then
            log_result "WARN" "Security" "$test_name" "System uptime high: ${uptime_days} days"
            print_test_result "WARN" "$test_name" "${uptime_days} days uptime" "Reboot recommended for updates"
        else
            log_result "PASS" "Security" "$test_name" "System uptime: ${uptime_days} days, ${uptime_hours} hours" "info"
            print_test_result "PASS" "$test_name" "${uptime_days}d ${uptime_hours}h uptime" "Recent reboot or new system"
        fi
    fi
}

generate_summary_report() {
    local end_time health_score scan_duration
    end_time=$(date +%s)
    scan_duration=$((end_time - START_TIME))
    
    print_section_header "COMPREHENSIVE DIAGNOSTIC REPORT" "Detailed analysis with actionable fixes"
    
    if [[ $TOTAL_TESTS -gt 0 ]]; then
        health_score=$(safe_calc "($PASSED_TESTS / $TOTAL_TESTS) * 100")
        local status_color status_text
        
        if (( $(awk "BEGIN {print ($health_score >= 85)}") )); then
            status_color="$GREEN" ; status_text="EXCELLENT"
        elif (( $(awk "BEGIN {print ($health_score >= 70)}") )); then
            status_color="$YELLOW" ; status_text="GOOD"
        elif (( $(awk "BEGIN {print ($health_score >= 50)}") )); then
            status_color="$YELLOW" ; status_text="FAIR"
        else
            status_color="$RED" ; status_text="POOR"
        fi
        
        echo
        printf "${BOLD}${PURPLE}╭─────────────────────────────────────────────────────────╮${NC}\n"
        printf "${BOLD}${PURPLE}│${NC}                    ${BOLD}HEALTH SCORE: %s%%${NC}                     ${BOLD}${PURPLE}│${NC}\n" "$health_score"
        printf "${BOLD}${PURPLE}│${NC}              ${status_color}${BOLD}STATUS: %s${NC}                      ${BOLD}${PURPLE}│${NC}\n" "$status_text"
        printf "${BOLD}${PURPLE}╰─────────────────────────────────────────────────────────╯${NC}\n"
        echo
        
        # Test statistics
        printf "${BOLD}Test Results Summary:${NC}\n"
        printf "  %s${GREEN}${CHECK} Passed:%s %d tests${NC}\n" "" "" "$PASSED_TESTS"
        printf "  %s${YELLOW}${WARN} Warnings:%s %d tests${NC}\n" "" "" "$WARNING_TESTS"
        printf "  %s${RED}${CROSS} Failed:%s %d tests${NC}\n" "" "" "$FAILED_TESTS"
        printf "  %s${DIM}${INFO} Skipped:%s %d tests${NC}\n" "" "" "$SKIPPED_TESTS"
        printf "  ${BOLD}Total Executed:%s %d tests in %ds${NC}\n" "" "$TOTAL_TESTS" "$scan_duration"
        echo
        
        # Show critical issues
        if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
            printf "${RED}${BOLD}CRITICAL ISSUES (Immediate Action Required):${NC}\n"
            for issue in "${CRITICAL_ISSUES[@]}"; do
                printf "  ${RED}${CROSS} %s${NC}\n" "$issue"
            done
            echo
        fi
        
        # Show high priority issues
        if [[ ${#HIGH_ISSUES[@]} -gt 0 ]]; then
            printf "${YELLOW}${BOLD}HIGH PRIORITY ISSUES:${NC}\n"
            for issue in "${HIGH_ISSUES[@]:0:5}"; do
                printf "  ${YELLOW}${WARN} %s${NC}\n" "$issue"
            done
            [[ ${#HIGH_ISSUES[@]} -gt 5 ]] && printf "  ${DIM}... and %d more issues${NC}\n" $((${#HIGH_ISSUES[@]} - 5))
            echo
        fi
        
        # Show detailed fix recommendations
        if [[ ${#FIX_SUGGESTIONS[@]} -gt 0 ]]; then
            echo
            printf "${BOLD}${CYAN}╭─── DETAILED FIX RECOMMENDATIONS ───╮${NC}\n"
            printf "${BOLD}${CYAN}│                                      │${NC}\n"
            printf "${BOLD}${CYAN}╰──────────────────────────────────────╯${NC}\n"
            echo
            
            local fix_count=1
            for fix_key in "${!FIX_SUGGESTIONS[@]}"; do
                printf "${BOLD}${CYAN}%d. %s:${NC}\n" "$fix_count" "${fix_key^^}"
                printf "%s\n\n" "${FIX_SUGGESTIONS[$fix_key]}"
                ((fix_count++))
                [[ $fix_count -gt 10 ]] && break
            done
        fi
        
        # Hardware-specific recommendations
        echo
        printf "${BOLD}${PURPLE}HARDWARE-SPECIFIC RECOMMENDATIONS:${NC}\n"
        
        if command_exists dmesg && dmesg 2>/dev/null | grep -qi bluetooth; then
            printf "• ${CYAN}Bluetooth Hardware:${NC} Issues detected in system logs\n"
            printf "  - Install firmware: ${BOLD}sudo apt install bluez-firmware${NC}\n"
            printf "  - Check hardware: ${BOLD}lsusb | grep -i bluetooth${NC}\n"
        fi
        
        if command_exists dmesg && dmesg 2>/dev/null | grep -qi "i2c_hid"; then
            printf "• ${CYAN}Touchpad Hardware:${NC} I2C HID communication errors\n"
            printf "  - Install drivers: ${BOLD}sudo apt install xserver-xorg-input-synaptics${NC}\n"
            printf "  - Kernel parameter: ${BOLD}i2c_hid.use_polling_mode=1${NC} in GRUB\n"
        fi
        
        if command_exists lspci && lspci 2>/dev/null | grep -qi "realtek\|broadcom\|intel.*wireless"; then
            printf "• ${CYAN}Network Hardware:${NC} Common vendors detected\n"
            printf "  - Update drivers: ${BOLD}sudo apt install firmware-realtek firmware-iwlwifi${NC}\n"
            printf "  - Check status: ${BOLD}sudo dmesg | grep -i firmware${NC}\n"
        fi
    fi
    
    echo
    printf "${BOLD}${GREEN}SYSTEM MAINTENANCE CHECKLIST:${NC}\n"
    printf "□ Run system updates: ${BOLD}sudo apt update && sudo apt upgrade${NC}\n"
    printf "□ Clean package cache: ${BOLD}sudo apt autoremove && sudo apt clean${NC}\n"
    printf "□ Check disk space: ${BOLD}df -h${NC}\n"
    printf "□ Review system logs: ${BOLD}sudo journalctl -p 3 -b${NC}\n"
    printf "□ Update firmware: ${BOLD}sudo apt install firmware-linux firmware-linux-nonfree${NC}\n"
    printf "□ Restart failed services: ${BOLD}sudo systemctl restart [service]${NC}\n"
    
    echo
    printf "${BOLD}${BLUE}EMERGENCY COMMANDS (if system is unstable):${NC}\n"
    printf "• Force filesystem check: ${BOLD}sudo fsck -f /dev/[device]${NC}\n"
    printf "• Emergency mode: ${BOLD}sudo systemctl rescue${NC}\n"
    printf "• Safe reboot: ${BOLD}sudo systemctl reboot${NC}\n"
    printf "• Check hardware errors: ${BOLD}sudo dmesg | grep -i error${NC}\n"
    
    echo
    printf "${BOLD}${PURPLE}Diagnostic Complete - $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
    printf "${DIM}Enhanced scan completed in %d seconds with root cause analysis${NC}\n" "$scan_duration"
    echo
}

# Main execution flow
main() {
    print_main_header
    run_boot_hardware_tests
    run_storage_tests
    run_package_tests
    run_service_tests
    run_network_tests
    run_security_tests
    generate_summary_report
    
    # Exit with appropriate code based on results
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        exit 2  # Critical issues found
    elif [[ ${#HIGH_ISSUES[@]} -gt 0 ]]; then
        exit 1  # High priority issues found
    else
        exit 0  # System healthy
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
