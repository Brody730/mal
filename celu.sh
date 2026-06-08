#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  SETUP CELULAR v2.3
#  SSH + Tunnel Reverso a VPS
#  Autostart via .bashrc (sin termux-services)
#  Correr en Termux: bash celu.sh
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
echo -e "${BOLD}║   SETUP CELULAR  v2.3                ║${NC}"
echo -e "${BOLD}║   SSH + Tunnel Reverso a VPS         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Datos del VPS ─────────────────────────────────────────────
VPS_IP="3.128.129.120"
VPS_USER="tunnel"
VPS_PORT="22"

# ── Puerto tunnel (uno distinto por cel) ──────────────────────
echo -e "${YELLOW}━━━ PUERTO TUNNEL ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Cada cel necesita un puerto único en el VPS:"
echo -e "  Primer cel : ${CYAN}19999${NC} (ya usado)"
echo -e "  Segundo cel: ${CYAN}19998${NC}"
echo -e "  Tercer cel : ${CYAN}19997${NC}  ...etc"
echo ""
read -p "  Puerto tunnel para ESTE cel [default 19998]: " INPUT_PORT
TUNNEL_PORT="${INPUT_PORT:-19998}"
echo ""

# ── 1. Paquetes ──────────────────────────────────────────────
info "Actualizando paquetes..."
pkg update -y -q && pkg upgrade -y -q 2>/dev/null
info "Instalando dependencias..."
pkg install -y -q openssh rsync iproute2 termux-api autossh 2>/dev/null
log "Paquetes listos"

# ── 2. Almacenamiento ────────────────────────────────────────
if [ ! -d "$HOME/storage/dcim" ]; then
    warn "Configurando permisos de almacenamiento..."
    echo -e "${YELLOW}>>> ACEPTA EL POPUP EN TU PANTALLA <<<${NC}"
    termux-setup-storage
    sleep 8
    [ ! -d "$HOME/storage/dcim" ] && err "No se otorgaron permisos. Volvé a correr el script."
fi
log "Almacenamiento OK"

# ── 3. SSH del celular ───────────────────────────────────────
info "Configurando SSH..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh

[ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
log "Llave SSH lista"

mkdir -p $PREFIX/etc/ssh
cat > $PREFIX/etc/ssh/sshd_config << 'SSHD'
Port 8022
ListenAddress 0.0.0.0
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
Subsystem sftp /data/data/com.termux/files/usr/libexec/sftp-server
SSHD

[ ! -f $PREFIX/etc/ssh/ssh_host_ed25519_key ] && \
    ssh-keygen -t ed25519 -N "" -f $PREFIX/etc/ssh/ssh_host_ed25519_key -q
[ ! -f $PREFIX/etc/ssh/ssh_host_rsa_key ] && \
    ssh-keygen -t rsa -N "" -f $PREFIX/etc/ssh/ssh_host_rsa_key -q

pkill sshd 2>/dev/null || true
sleep 1
sshd
sleep 1
pgrep sshd && log "sshd corriendo en puerto 8022" || err "sshd no arrancó"

# ── 4. Instalar llave del VPS en el cel ──────────────────────
info "Instalando llave del VPS..."
VPS_TUNNEL_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAWXCv+THPKtTZAcNyP7Fyrz2s81E3CsuHmldCHXRn7p tunnel@ip-172-31-40-218"
if ! grep -qF "$VPS_TUNNEL_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$VPS_TUNNEL_PUBKEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    log "Llave del VPS instalada"
else
    log "Llave del VPS ya existía, skip"
fi

# ── 5. Intentar instalar llave del cel en el VPS ─────────────
info "Intentando instalar llave del cel en el VPS..."
CEL_PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
ssh -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    -o PasswordAuthentication=no \
    -p "$VPS_PORT" "$VPS_USER@$VPS_IP" \
    "mkdir -p ~/.ssh && echo '$CEL_PUBKEY' >> ~/.ssh/authorized_keys && \
     sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
     chmod 600 ~/.ssh/authorized_keys" 2>/dev/null && \
    log "Llave del cel instalada en VPS ✓" || \
    warn "No se pudo instalar en VPS — compu.sh v2.2 lo hará automáticamente"

# ── 6. Script de tunnel reverso ───────────────────────────────
info "Creando tunnel_reverso.sh..."
cat > ~/tunnel_reverso.sh << TUNNEL
#!/data/data/com.termux/files/usr/bin/bash
VPS_IP="${VPS_IP}"
VPS_USER="${VPS_USER}"
TUNNEL_PORT="${TUNNEL_PORT}"
CEL_PORT="8022"

while true; do
    ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || { sleep 30; continue; }
    autossh -M 0 \
        -N \
        -R \${TUNNEL_PORT}:localhost:\${CEL_PORT} \
        -i ~/.ssh/id_ed25519 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=no \
        -o ExitOnForwardFailure=yes \
        -o ConnectTimeout=10 \
        "\${VPS_USER}@\${VPS_IP}" 2>/dev/null
    sleep 10
done
TUNNEL
chmod +x ~/tunnel_reverso.sh
log "tunnel_reverso.sh creado"

# ── 7. Autostart en .bashrc ───────────────────────────────────
# Enfoque simple que funciona: .bashrc arranca sshd + tunnel
# al abrir cualquier sesión de Termux
info "Configurando autostart en .bashrc..."
if ! grep -q "auto_start_services" ~/.bashrc 2>/dev/null; then
    cat >> ~/.bashrc << 'AUTOSTART'

# ── Auto-arranque: sshd + tunnel al abrir Termux ──────────────
auto_start_services() {
    pgrep sshd > /dev/null || sshd
    pgrep autossh > /dev/null || bash ~/tunnel_reverso.sh &
}
auto_start_services
# ─────────────────────────────────────────────────────────────
AUTOSTART
    log "Autostart agregado a .bashrc"
else
    log "Autostart ya estaba en .bashrc, skip"
fi

# ── 8. Boot script para Termux:Boot ──────────────────────────
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/01_start_services.sh << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Arranca al encender el cel (requiere Termux:Boot de F-Droid)
termux-wake-lock
sleep 8
sshd
sleep 2
bash ~/tunnel_reverso.sh &
BOOT
chmod +x ~/.termux/boot/01_start_services.sh
log "Boot script configurado"

# ── 9. Escanear carpetas ──────────────────────────────────────
info "Escaneando carpetas de medios..."
CARPETAS_ENCONTRADAS=()
for CARPETA in \
    "storage/dcim/Camera" "storage/dcim/Screenshots" \
    "storage/pictures" "storage/downloads" "storage/movies" \
    "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images" \
    "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video" \
    "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Images" \
    "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Video" \
    "storage/shared/Android/media/com.instagram.android/files/videos" \
    "storage/shared/Android/media/com.instagram.android/files/images" \
    "storage/shared/DCIM" "storage/shared/Pictures" \
    "storage/shared/Movies" "storage/shared/Download"; do
    RUTA="$HOME/$CARPETA"
    if [ -d "$RUTA" ]; then
        COUNT=$(find "$RUTA" -maxdepth 3 \
            \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.heic" \) \
            2>/dev/null | head -1 | wc -l)
        [ "$COUNT" -gt 0 ] && CARPETAS_ENCONTRADAS+=("$CARPETA") && log "Encontrada: $CARPETA"
    fi
done

INFO_FILE="$HOME/storage/shared/.termux_backup_config"
cat > "$INFO_FILE" << CONF
PHONE_USER=$(whoami)
PHONE_PORT=8022
VPS_IP=$VPS_IP
TUNNEL_PORT=$TUNNEL_PORT
GENERATED=$(date '+%Y-%m-%d %H:%M:%S')
CONF
echo "CARPETAS=(" >> "$INFO_FILE"
for C in "${CARPETAS_ENCONTRADAS[@]}"; do echo "    \"$C\"" >> "$INFO_FILE"; done
echo ")" >> "$INFO_FILE"
log "Config guardada"

# ── 10. Arrancar tunnel ahora ─────────────────────────────────
info "Arrancando tunnel reverso..."
pkill autossh 2>/dev/null || true
sleep 1
bash ~/tunnel_reverso.sh &
sleep 8

if ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
    -o BatchMode=yes -p "$VPS_PORT" "$VPS_USER@$VPS_IP" \
    "ss -tlnp | grep -q $TUNNEL_PORT" 2>/dev/null; then
    log "Tunnel activo en VPS:$TUNNEL_PORT ✓"
else
    warn "Tunnel aún conectando (esperar ~15 seg más)"
fi

# ── Resumen ───────────────────────────────────────────────────
USUARIO=$(whoami)
IP_WIFI=$(ip -4 addr show wlan0 2>/dev/null | \
    grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Sin WiFi")

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              SETUP COMPLETADO ✓                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Usuario cel    :${NC} $USUARIO"
echo -e "  ${CYAN}IP WiFi        :${NC} $IP_WIFI"
echo -e "  ${CYAN}Puerto sshd    :${NC} 8022"
echo -e "  ${CYAN}VPS puente     :${NC} $VPS_IP"
echo -e "  ${CYAN}Puerto tunnel  :${NC} $TUNNEL_PORT"
echo -e "  ${CYAN}Carpetas       :${NC} ${#CARPETAS_ENCONTRADAS[@]} detectadas"
echo ""
echo -e "${YELLOW}━━━ LLAVE PÚBLICA DE ESTE CEL ━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}$(cat ~/.ssh/id_ed25519.pub)${NC}"
echo ""
echo -e "${YELLOW}━━━ SIGUIENTE PASO ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  1. Corre ${BOLD}compu.sh${NC} en WSL"
echo -e "     Pegá la llave de arriba cuando lo pida"
echo -e "     Usá el puerto: ${BOLD}${TUNNEL_PORT}${NC}"
echo ""
echo -e "${YELLOW}━━━ AUTOSTART ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}✓ Abrís Termux → sshd + tunnel arrancan solos${NC}"
echo -e "  ${YELLOW}⚡ Tras reboot del cel → instalar Termux:Boot (F-Droid)${NC}"
echo -e "    ${CYAN}https://f-droid.org/packages/com.termux.boot/${NC}"
echo ""
