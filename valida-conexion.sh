#!/bin/bash

################################################################################
# Script: valida-conexion.sh
# Descripción: Diagnóstico de conectividad para sitios con fallo
# Uso: ./valida-conexion.sh [url1] [url2] ...
#      ./valida-conexion.sh  (sin args usa TARGETS del targets.example)
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT=10
REPORT_FILE="${SCRIPT_DIR}/diagnostico-$(date '+%Y%m%d-%H%M%S').log"

log() { echo -e "$@" | tee -a "$REPORT_FILE"; }

separator() {
    log "${CYAN}────────────────────────────────────────────────────────${NC}"
}

################################################################################
# Diagnósticos individuales
################################################################################

check_dns() {
    local host="$1"
    log "\n${YELLOW}[DNS]${NC} Resolviendo $host ..."

    if command -v dig &>/dev/null; then
        local result=$(dig +short "$host" 2>&1)
        if [ -n "$result" ]; then
            log "${GREEN}✓ DNS OK${NC} → $result"
            return 0
        else
            log "${RED}✗ DNS FALLO${NC} — sin respuesta para $host"
            return 1
        fi
    else
        local result=$(getent hosts "$host" 2>/dev/null || nslookup "$host" 2>/dev/null | grep Address | tail -1)
        if [ -n "$result" ]; then
            log "${GREEN}✓ DNS OK${NC} → $result"
            return 0
        else
            log "${RED}✗ DNS FALLO${NC} — no se pudo resolver $host"
            return 1
        fi
    fi
}

check_ping() {
    local host="$1"
    log "\n${YELLOW}[PING]${NC} Probando ICMP a $host ..."

    if ping -c 3 -W 2 "$host" &>/dev/null; then
        local rtt=$(ping -c 3 -W 2 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
        log "${GREEN}✓ PING OK${NC} — RTT avg: ${rtt}ms"
        return 0
    else
        log "${YELLOW}⚠ PING sin respuesta${NC} — puede estar bloqueado por firewall (no determinante)"
        return 1
    fi
}

check_port() {
    local host="$1"
    local port="$2"
    log "\n${YELLOW}[TCP:${port}]${NC} Verificando puerto $port en $host ..."

    if command -v nc &>/dev/null; then
        if nc -zw "$TIMEOUT" "$host" "$port" 2>/dev/null; then
            log "${GREEN}✓ PUERTO $port ABIERTO${NC}"
            return 0
        else
            log "${RED}✗ PUERTO $port CERRADO o FILTRADO${NC} — posible firewall"
            return 1
        fi
    elif command -v bash &>/dev/null; then
        if timeout "$TIMEOUT" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
            log "${GREEN}✓ PUERTO $port ABIERTO${NC}"
            return 0
        else
            log "${RED}✗ PUERTO $port CERRADO o FILTRADO${NC}"
            return 1
        fi
    fi
}

check_curl() {
    local url="$1"
    log "\n${YELLOW}[CURL]${NC} Probando HTTP/S a $url ..."

    local output
    output=$(curl -s \
        --max-time "$TIMEOUT" \
        --insecure \
        --location \
        --write-out "http_code=%{http_code}|dns=%{time_namelookup}|connect=%{time_connect}|ssl=%{time_appconnect}|total=%{time_total}|size=%{size_download}" \
        --output /dev/null \
        "$url" 2>&1)

    local curl_exit=$?

    if [ $curl_exit -eq 0 ]; then
        local http_code=$(echo "$output" | grep -o 'http_code=[^|]*' | cut -d= -f2)
        local dns=$(echo "$output"     | grep -o 'dns=[^|]*'      | cut -d= -f2)
        local connect=$(echo "$output" | grep -o 'connect=[^|]*'  | cut -d= -f2)
        local ssl=$(echo "$output"     | grep -o 'ssl=[^|]*'      | cut -d= -f2)
        local total=$(echo "$output"   | grep -o 'total=[^|]*'    | cut -d= -f2)

        log "  HTTP Code : $http_code"
        log "  DNS       : ${dns}s"
        log "  Connect   : ${connect}s"
        log "  SSL       : ${ssl}s"
        log "  Total     : ${total}s"

        if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]]; then
            log "${GREEN}✓ CURL OK${NC} — HTTP $http_code"
        else
            log "${RED}✗ CURL FALLO${NC} — HTTP $http_code"
        fi
    else
        local error_desc
        case $curl_exit in
            6)  error_desc="DNS no resuelto" ;;
            7)  error_desc="Conexión rechazada (Connection refused)" ;;
            28) error_desc="Timeout — firewall descartando paquetes o servidor lento" ;;
            35) error_desc="SSL handshake fallido — certificado o protocolo incompatible" ;;
            51) error_desc="Certificado SSL no válido" ;;
            52) error_desc="Respuesta vacía del servidor" ;;
            56) error_desc="Fallo en recepción de datos" ;;
            *)  error_desc="Error curl código $curl_exit" ;;
        esac
        log "${RED}✗ CURL FALLO${NC} — $error_desc"
    fi

    return $curl_exit
}

