#!/bin/bash
# ============================================================
#  SETUP COMPU (WSL) v2.2 — Multi-celular
#  Correr en Ubuntu WSL: bash compu.sh
#  Para cada celular nuevo correr una vez
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
echo -e "${BOLD}║   SETUP COMPU  v2.2 — Multi-cel     ║${NC}"
echo -e "${BOLD}║   Backup via VPS Puente              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Config fija del VPS ───────────────────────────────────────
VPS_IP="3.128.129.120"
VPS_USER="tunnel"
VPS_SSH_PORT="22"
CEL_PORT="8022"

# ── Buscar .pem automáticamente ──────────────────────────────
info "Buscando llave .pem de AWS..."
PEM_FILE=""
for F in ~/.ssh/*.pem; do [ -f "$F" ] && PEM_FILE="$F" && break; done
if [ -z "$PEM_FILE" ]; then
    for F in ~/MAL.pem ~/mal/MAL.pem ~/.ssh/MAL.pem; do
        [ -f "$F" ] && PEM_FILE="$F" && break
    done
fi

if [ -n "$PEM_FILE" ]; then
    cp "$PEM_FILE" ~/.ssh/aws_mal.pem 2>/dev/null || true
    chmod 400 ~/.ssh/aws_mal.pem
    log "Llave AWS: $PEM_FILE"
else
    warn "No se encontró .pem automáticamente."
    read -p "  Ruta completa al .pem: " PEM_PATH
    [ ! -f "$PEM_PATH" ] && err "No encontrado: $PEM_PATH"
    cp "$PEM_PATH" ~/.ssh/aws_mal.pem && chmod 400 ~/.ssh/aws_mal.pem
    log "Llave AWS copiada"
fi

# ── Datos del celular ─────────────────────────────────────────
echo ""
echo -e "${YELLOW}━━━ DATOS DEL CELULAR A AGREGAR ━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Detectar próximo puerto disponible
PUERTOS_USADOS=$(grep -h "^TUNNEL_PORT=" ~/.phone_backup_*.conf 2>/dev/null | \
    grep -oP '\d+' | sort -rn || true)
SIGUIENTE_PUERTO=19999
for P in $PUERTOS_USADOS; do
    [ "$P" -le "$SIGUIENTE_PUERTO" ] && SIGUIENTE_PUERTO=$((P - 1))
done

# Listar cels ya configurados
if ls ~/.phone_backup_*.conf 2>/dev/null | head -1 | grep -q conf; then
    echo -e "  ${CYAN}Celulares ya configurados:${NC}"
    for F in ~/.phone_backup_*.conf; do
        NOMBRE=$(basename "$F" .conf | sed 's/.phone_backup_//')
        PUERTO=$(grep "^TUNNEL_PORT=" "$F" | cut -d'"' -f2)
        UNAME=$(grep "^PHONE_USER=" "$F" | cut -d'"' -f2)
        echo -e "    • ${NOMBRE} → puerto ${PUERTO} (${UNAME})"
    done
    echo ""
fi

read -p "  Nombre para este cel (ej: samsung, moto, cel2): " PHONE_NAME
PHONE_NAME=$(echo "$PHONE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
[ -z "$PHONE_NAME" ] && err "El nombre no puede estar vacío"

echo -e "  Puerto tunnel sugerido: ${CYAN}${SIGUIENTE_PUERTO}${NC} (cada cel usa uno distinto)"
read -p "  Puerto tunnel [Enter para usar $SIGUIENTE_PUERTO]: " INPUT_PORT
TUNNEL_PORT="${INPUT_PORT:-$SIGUIENTE_PUERTO}"

read -p "  Usuario Termux del cel (ej: u0_a447): " PHONE_USER
read -p "  Ruta destino fotos (ej: /mnt/f/TELEFONO_2): " DEST_DIR
echo ""

echo -e "  Pega la llave pública del celular"
echo -e "  (la que mostró celu.sh al final):"
read -p "  > " CEL_PUBKEY
[ -z "$CEL_PUBKEY" ] && err "La llave pública no puede estar vacía"

mkdir -p "$DEST_DIR"
log "Carpeta destino: $DEST_DIR"

# ── Generar/reusar llave SSH de la compu ─────────────────────
info "Configurando llaves SSH..."
SSH_KEY="$HOME/.ssh/id_ed25519_backup"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "backup@compu" -q
    log "Llave backup generada"
else
    log "Llave backup ya existe, reutilizando"
fi
COMPU_PUBKEY=$(cat "$SSH_KEY.pub")

# ── Instalar llaves en el VPS tunnel user ─────────────────────
# *** FIX PRINCIPAL: instalar TAMBIÉN la llave del cel en el VPS ***
info "Instalando llaves en el VPS (compu + ${PHONE_NAME})..."
ssh -i ~/.ssh/aws_mal.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ubuntu@$VPS_IP \
    "sudo -u tunnel bash -c '
        mkdir -p ~/.ssh
        # Llave de la compu
        echo \"$COMPU_PUBKEY\" >> ~/.ssh/authorized_keys
        # Llave del cel $PHONE_NAME (este era el bug que faltaba)
        echo \"$CEL_PUBKEY\" >> ~/.ssh/authorized_keys
        sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    '" 2>/dev/null && \
    log "Llaves de compu + ${PHONE_NAME} instaladas en VPS ✓" || \
    warn "No se pudo instalar en VPS automáticamente"

# ── Instalar llave de la compu en el cel (via VPS tunnel) ────
info "Instalando llave de la compu en ${PHONE_NAME} (via tunnel)..."
ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -J $VPS_USER@$VPS_IP:$VPS_SSH_PORT \
    -p $TUNNEL_PORT \
    $PHONE_USER@localhost \
    "mkdir -p ~/.ssh && echo '$COMPU_PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
    2>/dev/null && \
    log "Llave instalada en ${PHONE_NAME} via tunnel ✓" || \
    warn "Cel no accesible via tunnel (asegurate que tunnel esté corriendo en el cel)"

# ── Guardar configuración ─────────────────────────────────────
CONFIG_FILE="$HOME/.phone_backup_${PHONE_NAME}.conf"
cat > "$CONFIG_FILE" << CONF
# Config backup ${PHONE_NAME} — $(date '+%Y-%m-%d %H:%M:%S')
VPS_IP="$VPS_IP"
VPS_USER="$VPS_USER"
VPS_SSH_PORT="$VPS_SSH_PORT"
TUNNEL_PORT="$TUNNEL_PORT"
CEL_PORT="$CEL_PORT"
PHONE_USER="$PHONE_USER"
PHONE_NAME="$PHONE_NAME"
DEST_DIR="$DEST_DIR"
SSH_KEY="$SSH_KEY"
AWS_PEM="$HOME/.ssh/aws_mal.pem"
CONF
chmod 600 "$CONFIG_FILE"
log "Configuración guardada en $CONFIG_FILE"

# ── Crear daemon de backup para este cel ─────────────────────
DAEMON="$HOME/recolector_${PHONE_NAME}.sh"
cat > "$DAEMON" << 'DAEMON_EOF'
#!/bin/bash
# ============================================================
#  RECOLECTOR DAEMON — Un cel específico
#  NO borra archivos del celular (solo copia)
# ============================================================

# Detectar qué config usar según el nombre del script
SCRIPT_NAME=$(basename "$0" .sh)
PHONE_NAME="${SCRIPT_NAME#recolector_}"
CONFIG_FILE="$HOME/.phone_backup_${PHONE_NAME}.conf"

[ ! -f "$CONFIG_FILE" ] && echo "Config no encontrada: $CONFIG_FILE" && exit 1
source "$CONFIG_FILE"

LOG="$DEST_DIR/.backup.log"

SSH_OPTS="-i $SSH_KEY \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 \
    -o BatchMode=yes \
    -o ServerAliveInterval=15 \
    -o ProxyJump=${VPS_USER}@${VPS_IP}:${VPS_SSH_PORT}"

_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | [$PHONE_NAME] $1" >> "$LOG"; }

mkdir -p "$DEST_DIR"

# ¿Tunnel activo?
TUNNEL_ACTIVO=$(ssh -i "$AWS_PEM" \
    -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
    ubuntu@$VPS_IP \
    "ss -tlnp 2>/dev/null | grep -c $TUNNEL_PORT || echo 0" 2>/dev/null || echo "0")

[ "$TUNNEL_ACTIVO" = "0" ] || [ -z "$TUNNEL_ACTIVO" ] && exit 0

# ¿Responde SSH?
ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@$VPS_IP" exit 2>/dev/null || exit 0

_log "Detectado. Iniciando sync..."

# Escanear carpetas
REMOTE_CONFIG=$(ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@$VPS_IP" \
    "cat ~/storage/shared/.termux_backup_config 2>/dev/null" 2>/dev/null || echo "")

declare -a CARPETAS
if echo "$REMOTE_CONFIG" | grep -q "CARPETAS="; then
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '"' | xargs)
        [[ "$line" =~ ^storage/ ]] && CARPETAS+=("$line")
    done <<< "$(echo "$REMOTE_CONFIG" | sed -n '/^CARPETAS=(/,/^)/p' | grep -v 'CARPETAS\|^)$')"
fi

if [ ${#CARPETAS[@]} -eq 0 ]; then
    SCAN=$(ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@$VPS_IP" bash << 'SCAN_EOF'
for C in "storage/dcim/Camera" "storage/dcim/Screenshots" "storage/pictures" \
         "storage/downloads" "storage/movies" \
         "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images" \
         "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video" \
         "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Images" \
         "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Video" \
         "storage/shared/DCIM" "storage/shared/Pictures" \
         "storage/shared/Movies" "storage/shared/Download"; do
    RUTA="$HOME/$C"
    [ -d "$RUTA" ] && find "$RUTA" -maxdepth 2 \
        \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.heic" \) \
        2>/dev/null | head -1 | grep -q . && echo "$C"
done
SCAN_EOF
    2>/dev/null)
    while IFS= read -r line; do [ -n "$line" ] && CARPETAS+=("$line"); done <<< "$SCAN"
fi

[ ${#CARPETAS[@]} -eq 0 ] && _log "No hay carpetas." && exit 0

_log "Sincronizando ${#CARPETAS[@]} carpetas..."
TOTAL=0

for DIR in "${CARPETAS[@]}"; do
    DIR=$(echo "$DIR" | xargs)
    [ -z "$DIR" ] && continue

    NUEVOS=$(rsync --dry-run -az \
        --include="*.jpg" --include="*.jpeg" --include="*.png" \
        --include="*.mp4" --include="*.mov" --include="*.gif" \
        --include="*.webp" --include="*.heic" --include="*.3gp" \
        --exclude="*" --ignore-missing-args \
        -e "ssh $SSH_OPTS -p $TUNNEL_PORT" \
        "$PHONE_USER@$VPS_IP:~/$DIR/" \
        "$DEST_DIR/" 2>/dev/null | grep -c "^>" || echo 0)

    if [ "$NUEVOS" -gt 0 ]; then
        _log "  $DIR ($NUEVOS nuevos)"
        rsync -az \
            --include="*.jpg" --include="*.jpeg" --include="*.png" \
            --include="*.mp4" --include="*.mov" --include="*.gif" \
            --include="*.webp" --include="*.heic" --include="*.3gp" \
            --exclude="*" --ignore-missing-args \
            -e "ssh $SSH_OPTS -p $TUNNEL_PORT" \
            "$PHONE_USER@$VPS_IP:~/$DIR/" \
            "$DEST_DIR/" >> "$LOG" 2>&1
        TOTAL=$((TOTAL + NUEVOS))
    fi
done

_log "Sync completo. $TOTAL archivos transferidos."
[ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 2097152 ] && \
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
DAEMON_EOF

chmod +x "$DAEMON"
log "Daemon creado: $DAEMON"

# ── Instalar cron para este cel ───────────────────────────────
info "Instalando cron job para ${PHONE_NAME}..."
sudo apt-get install -y -q cron 2>/dev/null || true
(crontab -l 2>/dev/null | grep -v "recolector_${PHONE_NAME}"; \
    echo "*/30 * * * * $DAEMON") | crontab -
