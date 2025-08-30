#!/bin/bash

# Enhanced Universal System Health Check v5.1
# Comprehensive Hardware & Software Diagnostics with Root Cause Analysis
# Compatible with Debian-based systems

# Color definitions with fallback
if [[ -t 1 ]] && { [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]]; } && command -v tput >/dev/null 2>&1; then
    if tput colors >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
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
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' PURPLE='' BOLD='' DIM='' NC=''
    readonly CHECK="[OK]" CROSS="[FAIL]" WARN="[WARN]" INFO="[INFO]" FIX="[FIX]"
fi

# Global tracking variables
declare -i TOTAL_TESTS=0 PASSED_TESTS=0 FAILED_TESTS=0 WARNING_TESTS=0 SKIPPED_TESTS=0
declare -a CRITICAL_ISSUES=() HIGH_ISSUES=() MEDIUM_ISSUES=() INFO_ITEMS=() DETAILED_ERRORS=()
declare -A TEST_RESULTS=() FIX_SUGGESTIONS=() HARDWARE_INFO=() HARDWARE_CACHE=()
readonly START_TIME=$(date +%s)

# Hardware database for driver recommendations
declare -A HARDWARE_DRIVERS=(
    # Bluetooth hardware
    ["8087:0025"]="firmware-iwlwifi bluez-firmware"
    ["8087:0026"]="firmware-iwlwifi bluez-firmware"  
    ["8087:0029"]="firmware-iwlwifi bluez-firmware"
    ["8087:0a2b"]="bluez-firmware"  # Intel Bluetooth found in your system
    ["04ca:3015"]="firmware-brcm80211"
    ["0cf3:e007"]="firmware-atheros"
    ["13d3:3491"]="firmware-atheros"
    
    # WiFi hardware
    ["8086:24f3"]="firmware-iwlwifi"
    ["8086:095a"]="firmware-iwlwifi"
    ["8086:24fd"]="firmware-iwlwifi"  # Intel Wireless 8265/8275
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
    ["10de:174d"]="nvidia-driver-535"  # NVIDIA GM108M [GeForce MX130]
    
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
    ["i2c_hid.*ELAN.*incorrect report"]="elan_touchpad_error"
    ["iwlwifi.*firmware.*failed"]="wifi_firmware_failed"
    ["i915.*GPU.*hung"]="gpu_hang"
    ["nouveau.*MMIO.*FAULT"]="nvidia_gpu_error"
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

sanitize_integer() {
    echo "$1" | tr -d '[:space:]' | grep -oE '^[0-9]+$' || echo "0"
}

safe_arithmetic() {
    local value1=$(sanitize_integer "$1")
    local value2=$(sanitize_integer "$2")
    local operation="$3"
    
    case "$operation" in
        "gt") [[ "$value1" -gt "$value2" ]] && return 0 || return 1 ;;
        "eq") [[ "$value1" -eq "$value2" ]] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

