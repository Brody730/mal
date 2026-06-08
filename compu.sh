#!/bin/bash
# ============================================================
#  SETUP COMPU (WSL) - Auto configurador completo
#  Se conecta al cel a través del VPS puente
#  Correr en Ubuntu WSL: bash setup_compu.sh
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
echo -e "${BOLD}║   SETUP COMPU  v2.0                  ║${NC}"
echo -e "${BOLD}║   Backup via VPS Puente              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Configuración fija ────────────────────────────────────────
VPS_IP="3.128.129.120"
VPS_USER="tunnel"
VPS_SSH_PORT="22"
TUNNEL_PORT="19999"    # Puerto en el VPS donde está el cel
CEL_PORT="8022"        # Puerto sshd del cel

# ── Buscar .pem automáticamente ──────────────────────────────
info "Buscando llave .pem de AWS..."
PEM_FILE=""
# Buscar en ~/.ssh primero
for F in ~/.ssh/*.pem; do
    [ -f "$F" ] && PEM_FILE="$F" && break
done
# Si no, buscar en rutas comunes
if [ -z "$PEM_FILE" ]; then
    for F in ~/MAL.pem ~/mal/MAL.pem ~/.ssh/MAL.pem; do
        [ -f "$F" ] && PEM_FILE="$F" && break
    done
fi

if [ -n "$PEM_FILE" ]; then
    cp "$PEM_FILE" ~/.ssh/aws_mal.pem 2>/dev/null || true
    chmod 400 ~/.ssh/aws_mal.pem
    log "Llave AWS encontrada: $PEM_FILE"
else
    warn "No se encontró .pem automáticamente."
    read -p "  Ruta completa al archivo .pem: " PEM_PATH
    [ ! -f "$PEM_PATH" ] && err "Archivo no encontrado: $PEM_PATH"
    cp "$PEM_PATH" ~/.ssh/aws_mal.pem
    chmod 400 ~/.ssh/aws_mal.pem
    log "Llave AWS copiada"
fi

# ── Pedir datos mínimos ───────────────────────────────────────
echo ""
read -p "  Usuario Termux del cel (ej: u0_a447): " PHONE_USER
read -p "  Ruta destino fotos (ej: /mnt/f/TELEFONO): " DEST_DIR
echo ""

# Pegar llave pública del cel
echo -e "  Pega la llave pública del celular"
echo -e "  (la que mostró setup_cel.sh al final):"
read -p "  > " CEL_PUBKEY

mkdir -p "$DEST_DIR"
log "Carpeta destino: $DEST_DIR"

# ── Generar llave SSH de la compu ────────────────────────────
info "Configurando llaves SSH..."
SSH_KEY="$HOME/.ssh/id_ed25519_backup"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "backup@compu" -q
    log "Llave backup generada"
else
    log "Llave backup ya existe, skip"
fi

COMPU_PUBKEY=$(cat "$SSH_KEY.pub")

# ── Instalar llave de la compu en el VPS (usuario tunnel) ────
info "Instalando llave de la compu en el VPS..."
ssh -i ~/.ssh/aws_mal.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ubuntu@$VPS_IP \
    "sudo -u tunnel bash -c 'mkdir -p ~/.ssh && echo \"$COMPU_PUBKEY\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys'" 2>/dev/null && \
    log "Llave de la compu instalada en VPS" || \
    warn "No se pudo instalar automáticamente en VPS"

# ── Instalar llave de la compu en el cel (via VPS tunnel) ────
info "Instalando llave de la compu en el celular..."

# Intentar conectar al cel a través del tunnel del VPS
SSH_VIA_VPS="ssh -i $SSH_KEY \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -J $VPS_USER@$VPS_IP:$VPS_SSH_PORT \
    -p $TUNNEL_PORT \
    $PHONE_USER@localhost"

# Instalar llave en cel via tunnel
$SSH_VIA_VPS \
    "mkdir -p ~/.ssh && echo '$COMPU_PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null && \
    log "Llave instalada en cel via tunnel ✓" || \
    warn "Cel no accesible via tunnel aún (asegúrate que tunnel_reverso.sh esté corriendo en el cel)"

# Instalar llave del cel en known_hosts de la compu
if [ -n "$CEL_PUBKEY" ]; then
    if ! grep -qF "$CEL_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "$CEL_PUBKEY" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    fi
fi

# ── Guardar configuración ─────────────────────────────────────
CONFIG_FILE="$HOME/.phone_backup.conf"
cat > "$CONFIG_FILE" << CONF
# Backup config — generado $(date '+%Y-%m-%d %H:%M:%S')
VPS_IP="$VPS_IP"
VPS_USER="$VPS_USER"
VPS_SSH_PORT="$VPS_SSH_PORT"
TUNNEL_PORT="$TUNNEL_PORT"
CEL_PORT="$CEL_PORT"
PHONE_USER="$PHONE_USER"
DEST_DIR="$DEST_DIR"
SSH_KEY="$SSH_KEY"
AWS_PEM="$HOME/.ssh/aws_mal.pem"
CONF
chmod 600 "$CONFIG_FILE"
log "Configuración guardada en $CONFIG_FILE"

# ── Crear daemon de backup ────────────────────────────────────
DAEMON="$HOME/recolector_daemon.sh"
cat > "$DAEMON" << 'DAEMON_EOF'
#!/bin/bash
# ============================================================
#  RECOLECTOR DAEMON v2.0
#  Backup via VPS puente — sin Tailscale
# ============================================================

source "$HOME/.phone_backup.conf"

LOG="$DEST_DIR/.backup.log"

# SSH options para conectar al cel VIA el VPS como salto (ProxyJump)
SSH_OPTS="-i $SSH_KEY \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 \
    -o BatchMode=yes \
    -o ServerAliveInterval=15 \
    -o ProxyJump=${VPS_USER}@${VPS_IP}:${VPS_SSH_PORT}"

_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG"; }

mkdir -p "$DEST_DIR"

# ── Chequeo: ¿está el tunnel activo en el VPS? ───────────────
TUNNEL_ACTIVO=$(ssh -i "$AWS_PEM" \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    ubuntu@$VPS_IP \
    "ss -tlnp 2>/dev/null | grep -c $TUNNEL_PORT || echo 0" 2>/dev/null || echo "0")

if [ "$TUNNEL_ACTIVO" = "0" ] || [ -z "$TUNNEL_ACTIVO" ]; then
    exit 0  # Cel no conectado, salida silenciosa
fi

# ── Chequeo: ¿responde SSH del cel? ──────────────────────────
ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@$VPS_IP" exit 2>/dev/null || exit 0

_log "Celular detectado via VPS. Iniciando sync..."

# ── Leer carpetas desde config remota o escanear ─────────────
REMOTE_CONFIG=$(ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@$VPS_IP" \
    "cat ~/storage/shared/.termux_backup_config 2>/dev/null" 2>/dev/null || echo "")

declare -a CARPETAS
if echo "$REMOTE_CONFIG" | grep -q "CARPETAS="; then
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '"' | xargs)
        [[ "$line" =~ ^storage/ ]] && CARPETAS+=("$line")
    done <<< "$(echo "$REMOTE_CONFIG" | sed -n '/^CARPETAS=(/,/^)/p' | grep -v 'CARPETAS\|^)$')"
fi

# Si no hay config, escanear dinámicamente
if [ ${#CARPETAS[@]} -eq 0 ]; then
    _log "Sin config remota, escaneando..."
    SCAN=$(ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@$VPS_IP" bash << 'SCAN_EOF'
for C in "storage/dcim/Camera" "storage/dcim/Screenshots" "storage/pictures" \
         "storage/downloads" "storage/movies" \
         "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images" \
         "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video" \
         "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Images" \
         "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Video" \
         "storage/shared/Android/media/com.instagram.android/files/videos" \
         "storage/shared/Android/media/com.instagram.android/files/images" \
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

[ ${#CARPETAS[@]} -eq 0 ] && _log "No hay carpetas con imágenes." && exit 0

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
        _log "  $DIR ($NUEVOS archivos nuevos)"
        rsync -az \
            --include="*.jpg" --include="*.jpeg" --include="*.png" \
            --include="*.mp4" --include="*.mov" --include="*.gif" \
            --include="*.webp" --include="*.heic" --include="*.3gp" \
            --exclude="*" --remove-source-files --ignore-missing-args \
            -e "ssh $SSH_OPTS -p $TUNNEL_PORT" \
            "$PHONE_USER@$VPS_IP:~/$DIR/" \
            "$DEST_DIR/" >> "$LOG" 2>&1
        TOTAL=$((TOTAL + NUEVOS))
    fi
done

_log "Sync completo. $TOTAL archivos transferidos."

# Rotar log > 2MB
[ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 2097152 ] && \
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
DAEMON_EOF

chmod +x "$DAEMON"
log "Daemon creado: $DAEMON"

# ── Instalar cron ─────────────────────────────────────────────
info "Instalando cron job..."
sudo apt-get install -y -q cron 2>/dev/null || true
(crontab -l 2>/dev/null | grep -v "recolector_daemon"; echo "*/30 * * * * $DAEMON") | crontab -
log "Cron instalado: cada 30 minutos"