check_traceroute() {
    local host="$1"
    log "\n${YELLOW}[RUTA]${NC} Trazando ruta a $host ..."

    if command -v traceroute &>/dev/null; then
        log "$(traceroute -m 15 -w 2 "$host" 2>&1 | head -20)"
    elif command -v tracepath &>/dev/null; then
        log "$(tracepath -m 15 "$host" 2>&1 | head -20)"
    else
        log "${YELLOW}⚠ traceroute/tracepath no disponible${NC}"
    fi
}

check_ssl() {
    local host="$1"
    log "\n${YELLOW}[SSL]${NC} Verificando certificado de $host ..."

    if command -v openssl &>/dev/null; then
        local ssl_info
        ssl_info=$(echo | timeout "$TIMEOUT" openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null)

        local subject=$(echo "$ssl_info" | openssl x509 -noout -subject 2>/dev/null)
        local dates=$(echo "$ssl_info"   | openssl x509 -noout -dates  2>/dev/null)
        local issuer=$(echo "$ssl_info"  | openssl x509 -noout -issuer 2>/dev/null)

        if [ -n "$subject" ]; then
            log "${GREEN}✓ Certificado encontrado${NC}"
            log "  $subject"
            log "  $dates"
            log "  $issuer"
        else
            log "${RED}✗ No se pudo obtener certificado SSL${NC}"
        fi
    else
        log "${YELLOW}⚠ openssl no disponible${NC}"
    fi
}

################################################################################
# Diagnóstico completo por host
################################################################################

diagnose_host() {
    local raw_url="$1"

    # Extraer host de la URL (maneja con o sin https://)
    local host
    if [[ "$raw_url" =~ ^https?:// ]]; then
        host=$(echo "$raw_url" | sed 's|https\?://||' | cut -d'/' -f1)
        local url="$raw_url"
    else
        host="$raw_url"
        local url="https://${raw_url}"
    fi

    separator
    log "${BLUE}▶ DIAGNÓSTICO: $host${NC}"
    log "  URL: $url"
    log "  Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
    separator

    local dns_ok=0
    check_dns "$host"    && dns_ok=1
    check_ping "$host"
    check_port "$host" 443
    check_port "$host" 80
    check_ssl  "$host"
    check_curl "$url"

    if [ $dns_ok -eq 0 ]; then
        log "\n${RED}► DIAGNÓSTICO: falla en DNS — el servidor no puede resolver el nombre.${NC}"
        log "  Verificar: /etc/resolv.conf, servidor DNS de la red, reglas de firewall para UDP/53"
    fi

    check_traceroute "$host"
    separator
}

################################################################################
# Main
################################################################################

main() {
    log "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    log "${CYAN}║         DIAGNÓSTICO DE CONECTIVIDAD DE SITIOS        ║${NC}"
    log "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    log "Reporte guardado en: $REPORT_FILE\n"

    if [ $# -gt 0 ]; then
        for url in "$@"; do
            diagnose_host "$url"
        done
    else
        # Sin argumentos: leer targets.example o targets
        local targets_file="${SCRIPT_DIR}/targets"
        [ ! -f "$targets_file" ] && targets_file="${SCRIPT_DIR}/targets.example"

        while IFS= read -r line; do
            local url=$(echo "$line" | cut -d'|' -f1)
            diagnose_host "$url"
        done < <(grep -v '^#' "$targets_file" | grep -v '^[[:space:]]*$')
    fi

    log "\n${GREEN}Diagnóstico completado. Reporte en: $REPORT_FILE${NC}"
}

main "$@"
