#!/bin/bash
# Q-Config-Backup - Script de respaldo versionado de archivos de configuración
# Autor: Sistema de respaldos automatizado
# Versión: 2.0
# Descripción: CLI en Bash que hace backups versionados de archivos de configuración,
#              guarda .tar.gz con timestamp, verifica checksum y rota backups.

# Configuración de errores estricta
set -euo pipefail

# Variables de configuración por defecto
BACKUP_DIR="${BACKUP_DIR:-$HOME/.config-backups}"
MAX_BACKUPS="${MAX_BACKUPS:-5}"
LOG_FILE="${LOG_FILE:-/var/log/q-config-backup.log}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/q-config-backup.conf}"
SOURCE_PATH="${SOURCE_PATH:-/etc}"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para mostrar ayuda
mostrar_ayuda() {
    cat << EOF
q-config-backup - Sistema de respaldos versionados

USO:
    $0 [OPCIÓN] [COMANDO] [ARGUMENTOS]

COMANDOS:
    crear                    Crear un nuevo respaldo
    listar                   Listar respaldos disponibles  
    restaurar <archivo>      Restaurar desde un respaldo específico
    configurar               Configurar las opciones del script
    ayuda                    Mostrar esta ayuda

OPCIONES:
    -d, --directorio <dir>   Directorio de respaldos (por defecto: $BACKUP_DIR)
    -m, --max <num>          Número máximo de respaldos a mantener (por defecto: $MAX_BACKUPS)
    -s, --origen <path>      Directorio fuente a respaldar (por defecto: $SOURCE_PATH)
    -v, --verboso            Modo verboso
    -h, --ayuda             Mostrar esta ayuda

EJEMPLOS:
    $0 crear
    $0 listar
    $0 restaurar backup_20241226123456.tar.gz
    $0 -d /mis/respaldos -m 10 crear

ARCHIVOS DE CONFIGURACIÓN:
    $CONFIG_FILE

Para más información, consulte el archivo README.md
EOF
}

# Función de logging mejorada
log() {
    local nivel="${2:-INFO}"
    local mensaje="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Crear directorio de log si no existe
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    # Escribir al log
    echo "[$timestamp] [$nivel] $mensaje" >> "$LOG_FILE" 2>/dev/null || {
        echo -e "${RED}Error: No se puede escribir al archivo de log: $LOG_FILE${NC}" >&2
        return 1
    }
    
    # Mostrar en consola según el nivel
    case "$nivel" in
        "ERROR")
            echo -e "${RED}ERROR: $mensaje${NC}" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}ADVERTENCIA: $mensaje${NC}" >&2
            ;;
        "SUCCESS")
            echo -e "${GREEN}ÉXITO: $mensaje${NC}"
            ;;
        "INFO")
            [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${BLUE}INFO: $mensaje${NC}"
            ;;
    esac
}

# Función para validar prerrequisitos
validar_prerrequisitos() {
    local errores=0
    
    # Verificar comandos requeridos
    for cmd in tar sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "Comando requerido no encontrado: $cmd" "ERROR"
            ((errores++))
        fi
    done
    
    # Verificar permisos del directorio de respaldos
    if [[ ! -d "$BACKUP_DIR" ]]; then
        if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
            log "No se puede crear el directorio de respaldos: $BACKUP_DIR" "ERROR"
            ((errores++))
        else
            log "Directorio de respaldos creado: $BACKUP_DIR" "INFO"
        fi
    fi
    
    # Verificar permisos de escritura
    if [[ ! -w "$BACKUP_DIR" ]]; then
        log "Sin permisos de escritura en: $BACKUP_DIR" "ERROR"
        ((errores++))
    fi
    
    # Verificar que existe el directorio fuente
    if [[ ! -d "$SOURCE_PATH" ]]; then
        log "Directorio fuente no existe: $SOURCE_PATH" "ERROR"
        ((errores++))
    fi
    
    if [[ $errores -gt 0 ]]; then
        log "Se encontraron $errores errores en los prerrequisitos" "ERROR"
        exit 1
    fi
}

