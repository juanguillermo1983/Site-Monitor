#!/bin/bash

################################################################################
# Script: check-url.sh
# Descripción: Monitorea sitios web y muestra resumen de conexión (sin InfluxDB)
# Uso: ./check-url.sh [--once|--daemon|--test]
################################################################################

set -o pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Directorio del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cargar configuración
if [ ! -f "${SCRIPT_DIR}/config.sh" ]; then
    echo -e "${RED}[ERROR]${NC} Archivo config.sh no encontrado"
    exit 1
fi

source "${SCRIPT_DIR}/config.sh"

# Crear directorio de logs si no existe
mkdir -p "$LOG_DIR"

################################################################################
# Funciones de utilidad
################################################################################

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    if [ "$VERBOSE" = true ]; then
        case $level in
            ERROR)   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
            WARN)    echo -e "${YELLOW}[WARN]${NC} $message" >&2 ;;
            SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
            INFO)    echo -e "${BLUE}[INFO]${NC} $message" ;;
        esac
    fi
}

check_dependencies() {
    local deps=("curl" "date")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log ERROR "Dependencias faltantes: ${missing[*]}"
        echo -e "${RED}[ERROR]${NC} Instalar: sudo apt-get install ${missing[*]}"
        exit 1
    fi
}

load_targets() {
    if [ ! -f "$TARGETS_FILE" ]; then
        log ERROR "Archivo de targets no encontrado: $TARGETS_FILE"
        exit 1
    fi

    TARGETS=()
    while IFS= read -r line; do
        TARGETS+=("$line")
    done < <(grep -v '^#' "$TARGETS_FILE" | grep -v '^[[:space:]]*$')

    if [ ${#TARGETS[@]} -eq 0 ]; then
        log ERROR "No hay targets configurados en $TARGETS_FILE"
        exit 1
    fi

    log INFO "Cargados ${#TARGETS[@]} sitios para monitorear"
}

################################################################################
# Función de chequeo (sin envío a InfluxDB)
################################################################################

check_site() {
    local target_line="$1"
    local url=$(echo "$target_line" | cut -d'|' -f1)
    local site_name=$(echo "$target_line" | cut -d'|' -f2)

    local status=0
    local http_code=0
    local response_time=0
    local dns_time=0
    local connect_time=0
    local ssl_time=0
    local total_time=0
    local size_download=0
    local error_msg=""

    local curl_opts=(
        --silent
        --output /dev/null
        --max-time "$CHECK_TIMEOUT"
        --write-out "%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_total}|%{size_download}"
        --user-agent "$USER_AGENT"
    )

    if [ "$FOLLOW_REDIRECTS" = true ]; then
        curl_opts+=(--location --max-redirs "$MAX_REDIRECTS")
    fi

    if [ "$VERIFY_SSL" = false ]; then
        curl_opts+=(--insecure)
    fi

    local attempt=0
    local success=false

    while [ $attempt -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        attempt=$((attempt + 1))

        local curl_output
        local curl_exit

        curl_output=$(curl "${curl_opts[@]}" "$url" 2>/tmp/curl_error)
        curl_exit=$?

        if [ $curl_exit -eq 0 ]; then
            http_code=0; dns_time=0; connect_time=0; ssl_time=0; total_time=0; size_download=0

            IFS='|' read -r http_code dns_time connect_time ssl_time total_time size_download <<< "$curl_output"

            if [[ "$http_code" =~ ^[2-3][0-9]{2}$ ]]; then
                status=1
                success=true
                response_time=$total_time
                log SUCCESS "$site_name está UP (HTTP $http_code, ${total_time}s)"
            else
                error_msg="HTTP $http_code"
                log WARN "$site_name retornó código no exitoso: $http_code (intento $attempt/$MAX_RETRIES)"
            fi
        else
            case $curl_exit in
                6)  error_msg="DNS resolution failed" ;;
                7)  error_msg="Connection refused" ;;
                28) error_msg="Timeout" ;;
                35) error_msg="SSL handshake failed" ;;
                52) error_msg="Empty reply from server" ;;
                *)  error_msg="Curl error $curl_exit" ;;
            esac
            log WARN "$site_name falló: $error_msg (intento $attempt/$MAX_RETRIES)"
        fi

        if [ "$success" = false ] && [ $attempt -lt $MAX_RETRIES ]; then
            sleep $RETRY_DELAY
        fi
    done

    if [ "$success" = false ]; then
        status=0
        log ERROR "$site_name está DOWN después de $MAX_RETRIES intentos: $error_msg"
    fi

    # Retornar resultados como string delimitado
    echo "${site_name}|${url}|${status}|${http_code}|${total_time}|${dns_time}|${connect_time}|${ssl_time}|${size_download}|${error_msg}"
}