# Autostart cron en .zshrc / .bashrc
SHELL_RC="$HOME/.zshrc"
[ ! -f "$SHELL_RC" ] && SHELL_RC="$HOME/.bashrc"
grep -q "service cron start" "$SHELL_RC" 2>/dev/null || \
    echo "sudo service cron start > /dev/null 2>&1" >> "$SHELL_RC"
sudo service cron start > /dev/null 2>&1 || true
log "Cron iniciado"

# ── Primera sync ──────────────────────────────────────────────
info "Corriendo primera sync..."
bash "$DAEMON" && log "Primera sync OK" || warn "Primera sync falló (normal si el tunnel aún no está activo)"

# ── Resumen ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              SETUP COMPLETADO ✓                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}VPS puente     :${NC} $VPS_IP"
echo -e "  ${CYAN}Usuario cel    :${NC} $PHONE_USER"
echo -e "  ${CYAN}Destino        :${NC} $DEST_DIR"
echo -e "  ${CYAN}Daemon         :${NC} $DAEMON"
echo -e "  ${CYAN}Log            :${NC} $DEST_DIR/.backup.log"
echo -e "  ${CYAN}Frecuencia     :${NC} Cada 30 minutos"
echo ""
echo -e "${YELLOW}━━━ COMANDOS ÚTILES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Sync manual     : ${BOLD}bash $DAEMON${NC}"
echo -e "  Ver log         : ${BOLD}tail -f $DEST_DIR/.backup.log${NC}"
echo -e "  Estado tunnel   : ${BOLD}ssh -i ~/.ssh/aws_mal.pem ubuntu@$VPS_IP tunnel_status.sh${NC}"
echo ""
echo -e "${GREEN}  El daemon ya está corriendo. No necesitas hacer nada más.${NC}"
echo ""