# Función para cargar configuración
cargar_configuracion() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Cargar archivo de configuración de forma segura
        while IFS='=' read -r clave valor; do
            # Ignorar comentarios y líneas vacías
            [[ "$clave" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$clave" ]] && continue
            
            # Limpiar espacios en blanco
            clave=$(echo "$clave" | tr -d '[:space:]')
            valor=$(echo "$valor" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Asignar variables válidas
            case "$clave" in
                BACKUP_DIR) BACKUP_DIR="$valor" ;;
                MAX_BACKUPS) 
                    if [[ "$valor" =~ ^[0-9]+$ ]] && [[ "$valor" -gt 0 ]]; then
                        MAX_BACKUPS="$valor"
                    else
                        log "Valor inválido para MAX_BACKUPS: $valor" "WARN"
                    fi
                    ;;
                SOURCE_PATH) SOURCE_PATH="$valor" ;;
                LOG_FILE) LOG_FILE="$valor" ;;
            esac
        done < "$CONFIG_FILE"
        log "Configuración cargada desde: $CONFIG_FILE" "INFO"
    fi
}
crear_respaldo() {
    log "Iniciando creación de respaldo..." "INFO"
    
    local timestamp=$(date +'%Y%m%d%H%M%S')
    local backup_file="$BACKUP_DIR/backup_$timestamp.tar.gz"
    local temp_dir
    
    # Crear directorio temporal para operaciones
    temp_dir=$(mktemp -d) || {
        log "Error al crear directorio temporal" "ERROR"
        return 1
    }
    
    # Función de limpieza
    cleanup() {
        [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf "$temp_dir"
    }
    trap cleanup EXIT
    
    # Verificar espacio disponible
    local espacio_requerido=$(du -sb "$SOURCE_PATH" 2>/dev/null | cut -f1)
    local espacio_disponible=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4*1024}')
    
    if [[ $espacio_requerido -gt $espacio_disponible ]]; then
        log "Espacio insuficiente. Requerido: $espacio_requerido bytes, Disponible: $espacio_disponible bytes" "ERROR"
        return 1
    fi
    
    # Crear respaldo con manejo de errores mejorado
    log "Creando archivo de respaldo: $backup_file" "INFO"
    if ! tar -czf "$backup_file" -C "$(dirname "$SOURCE_PATH")" "$(basename "$SOURCE_PATH")" 2>"$temp_dir/tar_error.log"; then
        local error_msg=$(cat "$temp_dir/tar_error.log" 2>/dev/null || echo "Error desconocido")
        log "Error al crear respaldo: $error_msg" "ERROR"
        [[ -f "$backup_file" ]] && rm -f "$backup_file"
        return 1
    fi
    
    # Verificar que el archivo se creó correctamente
    if [[ ! -f "$backup_file" || ! -s "$backup_file" ]]; then
        log "El archivo de respaldo está vacío o no se creó correctamente" "ERROR"
        return 1
    fi
    
    # Generar checksum
    log "Generando checksum..." "INFO"
    local checksum
    if ! checksum=$(sha256sum "$backup_file" | awk '{print $1}'); then
        log "Error al generar checksum" "ERROR"
        [[ -f "$backup_file" ]] && rm -f "$backup_file"
        return 1
    fi
    
    # Guardar checksum
    echo "$checksum  $(basename "$backup_file")" > "$backup_file.sha256" || {
        log "Error al guardar checksum" "ERROR"
        [[ -f "$backup_file" ]] && rm -f "$backup_file"
        return 1
    }
    
    # Obtener información del respaldo
    local tamaño=$(du -h "$backup_file" | cut -f1)
    local archivos=$(tar -tzf "$backup_file" | wc -l)
    
    log "Respaldo creado exitosamente: $backup_file (Tamaño: $tamaño, Archivos: $archivos)" "SUCCESS"
    log "Checksum SHA256: $checksum" "INFO"
    
    rotar_respaldos
}
rotate_backups() {
    BACKUP_COUNT=$(ls -1 $BACKUP_DIR/backup_*.tar.gz 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        OLDEST_BACKUP=$(ls -1t $BACKUP_DIR/backup_*.tar.gz | tail -n 1)
        rm -f "$OLDEST_BACKUP" "$OLDEST_BACKUP.sha256"
        log "Oldest backup removed: $OLDEST_BACKUP"
    fi
}
list_backups() {
    ls -1t $BACKUP_DIR/backup_*.tar.gz 2>/dev/null || echo "No backups found."
}
restore_backup() {
    if [ -z "$1" ]; then
        echo "Usage: $0 restore <backup_file>"
        exit 1
    fi
    BACKUP_FILE="$1"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "Backup file not found: $BACKUP_FILE"
        exit 1
    fi
    sha256sum -c "$BACKUP_FILE.sha256" || { log "Checksum verification failed"; exit 1; }
    tar -xzf "$BACKUP_FILE" -C / || { log "Restore failed"; exit 1; }
    log "Backup restored: $BACKUP_FILE"
}
case "$1" in
    create)
        create_backup
        ;;
    list)
        list_backups
        ;;
    restore)
        restore_backup "$2"
        ;;
    *)
        echo "Usage: $0 {create|list|restore <backup_file>}"
        exit 1
        ;;
esac
