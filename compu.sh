#!/bin/bash
# ============================================================
#  SETUP COMPU (WSL) - AUTO CONFIGURADOR
#  Corre esto una sola vez en Ubuntu/WSL.
#  Instala el daemon, el cron, todo solo.
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   COMPU AUTO-SETUP  v1.0             ║${NC}"
echo -e "${BOLD}║   Backup daemon de imágenes          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── 1. Pedir datos ───────────────────────────────────────────
echo -e "${YELLOW}━━━ CONFIGURACIÓN INICIAL ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "  IP Tailscale del celular (ej: 100.x.x.x): " PHONE_IP
read -p "  Usuario Termux del celular (ej: u0_a123): " PHONE_USER
read -p "  Ruta destino en tu compu (ej: /mnt/f/TELEFONO): " DEST_DIR

echo ""
echo -e "  Pega la llave pública del celular (la que mostró setup_termux.sh):"
read -p "  > " PHONE_PUBKEY

echo ""

# Validar que la IP tiene formato Tailscale
if ! echo "$PHONE_IP" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
    err "IP inválida: $PHONE_IP"
fi

# Crear carpeta destino
mkdir -p "$DEST_DIR"
log "Carpeta destino: $DEST_DIR"

# ── 2. Generar llave SSH en la compu ─────────────────────────
info "Configurando llaves SSH..."

SSH_KEY="$HOME/.ssh/id_ed25519_phone_backup"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "backup_daemon@compu" -q
    log "Llave SSH generada: $SSH_KEY"
else
    log "Llave SSH ya existe, skip"
fi

# ── 3. Instalar llave en el celular ──────────────────────────
info "Instalando llave de la compu en el celular..."
SSH_OPTS_SETUP="-p 8022 -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

# Verificar conexión primero
if ! ssh $SSH_OPTS_SETUP -i "$SSH_KEY" "$PHONE_USER@$PHONE_IP" exit 2>/dev/null; then
    # Intentar con password para instalar la llave
    warn "Instalando llave (te pedirá la contraseña de Termux una vez)..."
    
    # Instalar llave pública de la compu en el cel
    ssh-copy-id -p 8022 -i "$SSH_KEY.pub" \
        -o StrictHostKeyChecking=no \
        "$PHONE_USER@$PHONE_IP" || {
        # Si no hay contraseña, intentar agregar la llave manualmente
        warn "ssh-copy-id falló. Intentando método alternativo..."
        cat "$SSH_KEY.pub" | ssh $SSH_OPTS_SETUP \
            "$PHONE_USER@$PHONE_IP" \
            "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null || true
    }
fi

# Instalar también la llave pública del celular en known_hosts
if [ -n "$PHONE_PUBKEY" ]; then
    mkdir -p ~/.ssh
    # Agregar al authorized_keys de la compu (por si acaso)
    if ! grep -qF "$PHONE_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "$PHONE_PUBKEY" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        log "Llave del celular registrada en la compu"
    fi
fi

# Verificar conexión sin contraseña
info "Verificando conexión sin contraseña..."
if ssh -p 8022 -i "$SSH_KEY" \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "$PHONE_USER@$PHONE_IP" exit 2>/dev/null; then
    log "Conexión SSH sin contraseña: OK"
else
    warn "No se pudo verificar conexión sin contraseña."
    warn "Asegúrate que sshd esté corriendo en Termux (comando: sshd)"
fi

# ── 4. Guardar configuración ─────────────────────────────────
CONFIG_FILE="$HOME/.phone_backup.conf"
cat > "$CONFIG_FILE" << CONF
# Configuración del backup daemon
# Generado: $(date '+%Y-%m-%d %H:%M:%S')
PHONE_IP="$PHONE_IP"
PHONE_PORT="8022"
PHONE_USER="$PHONE_USER"
DEST_DIR="$DEST_DIR"
SSH_KEY="$SSH_KEY"
CONF
chmod 600 "$CONFIG_FILE"
log "Configuración guardada en $CONFIG_FILE"

# ── 5. Crear el daemon de backup ─────────────────────────────
DAEMON_PATH="$HOME/recolector_daemon.sh"

cat > "$DAEMON_PATH" << 'DAEMON_EOF'
#!/bin/bash
# ============================================================
#  RECOLECTOR DAEMON
#  No editar manualmente - generado por setup_compu.sh
# ============================================================