sanitize_path() {
    echo "$1" | sed 's/[^a-zA-Z0-9/_.-]//g'
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
    printf "${BOLD}${PURPLE}│${NC}         ${BOLD}COMPREHENSIVE SYSTEM HEALTH CHECK v5.1${NC}          ${BOLD}${PURPLE}│${NC}\n"
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

detect_hardware_cached() {
    local hw_type="$1"
    if [[ -z "${HARDWARE_CACHE[$hw_type]}" ]]; then
        HARDWARE_CACHE["$hw_type"]=$(detect_hardware "$hw_type")
    fi
    echo "${HARDWARE_CACHE[$hw_type]}"
}

get_hardware_ids() {
    local hw_type="$1"
    local ids=""
    
    case "$hw_type" in
        "bluetooth"|"wifi"|"audio"|"gpu")
            if command_exists lspci; then
                case "$hw_type" in
                    "bluetooth")
                        ids=$(lspci -nn 2>/dev/null | grep -iE "(bluetooth|wireless.*bt)" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tr -d '[]' | head -3)
                        ;;
                    "wifi")
                        ids=$(lspci -nn 2>/dev/null | grep -iE "(wireless|802\.11|wifi)" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tr -d '[]' | head -3)
                        ;;
                    *)
                        ids=$(lspci -nn 2>/dev/null | grep -iE "$hw_type" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tr -d '[]' | head -3)
                        ;;
                esac
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
    local hardware_context=""
    
    # Get additional hardware context
    case "$category" in
        "bluetooth")
            hardware_context=$(lspci -v 2>/dev/null | grep -A5 -i bluetooth || lsusb -v 2>/dev/null | grep -A5 -i bluetooth)
            ;;
        "gpu")
            hardware_context=$(lspci -v 2>/dev/null | grep -A10 -i vga || lspci -v 2>/dev/null | grep -A10 -i nvidia)
            ;;
    esac
    
    for pattern in "${!ERROR_PATTERNS[@]}"; do
        if echo "$error_text" | grep -qE "$pattern"; then
            case "${ERROR_PATTERNS[$pattern]}" in
                "bluetooth_features_failed")
                    local bt_hw bt_ids
                    bt_hw=$(detect_hardware_cached "bluetooth")
                    bt_ids=$(get_hardware_ids "bluetooth")
                    fixes="Root Cause: Bluetooth controller firmware/driver issue"$'\n'
                    fixes+="Hardware Detected: $bt_hw"$'\n'
                    fixes+="Hardware Context: $hardware_context"$'\n'
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
                    
                "touchpad_hid_error"|"elan_touchpad_error")
                    local tp_hw
                    tp_hw=$(detect_hardware_cached "touchpad")
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
                    audio_hw=$(detect_hardware_cached "audio")
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
                    wifi_hw=$(detect_hardware_cached "wifi")
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
                    
                "nvidia_gpu_error")
                    fixes="Root Cause: NVIDIA GPU driver conflict with nouveau"$'\n'
                    fixes+="Hardware Context: $hardware_context"$'\n'
                    fixes+="Recommended Fixes:"$'\n'
                    fixes+="1. Install proprietary NVIDIA driver: sudo apt install nvidia-driver-535"$'\n'
                    fixes+="2. Blacklist nouveau driver: echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf"$'\n'
                    fixes+="3. Update initramfs: sudo update-initramfs -u"$'\n'
                    fixes+="4. Reboot system: sudo reboot"
                    ;;
                    
                "storage_ata_error")
                    local storage_hw
                    storage_hw=$(detect_hardware_cached "storage")
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
        boot_errors=$(sanitize_integer "$boot_errors")
        
        if safe_arithmetic "$boot_errors" "0" "eq"; then
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
            
            if echo "$error_details" | grep -qiE "nouveau.*MMIO.*FAULT"; then
                fix_recommendations+="NVIDIA GPU driver issue detected. "
                FIX_SUGGESTIONS["nvidia_fix"]=$(analyze_error_pattern "$error_details" "gpu")
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
            hw_info=$(detect_hardware_cached "$hw_type")
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
        
        mem_total=$(sanitize_integer "$mem_total")
        mem_available=$(sanitize_integer "$mem_available")
        
        if [[ -n "$mem_total" && -n "$mem_available" && "$mem_total" -gt 0 ]]; then
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
        
        cpu_cores=$(sanitize_integer "$cpu_cores")
        
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
        temp_raw=$(sanitize_integer "$temp_raw")
        
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
            
            usage_percent=$(sanitize_integer "$usage_percent")
            
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
    inode_usage=$(sanitize_integer "$inode_usage")
    
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
            print_test_result "PASS" "$test_name" "${inode_usage%} used" "Adequate file descriptors"
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
        if [[ $? -eq 0 ]] || echo "$apt_check_output" | grep -q "0 broken"; then
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
        if [[ $? -eq 0 ]] || echo "$apt_check_output" | grep -q "0 broken"; then
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
            
            # Count upgradable packages safely
            updates=$(apt list --upgradable 2>/dev/null | grep -c "/.*upgradable" || echo "0")
            security_updates=$(apt list --upgradable 2>/dev/null | grep -ic "security" || echo "0")
            
            # Ensure variables are integers
            updates=$(sanitize_integer "$updates")
            security_updates=$(sanitize_integer "$security_updates")
            
            if safe_arithmetic "$updates" "0" "eq"; then
                log_result "PASS" "Packages" "$test_name" "System is up to date"
                print_test_result "PASS" "$test_name" "All packages current"
            else
                if safe_arithmetic "$security_updates" "0" "gt"; then
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
        snap_count=$(sanitize_integer "$snap_count")
        
        if [[ "$snap_count" -gt 0 ]]; then
            if safe_timeout 15 snap refresh --list >/dev/null 2>&1; then
                snap_updates=$(snap refresh --list 2>/dev/null | tail -n +2 | wc -l || echo "0")
                snap_updates=$(sanitize_integer "$snap_updates")
                
                if safe_arithmetic "$snap_updates" "0" "gt"; then
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
        
        # Better service counting with error handling
        failed_services_list=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null)
        failed_count=$(echo "$failed_services_list" | grep -c ".service" 2>/dev/null)
        failed_count=$(sanitize_integer "$failed_count")
        
        if safe_arithmetic "$failed_count" "0" "eq"; then
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
        active_interfaces=$(sanitize_integer "$active_interfaces")
        
        if safe_arithmetic "$active_interfaces" "0" "gt"; then
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
            if safe_timeout 5 bash -c "nslookup '$domain' >/dev/null 2>&1 || dig '$domain' >/dev/null 2>&1"; then
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
            rule_count=$(sanitize_integer "$rule_count")
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
        rule_count=$(sanitize_integer "$rule_count")
        if safe_arithmetic "$rule_count" "3" "gt"; then
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
        auth_failures=$(sanitize_integer "$auth_failures")
        [[ -z "$auth_failures" ]] && auth_failures=0

        if safe_arithmetic "$auth_failures" "0" "eq"; then
            log_result "PASS" "Security" "$test_name" "No recent authentication failures"
            print_test_result "PASS" "$test_name" "No failed logins" "Clean authentication log"
        elif safe_arithmetic "$auth_failures" "5" "le"; then
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
        recent_errors=$(sanitize_integer "$recent_errors")
        
        if safe_arithmetic "$recent_errors" "0" "eq"; then
            log_result "PASS" "Security" "$test_name" "No recent critical errors"
            print_test_result "PASS" "$test_name" "Clean error logs" "No critical system errors"
        elif safe_arithmetic "$recent_errors" "3" "le"; then
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
    }
