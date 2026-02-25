#!/usr/bin/env bash
# deploy.sh – Konfigurera Raspberry Pi som nätverksprintserver
#
# Användning:
#   1. Kopiera config.env.template till config.env och fyll i värden
#   2. Kör: sudo bash deploy.sh
#
# Loggas till /var/log/printserver-deploy.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/printserver-deploy.log"

# ── Färgkoder ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Loggning ─────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] VARNING: $*"
    echo -e "${YELLOW}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] FEL: $*"
    echo -e "${RED}${msg}${NC}" >&2
    echo "$msg" >> "$LOG_FILE"
    exit 1
}

step() {
    local msg="══════════════════════════════════════════════"
    echo -e "${CYAN}${BOLD}$msg${NC}"
    echo -e "${CYAN}${BOLD}  $*${NC}"
    echo -e "${CYAN}${BOLD}$msg${NC}"
    echo "=== $* ===" >> "$LOG_FILE"
}

# ── Kontrollera root ──────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Det här scriptet måste köras som root: sudo bash deploy.sh${NC}" >&2
        exit 1
    fi
}

# ── Ladda och validera konfiguration ─────────────────────────────────────────
load_config() {
    local config_file="$SCRIPT_DIR/config.env"

    if [[ ! -f "$config_file" ]]; then
        error "Konfigurationsfil saknas: $config_file
Kopiera mallen och fyll i värden:
  cp config.env.template config.env
  nano config.env"
    fi

    # shellcheck source=/dev/null
    source "$config_file"

    # Validera obligatoriska variabler
    local required_vars=(
        WIFI_SSID WIFI_PASSWORD STATIC_IP SUBNET_PREFIX GATEWAY DNS
        WIFI_INTERFACE HOSTNAME TIMEZONE LOCALE CUPS_ADMIN_USER
        SAMBA_WORKGROUP SAMBA_SERVER_STRING
        INSTALL_HPLIP INSTALL_GUTENPRINT INSTALL_EPSON
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Följande obligatoriska variabler saknas i config.env: ${missing[*]}"
    fi

    log "Konfiguration laddad från $config_file"
}

# ── Steg 1: Uppdatera system ──────────────────────────────────────────────────
step_update() {
    step "Steg 1/9: Systemuppdatering"
    log "Uppdaterar paketlistor och systemet..."
    apt update -y >> "$LOG_FILE" 2>&1
    apt upgrade -y >> "$LOG_FILE" 2>&1
    apt install -y curl git ufw >> "$LOG_FILE" 2>&1
    log "Systemuppdatering klar."
}

# ── Steg 2: Hostname, timezone, locale ───────────────────────────────────────
step_system() {
    step "Steg 2/9: Systeminställningar"

    log "Sätter hostname till: $HOSTNAME"
    hostnamectl set-hostname "$HOSTNAME"
    # Uppdatera /etc/hosts
    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
    else
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1    $HOSTNAME/" /etc/hosts
    fi

    log "Sätter tidszon till: $TIMEZONE"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone

    log "Sätter locale till: $LOCALE"
    # Aktivera locale i /etc/locale.gen om den inte redan finns
    if ! locale -a 2>/dev/null | grep -qi "${LOCALE%%.*}"; then
        sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen || true
        grep -qF "${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
        locale-gen >> "$LOG_FILE" 2>&1
    fi
    # Använd update-locale istället för localectl – fungerar korrekt via sudo/SSH
    update-locale "LANG=$LOCALE"

    log "Systeminställningar klara."
}

# ── Steg 3: Statisk WiFi via NetworkManager ───────────────────────────────────
step_network() {
    step "Steg 3/9: Nätverkskonfiguration (statisk IP via nmcli)"

    warn "Om SSH körs via WiFi tappar anslutningen när IP ändras. Kör deploy.sh inuti tmux så fortsätter scriptet köra. Reconnecta med: ssh ${CUPS_ADMIN_USER}@${STATIC_IP} && tmux attach -t deploy"

    if nmcli connection show "$WIFI_SSID" &>/dev/null; then
        log "Modifierar befintlig WiFi-anslutning: $WIFI_SSID"
        nmcli connection modify "$WIFI_SSID" \
            ipv4.method manual \
            ipv4.addresses "${STATIC_IP}/${SUBNET_PREFIX}" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "$DNS"
    else
        log "Skapar ny WiFi-anslutning: $WIFI_SSID"
        nmcli connection add type wifi con-name "$WIFI_SSID" \
            ifname "$WIFI_INTERFACE" ssid "$WIFI_SSID" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASSWORD" \
            ipv4.method manual \
            ipv4.addresses "${STATIC_IP}/${SUBNET_PREFIX}" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "$DNS" \
            connection.autoconnect yes
    fi

    log "Aktiverar anslutning..."
    nmcli connection up "$WIFI_SSID" >> "$LOG_FILE" 2>&1 || true

    log "Nätverkskonfiguration klar. Statisk IP: ${STATIC_IP}/${SUBNET_PREFIX}"
}

# ── Steg 4: Installera paket ──────────────────────────────────────────────────
step_install_packages() {
    step "Steg 4/9: Installerar paket"

    local packages=(
        cups cups-client cups-filters
        avahi-daemon libnss-mdns
        samba smbclient
        openprinting-ppds foomatic-db-compressed-ppds
        ufw tmux
    )

    if [[ "${INSTALL_HPLIP,,}" == "true" ]]; then
        log "Lägger till HPLIP (HP-drivrutiner)"
        packages+=(hplip)
    fi

    if [[ "${INSTALL_GUTENPRINT,,}" == "true" ]]; then
        log "Lägger till Gutenprint-drivrutiner"
        packages+=(printer-driver-gutenprint)
    fi

    if [[ "${INSTALL_EPSON,,}" == "true" ]]; then
        log "Lägger till Epson ESCPR-drivrutiner"
        packages+=(printer-driver-escpr)
    fi

    log "Installerar: ${packages[*]}"
    apt install -y "${packages[@]}" >> "$LOG_FILE" 2>&1
    log "Paketinstallation klar."
}

# ── Steg 5: Konfigurera CUPS ──────────────────────────────────────────────────
step_configure_cups() {
    step "Steg 5/9: Konfigurerar CUPS"

    local template="$SCRIPT_DIR/config/cupsd.conf.template"
    local dest="/etc/cups/cupsd.conf"

    if [[ ! -f "$template" ]]; then
        error "Mall saknas: $template"
    fi

    log "Kopierar cupsd.conf..."
    cp "$template" "$dest"

    log "Lägger till CUPS-admin-användare: $CUPS_ADMIN_USER"
    usermod -aG lpadmin "$CUPS_ADMIN_USER" 2>/dev/null || \
        warn "Kunde inte lägga till $CUPS_ADMIN_USER i lpadmin-gruppen (användaren kanske inte finns)"

    log "Aktiverar utskriftsdelning och fjärradmin..."
    cupsctl --share-printers --remote-admin --remote-any

    log "CUPS konfigurerad."
}

# ── Steg 6: Konfigurera Samba ─────────────────────────────────────────────────
step_configure_samba() {
    step "Steg 6/9: Konfigurerar Samba"

    local template="$SCRIPT_DIR/config/smb.conf.template"
    local dest="/etc/samba/smb.conf"

    if [[ ! -f "$template" ]]; then
        error "Mall saknas: $template"
    fi

    log "Kopierar och anpassar smb.conf..."
    sed \
        -e "s/{{SAMBA_WORKGROUP}}/$SAMBA_WORKGROUP/g" \
        -e "s/{{SAMBA_SERVER_STRING}}/$SAMBA_SERVER_STRING/g" \
        "$template" > "$dest"

    log "Skapar Samba-spoolkatalog..."
    mkdir -p /var/spool/samba
    chmod 1777 /var/spool/samba

    log "Validerar smb.conf..."
    testparm -s >> "$LOG_FILE" 2>&1 && log "smb.conf validerad OK." || \
        warn "testparm rapporterade varningar – kontrollera $LOG_FILE"

    log "Samba konfigurerad."
}

# ── Steg 7: Konfigurera brandvägg ─────────────────────────────────────────────
step_configure_firewall() {
    step "Steg 7/9: Konfigurerar brandvägg (ufw)"

    log "Återställer och konfigurerar ufw-regler..."
    ufw --force reset >> "$LOG_FILE" 2>&1
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1
    ufw allow ssh >> "$LOG_FILE" 2>&1
    ufw allow 631/tcp   >> "$LOG_FILE" 2>&1  # IPP (CUPS)
    ufw allow 5353/udp  >> "$LOG_FILE" 2>&1  # mDNS (Avahi/Bonjour)
    ufw allow 137/udp   >> "$LOG_FILE" 2>&1  # NetBIOS Name Service
    ufw allow 138/udp   >> "$LOG_FILE" 2>&1  # NetBIOS Datagram
    ufw allow 139/tcp   >> "$LOG_FILE" 2>&1  # NetBIOS Session
    ufw allow 445/tcp   >> "$LOG_FILE" 2>&1  # SMB
    ufw --force enable  >> "$LOG_FILE" 2>&1

    log "Brandvägg konfigurerad:"
    ufw status numbered | tee -a "$LOG_FILE"
}

# ── Steg 8: Aktivera tjänster ──────────────────────────────────────────────────
step_enable_services() {
    step "Steg 8/9: Aktiverar och startar tjänster"

    # Säkerställ att tjänsterna är aktiverade vid boot
    systemctl enable cups avahi-daemon smbd nmbd >> "$LOG_FILE" 2>&1

    # Starta om tjänster med konfigurationsfiler som scriptet kan ha ändrat
    for svc in cups smbd nmbd; do
        log "Startar om $svc..."
        systemctl restart "$svc" >> "$LOG_FILE" 2>&1
    done

    # Starta avahi om den inte redan kör (inga config-ändringar från scriptet)
    systemctl start avahi-daemon >> "$LOG_FILE" 2>&1 || true

    log "Alla tjänster aktiverade och startade."
}

# ── Steg 9: Sammanfattning ────────────────────────────────────────────────────
step_summary() {
    step "Steg 9/9: Deploy klar!"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║        RPi Printserver – Deploy klar!        ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Nätverksinformation:${NC}"
    echo -e "  IP-adress:      ${CYAN}${STATIC_IP}${NC}"
    echo -e "  Hostname:       ${CYAN}${HOSTNAME}.local${NC}"
    echo ""
    echo -e "${BOLD}CUPS utskriftsserver:${NC}"
    echo -e "  Webgränssnitt:  ${CYAN}http://${STATIC_IP}:631${NC}"
    echo -e "  Admin-användare: ${CUPS_ADMIN_USER} (grupp: lpadmin)"
    echo ""
    echo -e "${BOLD}Windows-fildelning (Samba):${NC}"
    echo -e "  Sökväg:         ${CYAN}\\\\${STATIC_IP}${NC}"
    echo ""
    echo -e "${BOLD}Nästa steg – lägg till Zebra-skrivare:${NC}"
    echo -e "  ${CYAN}sudo bash scripts/add-zebra-printer.sh${NC}"
    echo ""
    echo -e "${BOLD}Verifiera tjänster:${NC}"
    echo -e "  ${CYAN}sudo systemctl status cups avahi-daemon smbd${NC}"
    echo ""
    echo -e "${BOLD}Testutskrift ZPL (efter skrivare lagts till):${NC}"
    echo -e "  ${CYAN}printf '^XA^FO50,50^ADN,36,20^FDTest ZPL^FS^XZ' | lpr -P <SKRIVARNAMN>${NC}"
    echo ""
    echo -e "Logg sparad i: ${LOG_FILE}"
    echo ""
}

# ── Huvudprogram ──────────────────────────────────────────────────────────────
main() {
    # Starta om inuti tmux om vi inte redan kör där
    if [[ -z "${TMUX:-}" ]]; then
        if command -v tmux &>/dev/null; then
            echo "Startar deploy inuti tmux-session 'deploy'..."
            echo "Återanslut med: tmux attach -t deploy"
            exec tmux new-session -s deploy "bash '$(realpath "$0")'"
        fi
    fi

    # Initiera loggfil
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   RPi Printserver Deploy – startar...        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    log "Deploy startar. Script: $SCRIPT_DIR/deploy.sh"

    check_root
    load_config

    step_update
    step_system
    step_network
    step_install_packages
    step_configure_cups
    step_configure_samba
    step_configure_firewall
    step_enable_services
    step_summary
}

main "$@"