# Cargar configuración
source "$HOME/.phone_backup.conf"

LOG="$DEST_DIR/.backup.log"
SSH_OPTS="-p $PHONE_PORT -i $SSH_KEY \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ServerAliveInterval=10"

# ── Función: log con timestamp ────────────────────────────────
_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG"; }

# ── Crear destino si no existe ────────────────────────────────
mkdir -p "$DEST_DIR"

# ── Chequeo silencioso de conectividad ────────────────────────
ping -c 1 -W 3 "$PHONE_IP" > /dev/null 2>&1 || exit 0
ssh $SSH_OPTS "$PHONE_USER@$PHONE_IP" exit 2>/dev/null || exit 0

_log "Celular detectado. Iniciando sync..."

# ── Intentar leer carpetas desde config del cel ──────────────
REMOTE_CONFIG_PATH="storage/shared/.termux_backup_config"
REMOTE_CONFIG=$(ssh $SSH_OPTS "$PHONE_USER@$PHONE_IP" \
    "cat ~/$REMOTE_CONFIG_PATH 2>/dev/null" 2>/dev/null || echo "")

# Parsear carpetas desde config remota
declare -a CARPETAS_REMOTE
if echo "$REMOTE_CONFIG" | grep -q "CARPETAS="; then
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '"' | xargs)
        [[ "$line" =~ ^storage/ ]] && CARPETAS_REMOTE+=("$line")
    done <<< "$(echo "$REMOTE_CONFIG" | sed -n '/^CARPETAS=(/,/^)/p' | grep -v 'CARPETAS\|(^)$')"
fi

