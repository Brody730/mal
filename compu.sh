#!/bin/bash
# ============================================================
#  SETUP COMPU v3.0 — Setup único, detecta todos los cels solo
#  Correr UNA SOLA VEZ en WSL: bash compu.sh
#  Los nuevos cels se detectan automáticamente después
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
echo -e "${BOLD}║   SETUP COMPU  v3.0 — Setup Único   ║${NC}"
echo -e "${BOLD}║   Detecta todos los cels solo        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── 1. Config del VPS ─────────────────────────────────────────
VPS_IP="3.128.129.120"
VPS_USER="tunnel"
VPS_SSH_PORT="22"

# ── 2. Buscar MAL.pem ────────────────────────────────────────
info "Buscando MAL.pem..."
PEM_KEY=""
for F in ~/.ssh/MAL.pem ~/.ssh/*.pem; do
    [ -f "$F" ] && PEM_KEY="$F" && break
done
if [ -n "$PEM_KEY" ]; then
    chmod 400 "$PEM_KEY"
    log "Llave AWS: $PEM_KEY"
else
    read -p "  Ruta al archivo .pem: " PEM_KEY
    [ ! -f "$PEM_KEY" ] && err "No encontrado: $PEM_KEY"
    chmod 400 "$PEM_KEY"
fi

# ── 3. Carpeta base de backups ────────────────────────────────
echo ""
echo -e "  Carpeta base donde se guardarán las fotos."
echo -e "  Cada cel tendrá su propia subcarpeta: BASE_DIR/nombre_cel/"
echo ""
read -p "  Carpeta base (ej: /mnt/f/BACKUPS): " BASE_DEST_DIR
[ -z "$BASE_DEST_DIR" ] && err "La carpeta no puede estar vacía"
mkdir -p "$BASE_DEST_DIR"
log "Carpeta base: $BASE_DEST_DIR"

# ── 4. Generar llave SSH backup ───────────────────────────────
info "Configurando llaves SSH..."
SSH_KEY="$HOME/.ssh/id_ed25519_backup"
[ ! -f "$SSH_KEY" ] && ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "backup@compu" -q && log "Llave backup generada" || log "Llave backup ya existe"
BACKUP_PUBKEY=$(cat "$SSH_KEY.pub")

# ── 5. Subir llaves del WSL al VPS ───────────────────────────
# Estas llaves se distribuyen automáticamente a cada cel que se registre
info "Subiendo llaves WSL al VPS (para auto-distribución a cels)..."

# Recolectar todas las llaves del WSL
WSL_KEYS="$BACKUP_PUBKEY"
for PUB in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    [ -f "$PUB" ] && KEY=$(cat "$PUB") && WSL_KEYS="$WSL_KEYS"$'\n'"$KEY"
done

# Subir al VPS — los cels las recibirán en su registro
ssh -i "$PEM_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$VPS_IP \
    "sudo -u tunnel bash -c '
        echo \"$WSL_KEYS\" | sort -u > /home/tunnel/keys/wsl_keys
        chmod 600 /home/tunnel/keys/wsl_keys
        echo \"WSL keys: \$(wc -l < /home/tunnel/keys/wsl_keys) llaves\"
    '" 2>/dev/null && log "Llaves WSL subidas al VPS ✓" || warn "No se pudo subir llaves al VPS"

# Instalar backup key y WSL keys en el tunnel user del VPS
ssh -i "$PEM_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$VPS_IP \
    "sudo -u tunnel bash -c '
        echo \"$WSL_KEYS\" >> /home/tunnel/.ssh/authorized_keys
        sort -u /home/tunnel/.ssh/authorized_keys -o /home/tunnel/.ssh/authorized_keys
        chmod 600 /home/tunnel/.ssh/authorized_keys
    '" 2>/dev/null && log "Llaves también instaladas en tunnel@VPS (ProxyJump) ✓"

# ── 6. Guardar config maestra ─────────────────────────────────
MASTER_CONF="$HOME/.mal_master.conf"
cat > "$MASTER_CONF" << CONF
# MAL Backup — Config maestra generada $(date '+%Y-%m-%d %H:%M:%S')
VPS_IP="$VPS_IP"
VPS_USER="$VPS_USER"
VPS_SSH_PORT="$VPS_SSH_PORT"
PEM_KEY="$PEM_KEY"
SSH_KEY="$SSH_KEY"
BASE_DEST_DIR="$BASE_DEST_DIR"
LOG="$BASE_DEST_DIR/.master.log"
CONF
chmod 600 "$MASTER_CONF"
log "Config maestra guardada: $MASTER_CONF"

# ── 7. Crear daemon maestro ───────────────────────────────────
# Un solo daemon que detecta y sincroniza TODOS los cels registrados
DAEMON="$HOME/recolector_master.sh"
cat > "$DAEMON" << 'DAEMON_EOF'
#!/bin/bash
# ============================================================
#  DAEMON MAESTRO v3.0 — Sincroniza TODOS los cels registrados
#  Lee el registro del VPS automáticamente
#  Cada cel nuevo en celu.sh se detecta solo
# ============================================================

source "$HOME/.mal_master.conf"
_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"; }

SSH_BASE="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15"
SSH_OPTS="$SSH_BASE -i $SSH_KEY -o ProxyJump=${VPS_USER}@${VPS_IP}:${VPS_SSH_PORT}"

mkdir -p "$BASE_DEST_DIR"

# Leer registro del VPS
REGISTRY=$(ssh -i "$PEM_KEY" $SSH_BASE ubuntu@$VPS_IP \
    "sudo -u tunnel cat /home/tunnel/keys/registry 2>/dev/null" 2>/dev/null)

[ -z "$REGISTRY" ] && exit 0

while IFS= read -r LINE; do
    [[ "$LINE" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$LINE" ]] && continue

    PHONE_ID=$(echo "$LINE"   | awk '{print $1}')
    TUNNEL_PORT=$(echo "$LINE" | awk '{print $2}')
    PHONE_NAME=$(echo "$LINE"  | awk '{print $3}')
    PHONE_USER=$(echo "$LINE"  | awk '{print $4}')

    # ¿Tunnel activo?
    ACTIVE=$(ssh -i "$PEM_KEY" $SSH_BASE ubuntu@$VPS_IP \
        "ss -tlnp 2>/dev/null | grep -c ':$TUNNEL_PORT '" 2>/dev/null || echo 0)
    [[ "$ACTIVE" =~ ^[0-9]+$ ]] || ACTIVE=0
    [ "$ACTIVE" -eq 0 ] && continue

    # ¿SSH responde?
    ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@localhost" exit 2>/dev/null || continue

    DEST="$BASE_DEST_DIR/$PHONE_NAME"
    LOG_CEL="$DEST/.backup.log"
    mkdir -p "$DEST"

    _log "$PHONE_NAME conectado (puerto $TUNNEL_PORT)"

    # Leer carpetas del cel
    REMOTE_CONF=$(ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@localhost" \
        "cat ~/storage/shared/.termux_backup_config 2>/dev/null" 2>/dev/null || echo "")

    declare -a CARPETAS
    if echo "$REMOTE_CONF" | grep -q "CARPETAS="; then
        while IFS= read -r C; do
            C=$(echo "$C" | tr -d '"' | xargs)
            [[ "$C" =~ ^storage/ ]] && CARPETAS+=("$C")
        done <<< "$(echo "$REMOTE_CONF" | sed -n '/^CARPETAS=(/,/^)/p' | grep -v 'CARPETAS\|^)$')"
    fi

    if [ ${#CARPETAS[@]} -eq 0 ]; then
        SCAN=$(ssh $SSH_OPTS -p "$TUNNEL_PORT" "$PHONE_USER@localhost" bash << 'SCAN_EOF'
for C in "storage/dcim/Camera" "storage/dcim/Screenshots" "storage/pictures" \
         "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images" \
         "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video" \
         "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Images" \
         "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Video" \
         "storage/shared/DCIM" "storage/shared/Pictures" "storage/shared/Download"; do
    [ -d "$HOME/$C" ] && find "$HOME/$C" -maxdepth 2 \
        \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.heic" \) \
        2>/dev/null | head -1 | grep -q . && echo "$C"
done
SCAN_EOF
        2>/dev/null)
        while IFS= read -r C; do [ -n "$C" ] && CARPETAS+=("$C"); done <<< "$SCAN"
    fi

    [ ${#CARPETAS[@]} -eq 0 ] && unset CARPETAS && continue

    TOTAL=0
    for DIR in "${CARPETAS[@]}"; do
        DIR=$(echo "$DIR" | xargs)
        [ -z "$DIR" ] && continue

        NUEVOS=$(rsync --dry-run -az --itemize-changes \
            --include="*.jpg" --include="*.jpeg" --include="*.png" \
            --include="*.mp4" --include="*.mov" --include="*.gif" \
            --include="*.webp" --include="*.heic" --include="*.3gp" \
            --include="*/" --exclude="*" --ignore-missing-args \
            -e "ssh $SSH_OPTS -p $TUNNEL_PORT" \
            "$PHONE_USER@localhost:~/$DIR/" \
            "$DEST/" 2>/dev/null | grep -c "^>")

        if [ "$NUEVOS" -gt 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') | $DIR → $NUEVOS nuevos" >> "$LOG_CEL"
            rsync -az \
                --include="*.jpg" --include="*.jpeg" --include="*.png" \
                --include="*.mp4" --include="*.mov" --include="*.gif" \
                --include="*.webp" --include="*.heic" --include="*.3gp" \
                --include="*/" --exclude="*" --ignore-missing-args \
                -e "ssh $SSH_OPTS -p $TUNNEL_PORT" \
                "$PHONE_USER@localhost:~/$DIR/" \
                "$DEST/" >> "$LOG_CEL" 2>&1
            TOTAL=$((TOTAL + NUEVOS))
        fi
    done

    [ "$TOTAL" -gt 0 ] && _log "$PHONE_NAME: $TOTAL archivos → $DEST"
    unset CARPETAS

done <<< "$REGISTRY"
DAEMON_EOF
chmod +x "$DAEMON"
log "Daemon maestro creado: $DAEMON"

# ── 8. Instalar cron ──────────────────────────────────────────
info "Instalando cron..."
sudo apt-get install -y -q cron 2>/dev/null || true
(crontab -l 2>/dev/null | grep -v recolector_master; \
    echo "*/30 * * * * $DAEMON") | crontab -
sudo service cron start > /dev/null 2>&1 || true

for RC in ~/.zshrc ~/.bashrc; do
    [ -f "$RC" ] && grep -q "service cron start" "$RC" 2>/dev/null || \
        echo "sudo service cron start > /dev/null 2>&1" >> "$RC"
done
log "Cron cada 30 min"

# ── 9. Primera sync ───────────────────────────────────────────
info "Corriendo primera sync..."
bash "$DAEMON" && log "Primera sync OK" || warn "Sync falló (normal si no hay cels conectados)"

# ── Resumen ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           COMPU CONFIGURADA ✓                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Carpeta base   :${NC} $BASE_DEST_DIR"
echo -e "  ${CYAN}Daemon maestro :${NC} $DAEMON"
echo -e "  ${CYAN}Log maestro    :${NC} $BASE_DEST_DIR/.master.log"
echo -e "  ${CYAN}Frecuencia     :${NC} Cada 30 minutos"
echo ""
echo -e "${YELLOW}━━━ CELS REGISTRADOS EN EL VPS ━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
ssh -i "$PEM_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@$VPS_IP \
    "sudo -u tunnel cat /home/tunnel/keys/registry 2>/dev/null | grep -v '^#' | \
    awk '{printf \"  • %-10s  puerto %-6s  %s\n\", \$3, \$2, \$5}'" 2>/dev/null || \
    echo "  (no hay cels aún — corré celu.sh en el cel)"
echo ""
echo -e "${YELLOW}━━━ COMANDOS ÚTILES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Sync manual  : ${BOLD}bash $DAEMON${NC}"
echo -e "  Estado VPS   : ${BOLD}ssh -i $PEM_KEY ubuntu@$VPS_IP tunnel_status.sh${NC}"
echo -e "  Ver registro : ${BOLD}ssh -i $PEM_KEY ubuntu@$VPS_IP 'sudo -u tunnel cat /home/tunnel/keys/registry'${NC}"
echo ""
echo -e "${GREEN}  ¡Listo! Cualquier cel que corra celu.sh se detecta solo.${NC}"
echo ""
