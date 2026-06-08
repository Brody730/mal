#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  SETUP CELULAR - Auto configurador completo
#  Instala sshd + tunnel reverso al VPS
#  Correr en Termux: bash setup_cel.sh
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
echo -e "${BOLD}║   SETUP CELULAR  v2.0                ║${NC}"
echo -e "${BOLD}║   SSH + Tunnel Reverso a VPS         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Datos del VPS ─────────────────────────────────────────────
VPS_IP="3.128.129.120"
VPS_USER="tunnel"
VPS_PORT="22"
TUNNEL_PORT="19999"   # Puerto en el VPS donde quedará expuesto el cel

# ── 1. Paquetes ──────────────────────────────────────────────
info "Actualizando paquetes..."
pkg update -y -q && pkg upgrade -y -q 2>/dev/null
info "Instalando dependencias..."
pkg install -y -q openssh rsync iproute2 termux-api autossh 2>/dev/null
log "Paquetes listos"

# ── 2. Almacenamiento ────────────────────────────────────────
if [ ! -d "$HOME/storage/dcim" ]; then
    warn "Configurando permisos de almacenamiento..."
    echo ""
    echo -e "${YELLOW}>>> ACEPTA EL POPUP EN TU PANTALLA <<<${NC}"
    echo ""
    termux-setup-storage
    sleep 8
    [ ! -d "$HOME/storage/dcim" ] && err "No se otorgaron permisos. Vuelve a correr el script."
fi
log "Almacenamiento OK"

# ── 3. SSH del celular ───────────────────────────────────────
info "Configurando SSH..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh

[ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
log "Llave SSH del cel lista"

# sshd config — solo llaves, sin contraseña
mkdir -p $PREFIX/etc/ssh
cat > $PREFIX/etc/ssh/sshd_config << 'SSHD'
Port 8022
ListenAddress 0.0.0.0
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp /data/data/com.termux/files/usr/libexec/sftp-server
SSHD

[ ! -f $PREFIX/etc/ssh/ssh_host_ed25519_key ] && ssh-keygen -t ed25519 -N "" -f $PREFIX/etc/ssh/ssh_host_ed25519_key -q
[ ! -f $PREFIX/etc/ssh/ssh_host_rsa_key ]     && ssh-keygen -t rsa     -N "" -f $PREFIX/etc/ssh/ssh_host_rsa_key -q

pkill sshd 2>/dev/null || true; sleep 1; sshd
log "sshd corriendo en puerto 8022"

# ── 4. Instalar llave del VPS en el cel ──────────────────────
info "Instalando llave del VPS en el celular..."

# Llave pública del usuario tunnel del VPS
# Esta llave fue generada por setup_vps.sh
VPS_TUNNEL_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAWXCv+THPKtTZAcNyP7Fyrz2s81E3CsuHmldCHXRn7p tunnel@ip-172-31-40-218"

if ! grep -qF "$VPS_TUNNEL_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$VPS_TUNNEL_PUBKEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    log "Llave del VPS instalada"
else
    log "Llave del VPS ya existía, skip"
fi

# ── 5. Instalar llave del cel en el VPS ──────────────────────
info "Instalando llave del cel en el VPS..."
CEL_PUBKEY=$(cat ~/.ssh/id_ed25519.pub)

# Intentar instalar automáticamente (requiere que el VPS tenga puerto 22 abierto)
ssh -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    -o PasswordAuthentication=no \
    -p "$VPS_PORT" "$VPS_USER@$VPS_IP" \
    "mkdir -p ~/.ssh && echo '$CEL_PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null && \
    log "Llave del cel instalada en VPS" || \
    warn "No se pudo instalar llave en VPS automáticamente (se necesita correr setup_compu.sh primero)"

# ── 6. Crear script de tunnel reverso ────────────────────────
info "Configurando tunnel reverso..."

cat > ~/tunnel_reverso.sh << TUNNEL
#!/data/data/com.termux/files/usr/bin/bash
# Tunnel reverso al VPS
# Este script mantiene una conexión permanente al VPS
# El VPS expone el puerto $TUNNEL_PORT que apunta al sshd de este cel (8022)

VPS_IP="$VPS_IP"
VPS_USER="$VPS_USER"
TUNNEL_PORT="$TUNNEL_PORT"
CEL_PORT="8022"

while true; do
    # Verificar que hay internet antes de intentar
    ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || { sleep 30; continue; }

    # autossh mantiene el tunnel vivo automáticamente
    # -R: expone el puerto 8022 del cel como 19999 en el VPS
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

    sleep 10  # esperar antes de reconectar
done
TUNNEL
chmod +x ~/tunnel_reverso.sh
log "Script de tunnel creado"

# ── 7. Autostart: sshd + tunnel al arrancar el cel ───────────
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/01_start_services.sh << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sleep 5
sshd
sleep 3
bash ~/tunnel_reverso.sh &
BOOT
chmod +x ~/.termux/boot/01_start_services.sh
log "Autostart configurado"

# ── 8. Escanear carpetas de imágenes ─────────────────────────
info "Escaneando carpetas..."
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
        COUNT=$(find "$RUTA" -maxdepth 3 \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.heic" \) 2>/dev/null | head -1 | wc -l)
        [ "$COUNT" -gt 0 ] && CARPETAS_ENCONTRADAS+=("$CARPETA") && log "Encontrada: $CARPETA"
    fi
done

# Guardar config para que la compu la lea
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

# ── 9. Levantar tunnel ahora mismo ───────────────────────────
info "Levantando tunnel al VPS..."
pkill -f tunnel_reverso.sh 2>/dev/null || true
bash ~/tunnel_reverso.sh &
sleep 5

# Verificar tunnel
if ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
    -o BatchMode=yes -p "$VPS_PORT" "$VPS_USER@$VPS_IP" \
    "ss -tlnp | grep -q $TUNNEL_PORT" 2>/dev/null; then
    log "Tunnel activo en VPS:$TUNNEL_PORT ✓"
else
    warn "Tunnel aún conectando... espera 30 seg y corre: bash ~/tunnel_reverso.sh &"
fi

# ── Resumen ───────────────────────────────────────────────────
USUARIO=$(whoami)
IP_WIFI=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Sin WiFi")

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
echo -e "${YELLOW}━━━ LLAVE PÚBLICA DE ESTE CEL (para setup_compu.sh) ━━${NC}"
echo ""
echo -e "  ${GREEN}$(cat ~/.ssh/id_ed25519.pub)${NC}"
echo ""
echo -e "${YELLOW}━━━ SIGUIENTE PASO ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Corre ${BOLD}setup_compu.sh${NC} en tu WSL"
echo -e "  Instala ${BOLD}Termux:Boot${NC} desde F-Droid para autostart"
echo ""