# Si no se pudo leer la config remota, usar rutas base + escaneo dinámico
if [ ${#CARPETAS_REMOTE[@]} -eq 0 ]; then
    _log "Sin config remota. Usando escaneo dinámico..."

    # Escanear en el celular qué carpetas existen y tienen archivos
    SCAN_OUTPUT=$(ssh $SSH_OPTS "$PHONE_USER@$PHONE_IP" bash << 'REMOTE_SCAN'
CANDIDATAS=(
    "storage/dcim/Camera"
    "storage/dcim/Screenshots"
    "storage/pictures"
    "storage/downloads"
    "storage/movies"
    "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"
    "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video"
    "storage/shared/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Images"
    "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Images"
    "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Video"
    "storage/shared/Android/media/com.instagram.android/files/videos"
    "storage/shared/Android/media/com.instagram.android/files/images"
    "storage/shared/Android/media/com.facebook.orca/files/Video"
    "storage/shared/Android/media/com.facebook.orca/files/Images"
    "storage/shared/Android/media/com.snapchat.android/files"
    "storage/shared/Android/media/com.twitter.android/Twitter"
    "storage/shared/DCIM"
    "storage/shared/Pictures"
    "storage/shared/Movies"
    "storage/shared/Download"
)
for C in "${CANDIDATAS[@]}"; do
    RUTA="$HOME/$C"
    if [ -d "$RUTA" ]; then
        COUNT=$(find "$RUTA" -maxdepth 3 \
            \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
               -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.gif" \
               -o -iname "*.webp" -o -iname "*.heic" \) \
            2>/dev/null | wc -l)
        [ "$COUNT" -gt 0 ] && echo "$C"
    fi
done
REMOTE_SCAN
    2>/dev/null)

    while IFS= read -r line; do
        [ -n "$line" ] && CARPETAS_REMOTE+=("$line")
    done <<< "$SCAN_OUTPUT"
fi

if [ ${#CARPETAS_REMOTE[@]} -eq 0 ]; then
    _log "No se encontraron carpetas con imágenes. Abortando."
    exit 0
fi

_log "Carpetas a sincronizar: ${#CARPETAS_REMOTE[@]}"

# ── Sync de cada carpeta ──────────────────────────────────────
TOTAL_NUEVOS=0
for DIR in "${CARPETAS_REMOTE[@]}"; do
    DIR_TRIM=$(echo "$DIR" | xargs)
    [ -z "$DIR_TRIM" ] && continue

    # Contar archivos nuevos (dry-run)
    NUEVOS=$(rsync --dry-run -az \
        --include="*.jpg" --include="*.jpeg" --include="*.png" \
        --include="*.mp4" --include="*.mov"  --include="*.gif" \
        --include="*.webp" --include="*.heic" --include="*.3gp" \
        --exclude="*" \
        --ignore-missing-args \
        -e "ssh $SSH_OPTS" \
        "$PHONE_USER@$PHONE_IP:~/$DIR_TRIM/" \
        "$DEST_DIR/" 2>/dev/null | grep "^>" | wc -l || echo 0)

    if [ "$NUEVOS" -gt 0 ]; then
        _log "  Syncing ~/$DIR_TRIM ($NUEVOS archivos nuevos)..."
        rsync -az \
            --include="*.jpg" --include="*.jpeg" --include="*.png" \
            --include="*.mp4" --include="*.mov"  --include="*.gif" \
            --include="*.webp" --include="*.heic" --include="*.3gp" \
            --exclude="*" \
            --remove-source-files \
            --ignore-missing-args \
            -e "ssh $SSH_OPTS" \
            "$PHONE_USER@$PHONE_IP:~/$DIR_TRIM/" \
            "$DEST_DIR/" >> "$LOG" 2>&1

        TOTAL_NUEVOS=$((TOTAL_NUEVOS + NUEVOS))
    fi
done

_log "Sync completo. $TOTAL_NUEVOS archivos nuevos transferidos."

# ── Rotar log si pasa de 2MB ──────────────────────────────────
LOG_SIZE=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
if [ "$LOG_SIZE" -gt 2097152 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
DAEMON_EOF

chmod +x "$DAEMON_PATH"
log "Daemon creado en $DAEMON_PATH"

# ── 6. Instalar cron ─────────────────────────────────────────
info "Instalando cron job..."
sudo apt-get install -y -q cron 2>/dev/null || true

# Agregar al crontab (sin duplicar)
CRON_LINE="*/30 * * * * $DAEMON_PATH"
(crontab -l 2>/dev/null | grep -v "recolector_daemon"; echo "$CRON_LINE") | crontab -
log "Cron instalado: cada 30 minutos"

# Asegurar que cron arranca con WSL
if ! grep -q "service cron start" "$HOME/.bashrc" 2>/dev/null && \
   ! grep -q "service cron start" "$HOME/.zshrc" 2>/dev/null; then
    SHELL_RC="$HOME/.zshrc"
    [ ! -f "$SHELL_RC" ] && SHELL_RC="$HOME/.bashrc"
    echo "" >> "$SHELL_RC"
    echo "# Autostart cron para backup daemon" >> "$SHELL_RC"
    echo "sudo service cron start > /dev/null 2>&1" >> "$SHELL_RC"
    log "Autostart cron agregado a $SHELL_RC"
fi

# Iniciar cron ahora mismo
sudo service cron start > /dev/null 2>&1 || true
log "Servicio cron iniciado"

# ── 7. Correr daemon una vez ahora ──────────────────────────
info "Corriendo primera sincronización ahora..."
bash "$DAEMON_PATH" && log "Primera sincronización completada" || warn "Primera sync falló (normal si el cel no está conectado)"

# ── 8. Resumen final ─────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              SETUP COMPLETADO ✓                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Celular IP  :${NC} $PHONE_IP"
echo -e "  ${CYAN}Usuario     :${NC} $PHONE_USER"
echo -e "  ${CYAN}Destino     :${NC} $DEST_DIR"
echo -e "  ${CYAN}Daemon      :${NC} $DAEMON_PATH"
echo -e "  ${CYAN}Config      :${NC} $CONFIG_FILE"
echo -e "  ${CYAN}Log         :${NC} $DEST_DIR/.backup.log"
echo -e "  ${CYAN}Frecuencia  :${NC} Cada 30 minutos"
echo ""
echo -e "${YELLOW}━━━ COMANDOS ÚTILES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Correr sync ahora   : ${BOLD}bash $DAEMON_PATH${NC}"
echo -e "  Ver logs en vivo    : ${BOLD}tail -f $DEST_DIR/.backup.log${NC}"
echo -e "  Ver cron activo     : ${BOLD}crontab -l${NC}"
echo -e "  Desactivar daemon   : ${BOLD}crontab -e${NC} (borra la línea recolector)"
echo ""
echo -e "${GREEN}  El daemon ya está corriendo. No necesitas hacer nada más.${NC}"
echo ""