sudo service cron start > /dev/null 2>&1 || true

SHELL_RC="$HOME/.zshrc"; [ ! -f "$SHELL_RC" ] && SHELL_RC="$HOME/.bashrc"
grep -q "service cron start" "$SHELL_RC" 2>/dev/null || \
    echo "sudo service cron start > /dev/null 2>&1" >> "$SHELL_RC"
log "Cron instalado para ${PHONE_NAME}: cada 30 minutos"

# ── Primera sync ──────────────────────────────────────────────
info "Primera sync de ${PHONE_NAME}..."
bash "$DAEMON" && log "Primera sync OK" || warn "Sync falló (normal si tunnel no está activo)"

# ── Resumen ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   ${PHONE_NAME} CONFIGURADO ✓                                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Cel            :${NC} ${PHONE_NAME} (${PHONE_USER})"
echo -e "  ${CYAN}Puerto tunnel  :${NC} ${TUNNEL_PORT}"
echo -e "  ${CYAN}Destino        :${NC} ${DEST_DIR}"
echo -e "  ${CYAN}Daemon         :${NC} ${DAEMON}"
echo -e "  ${CYAN}Config         :${NC} ${CONFIG_FILE}"
echo ""

# Mostrar todos los cels configurados
echo -e "${YELLOW}━━━ TODOS LOS CELULARES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
for F in ~/.phone_backup_*.conf; do
    [ -f "$F" ] || continue
    N=$(grep "^PHONE_NAME=" "$F" | cut -d'"' -f2)
    P=$(grep "^TUNNEL_PORT=" "$F" | cut -d'"' -f2)
    D=$(grep "^DEST_DIR=" "$F" | cut -d'"' -f2)
    echo -e "  ${GREEN}•${NC} ${N} → puerto ${P} → ${D}"
done
echo ""
echo -e "${YELLOW}━━━ COMANDOS ÚTILES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Sync manual     : ${BOLD}bash $DAEMON${NC}"
echo -e "  Ver log         : ${BOLD}tail -f $DEST_DIR/.backup.log${NC}"
echo -e "  Estado VPS      : ${BOLD}ssh -i ~/.ssh/aws_mal.pem ubuntu@$VPS_IP tunnel_status.sh${NC}"
echo ""