################################################################################
# Resumen de resultados
################################################################################

print_summary() {
    local results=("$@")
    local up_count=0
    local down_count=0
    local total=${#results[@]}
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           RESUMEN DE MONITOREO DE SITIOS — ${timestamp}        ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${NC} %-20s %-6s %-6s %-10s %-10s %-18s ${CYAN}║${NC}\n" \
        "SITIO" "STATUS" "HTTP" "TIEMPO(s)" "DNS(s)" "ERROR"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"

    for result in "${results[@]}"; do
        IFS='|' read -r site_name url status http_code total_time dns_time connect_time ssl_time size_download error_msg <<< "$result"

        local status_label
        local status_color
        if [ "$status" = "1" ]; then
            status_label="UP"
            status_color="${GREEN}"
            up_count=$((up_count + 1))
        else
            status_label="DOWN"
            status_color="${RED}"
            down_count=$((down_count + 1))
        fi

        printf "${CYAN}║${NC} %-20s ${status_color}%-6s${NC} %-6s %-10s %-10s %-18s ${CYAN}║${NC}\n" \
            "${site_name:0:20}" \
            "$status_label" \
            "$http_code" \
            "$total_time" \
            "$dns_time" \
            "${error_msg:0:18}"
    done

    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"

    local summary_color="${GREEN}"
    [ $down_count -gt 0 ] && summary_color="${RED}"

    printf "${CYAN}║${NC}  Total: %-4s  ${GREEN}UP: %-4s${NC}  ${RED}DOWN: %-4s${NC}%41s${CYAN}║${NC}\n" \
        "$total" "$up_count" "$down_count" ""
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

################################################################################
# Modos de ejecución
################################################################################

run_once() {
    log INFO "==== Iniciando chequeo único de sitios ===="
    load_targets

    local results=()
    for target in "${TARGETS[@]}"; do
        result=$(check_site "$target")
        results+=("$result")
    done

    print_summary "${results[@]}"
    log INFO "==== Chequeo completado ===="
}

run_daemon() {
    log INFO "==== Iniciando modo daemon (intervalo: ${CHECK_INTERVAL}s) ===="

    while true; do
        load_targets

        local results=()
        for target in "${TARGETS[@]}"; do
            result=$(check_site "$target")
            results+=("$result")
        done

        print_summary "${results[@]}"
        log INFO "--- Ciclo completado. Esperando ${CHECK_INTERVAL}s ----"
        sleep "$CHECK_INTERVAL"
    done
}

run_test() {
    echo -e "${BLUE}=== Modo Test ===${NC}"
    echo ""

    echo -e "${YELLOW}[1/3]${NC} Verificando dependencias..."
    check_dependencies
    echo -e "${GREEN}✓${NC} Todas las dependencias instaladas"
    echo ""

    echo -e "${YELLOW}[2/3]${NC} Verificando archivos..."
    [ -f "${SCRIPT_DIR}/config.sh" ] && echo -e "${GREEN}✓${NC} config.sh encontrado" || echo -e "${RED}✗${NC} config.sh NO encontrado"
    [ -f "$TARGETS_FILE" ]           && echo -e "${GREEN}✓${NC} targets encontrado"   || echo -e "${RED}✗${NC} targets NO encontrado"
    echo ""

    echo -e "${YELLOW}[3/3]${NC} Cargando targets..."
    load_targets
    for target in "${TARGETS[@]}"; do
        local url=$(echo "$target" | cut -d'|' -f1)
        local name=$(echo "$target" | cut -d'|' -f2)
        echo -e "  ${GREEN}✓${NC} $name - $url"
    done
    echo ""

    echo -e "${BLUE}=== Test completado ===${NC}"
    echo ""
    echo "Para ejecutar el monitoreo:"
    echo "  Una vez:   ./check-url.sh --once"
    echo "  Continuo:  ./check-url.sh --daemon"
}

show_usage() {
    cat << EOF
Uso: $0 [MODO]

Monitoreo de sitios web con resumen de conexión (sin envío a InfluxDB).

MODOS:
  --once          Ejecuta un chequeo único de todos los sitios
  --daemon        Ejecuta en modo continuo
  --test          Verifica configuración y lista targets
  -h, --help      Muestra esta ayuda

ARCHIVOS:
  config.sh       Configuración centralizada
  targets         Lista de sitios a monitorear
  logs/           Directorio de logs

EOF
}

################################################################################
# Main
################################################################################

main() {
    local mode="${1:---once}"

    check_dependencies

    case "$mode" in
        --once)   run_once ;;
        --daemon) run_daemon ;;
        --test)   run_test ;;
        -h|--help) show_usage ;;
        *)
            echo -e "${RED}[ERROR]${NC} Modo desconocido: $mode"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