# System uptime analysis
run_uptime_analysis() {
    local test_name="System Uptime"
    if [[ -r /proc/uptime ]]; then
        local uptime_seconds uptime_days uptime_hours uptime_minutes
        uptime_seconds=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)
        uptime_seconds=$(sanitize_integer "$uptime_seconds")
        
        # Calculate time components
        uptime_days=$((uptime_seconds / 86400))
        uptime_hours=$(( (uptime_seconds % 86400) / 3600 ))
        uptime_minutes=$(( (uptime_seconds % 3600) / 60 ))
        
        # Format uptime string based on duration
        local uptime_display
        if [[ "$uptime_days" -gt 0 ]]; then
            uptime_display="${uptime_days}d ${uptime_hours}h ${uptime_minutes}m"
        elif [[ "$uptime_hours" -gt 0 ]]; then
            uptime_display="${uptime_hours}h ${uptime_minutes}m"
        else
            uptime_display="${uptime_minutes}m"
        fi
        
        # Evaluate uptime status
        if [[ "$uptime_days" -gt 90 ]]; then
            FIX_SUGGESTIONS["long_uptime"]="System uptime very high: ${uptime_days} days. Consider rebooting for:
• Kernel updates and security patches
• Memory leak prevention
• System stability improvements
Reboot command: sudo shutdown -r now"
            log_result "WARN" "Security" "$test_name" "System uptime very high: ${uptime_days} days"
            print_test_result "WARN" "$test_name" "${uptime_display} (Very High)" "Consider rebooting for security updates" "long_uptime"
        elif [[ "$uptime_days" -gt 30 ]]; then
            FIX_SUGGESTIONS["medium_uptime"]="System uptime high: ${uptime_days} days. Recommended actions:
• Schedule a maintenance window for reboot
• Check for pending kernel updates
• Review system logs for any issues"
            log_result "WARN" "Security" "$test_name" "System uptime high: ${uptime_days} days"
            print_test_result "WARN" "$test_name" "${uptime_display} (High)" "Reboot recommended for updates" "medium_uptime"
        else
            log_result "PASS" "Security" "$test_name" "System uptime: ${uptime_days} days, ${uptime_hours} hours" "info"
            print_test_result "PASS" "$test_name" "${uptime_display}" "Recent reboot or new system"
        fi
        
        # Additional uptime insights
        if [[ "$uptime_days" -gt 7 ]]; then
            printf "    ${DIM}Last boot: %s${NC}\n" "$(date -d "now - $uptime_seconds seconds" '+%Y-%m-%d %H:%M:%S')"
        fi
    else
        log_result "SKIP" "Security" "$test_name" "Uptime information unavailable"
        print_test_result "SKIP" "$test_name" "Cannot read /proc/uptime" "System uptime data not accessible"
    fi
}

# Generate comprehensive summary report
generate_summary_report() {
    local end_time health_score scan_duration
    end_time=$(date +%s)
    scan_duration=$((end_time - START_TIME))
    
    print_section_header "COMPREHENSIVE SYSTEM HEALTH REPORT" "Detailed analysis with prioritized recommendations"
    
    if [[ $TOTAL_TESTS -gt 0 ]]; then
        # Calculate health score with weighted components
        health_score=$(safe_calc "(($PASSED_TESTS * 1.0 + $WARNING_TESTS * 0.5) / $TOTAL_TESTS) * 100")
        
        # Determine system status
        local status_color status_text status_emoji
        if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
            status_color="$RED"
            status_text="CRITICAL"
            status_emoji="🔴"
        elif (( $(awk "BEGIN {print ($health_score >= 85)}") )); then
            status_color="$GREEN"
            status_text="EXCELLENT"
            status_emoji="🟢"
        elif (( $(awk "BEGIN {print ($health_score >= 70)}") )); then
            status_color="$YELLOW"
            status_text="GOOD"
            status_emoji="🟡"
        elif (( $(awk "BEGIN {print ($health_score >= 50)}") )); then
            status_color="$YELLOW"
            status_text="FAIR"
            status_emoji="🟠"
        else
            status_color="$RED"
            status_text="POOR"
            status_emoji="🔴"
        fi
        
        # Display health assessment
        echo
        printf "${BOLD}${PURPLE}╔═════════════════════════════════════════════════════════╗${NC}\n"
        printf "${BOLD}${PURPLE}║${NC}                  ${BOLD}SYSTEM HEALTH ASSESSMENT${NC}                  ${BOLD}${PURPLE}║${NC}\n"
        printf "${BOLD}${PURPLE}╠═════════════════════════════════════════════════════════╣${NC}\n"
        printf "${BOLD}${PURPLE}║${NC}     ${status_color}${BOLD}%s Overall Status: %s${NC}     ${BOLD}${PURPLE}║${NC}\n" "$status_emoji" "$status_text"
        printf "${BOLD}${PURPLE}║${NC}            ${BOLD}Health Score: ${status_color}%s%%${NC}            ${BOLD}${PURPLE}║${NC}\n" "$health_score"
        printf "${BOLD}${PURPLE}╚═════════════════════════════════════════════════════════╝${NC}\n"
        echo
        
        # Test statistics with visual indicators
        printf "${BOLD}${BLUE}Test Execution Summary:${NC}\n"
        printf "  ${GREEN}${CHECK} Passed:    %3d tests${NC}\n" "$PASSED_TESTS"
        printf "  ${YELLOW}${WARN} Warnings:  %3d tests${NC}\n" "$WARNING_TESTS"
        printf "  ${RED}${CROSS} Failed:    %3d tests${NC}\n" "$FAILED_TESTS"
        printf "  ${DIM}${INFO} Skipped:   %3d tests${NC}\n" "$SKIPPED_TESTS"
        printf "  ${BOLD}Total:      %3d tests executed in %d seconds${NC}\n" "$TOTAL_TESTS" "$scan_duration"
        echo
        
        # Priority-based issue display
        if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
            printf "${RED}${BOLD}🚨 CRITICAL ISSUES (Immediate Attention Required):${NC}\n"
            for i in "${!CRITICAL_ISSUES[@]}"; do
                printf "  ${RED}%2d. %s${NC}\n" "$((i+1))" "${CRITICAL_ISSUES[$i]}"
            done
            echo
        fi
        
        if [[ ${#HIGH_ISSUES[@]} -gt 0 ]]; then
            printf "${YELLOW}${BOLD}⚠️  HIGH PRIORITY ISSUES:${NC}\n"
            for i in "${!HIGH_ISSUES[@]}"; do
                if [[ $i -lt 5 ]]; then
                    printf "  ${YELLOW}%2d. %s${NC}\n" "$((i+1))" "${HIGH_ISSUES[$i]}"
                fi
            done
            [[ ${#HIGH_ISSUES[@]} -gt 5 ]] && 
                printf "  ${DIM}... and %d more high priority issues${NC}\n" $((${#HIGH_ISSUES[@]} - 5))
            echo
        fi
        
        # Actionable recommendations section
        if [[ ${#FIX_SUGGESTIONS[@]} -gt 0 ]]; then
            printf "${BOLD}${CYAN}🛠️  RECOMMENDED ACTIONS:${NC}\n"
            printf "${CYAN}╭─────────────────────────────────────────────────────────╮${NC}\n"
            
            local fix_count=1
            for fix_key in "${!FIX_SUGGESTIONS[@]}"; do
                # Prioritize critical fixes first
                if [[ "$fix_key" == *"critical"* || "$fix_key" == *"failed"* ]]; then
                    printf "${CYAN}│${NC} ${BOLD}%2d. ${RED}%s:${NC}\n" "$fix_count" "${fix_key^^}"
                    printf "${CYAN}│${NC}   %s\n" "${FIX_SUGGESTIONS[$fix_key]}"
                    printf "${CYAN}│${NC}\n"
                    ((fix_count++))
                fi
            done
            
            for fix_key in "${!FIX_SUGGESTIONS[@]}"; do
                # Show other fixes after critical ones
                if [[ ! "$fix_key" == *"critical"* && ! "$fix_key" == *"failed"* ]]; then
                    printf "${CYAN}│${NC} ${BOLD}%2d. %s:${NC}\n" "$fix_count" "${fix_key^^}"
                    printf "${CYAN}│${NC}   %s\n" "${FIX_SUGGESTIONS[$fix_key]}"
                    printf "${CYAN}│${NC}\n"
                    ((fix_count++))
                fi
                [[ $fix_count -gt 8 ]] && break
            done
            
            printf "${CYAN}╰─────────────────────────────────────────────────────────╯${NC}\n"
            echo
        fi
        
        # Hardware-specific recommendations with detection checks
        echo
        printf "${BOLD}${PURPLE}🔧 HARDWARE-SPECIFIC RECOMMENDATIONS:${NC}\n"
        
        # Check for NVIDIA issues
        if command_exists lspci && lspci 2>/dev/null | grep -qi "nvidia"; then
            printf "• ${CYAN}NVIDIA Graphics:${NC}\n"
            printf "  - Install proprietary driver: ${BOLD}sudo apt install nvidia-driver-535${NC}\n"
            printf "  - Blacklist nouveau: ${BOLD}sudo bash -c 'echo \"blacklist nouveau\" > /etc/modprobe.d/blacklist-nouveau.conf'${NC}\n"
            printf "  - Update initramfs: ${BOLD}sudo update-initramfs -u${NC}\n"
            echo
        fi
        
        # Check for Bluetooth issues
        if command_exists lsusb && lsusb 2>/dev/null | grep -qi "bluetooth"; then
            printf "• ${CYAN}Bluetooth Hardware:${NC}\n"
            printf "  - Install firmware: ${BOLD}sudo apt install bluez-firmware${NC}\n"
            printf "  - Add kernel parameter: ${BOLD}btusb.enable_autosuspend=0${NC} to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub\n"
            printf "  - Update GRUB: ${BOLD}sudo update-grub${NC}\n"
            echo
        fi
        
        # Check for touchpad issues
        if command_exists dmesg && dmesg 2>/dev/null | grep -qi "i2c_hid.*elan"; then
            printf "• ${CYAN}ELAN Touchpad:${NC}\n"
            printf "  - Install drivers: ${BOLD}sudo apt install xserver-xorg-input-synaptics${NC}\n"
            printf "  - Add kernel parameter: ${BOLD}i2c_hid.use_polling_mode=1${NC} to GRUB_CMDLINE_LINUX_DEFAULT\n"
            printf "  - Update GRUB: ${BOLD}sudo update-grub${NC}\n"
            echo
        fi
        
        # Check for WiFi issues
        if command_exists lspci && lspci 2>/dev/null | grep -qi "network"; then
            printf "• ${CYAN}Network Hardware:${NC}\n"
            printf "  - Update drivers: ${BOLD}sudo apt install firmware-iwlwifi firmware-realtek${NC}\n"
            printf "  - Check status: ${BOLD}sudo dmesg | grep -i firmware${NC}\n"
            echo
        fi
    fi
    
    # Maintenance checklist
    echo
    printf "${BOLD}${GREEN}📋 SYSTEM MAINTENANCE CHECKLIST:${NC}\n"
    printf "□ Run system updates: ${BOLD}sudo apt update && sudo apt upgrade${NC}\n"
    printf "□ Clean package cache: ${BOLD}sudo apt autoremove && sudo apt clean${NC}\n"
    printf "□ Check disk space: ${BOLD}df -h${NC}\n"
    printf "□ Review system logs: ${BOLD}sudo journalctl -p 3 -b${NC}\n"
    printf "□ Update firmware: ${BOLD}sudo apt install firmware-linux firmware-linux-nonfree${NC}\n"
    printf "□ Restart failed services: ${BOLD}sudo systemctl restart [service]${NC}\n"
    
    # Emergency commands
    echo
    printf "${BOLD}${RED}🚨 EMERGENCY COMMANDS (if system is unstable):${NC}\n"
    printf "• Force filesystem check: ${BOLD}sudo fsck -f /dev/[device]${NC}\n"
    printf "• Emergency mode: ${BOLD}sudo systemctl rescue${NC}\n"
    printf "• Safe reboot: ${BOLD}sudo systemctl reboot${NC}\n"
    printf "• Check hardware errors: ${BOLD}sudo dmesg | grep -i error${NC}\n"
    
    # Final summary
    echo
    printf "${BOLD}${PURPLE}📊 Diagnostic Complete - $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
    printf "${DIM}Comprehensive system scan completed in %d seconds${NC}\n" "$scan_duration"
    printf "${DIM}For additional help, consult: /var/log/syslog or journalctl -xe${NC}\n"
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
    run_uptime_analysis  # Replaced the inline uptime check with this function
    generate_summary_report
    
    # Enhanced exit code handling
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        exit 3  # Critical system issues
    elif [[ $FAILED_TESTS -gt $PASSED_TESTS ]]; then
        exit 2  # More failures than passes
    elif [[ ${#HIGH_ISSUES[@]} -gt 0 ]]; then
        exit 1  # High priority issues
    else
        exit 0  # System healthy
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
