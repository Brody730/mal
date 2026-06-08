#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  SETUP CELULAR v3.0 — UN solo comando, cero pasos manuales
#  Auto-registro en VPS, auto-config SSH, auto-tunnel
#  Correr en Termux: bash celu.sh
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

# ============================================================
#  BOOTSTRAP KEY — generada por vps.sh
#  Después de correr vps.sh, reemplazar todo lo que está entre
#  las dos líneas KEYEOF con el output de vps.sh
# ============================================================
BOOTSTRAP_KEY=$(cat << 'KEYEOF'
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBaWbmCGw6lEO2X43xaui4a/X9CqFaiUSa8ntU9MUMfAQAAAKAjsVjmI7FY
5gAAAAtzc2gtZWQyNTUxOQAAACBaWbmCGw6lEO2X43xaui4a/X9CqFaiUSa8ntU9MUMfAQ
AAAEDBaRNxmUhg4MwUvaJSCo/VvTzArLBEr2IKz1Fhbn9TWFpZuYIbDqUQ7ZfjfFq6Lhr9
f0KoVqJRJrye1T0xQx8BAAAAFmJvb3RzdHJhcEBtYWwtcmVnaXN0ZXIBAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
KEYEOF
)

# Config del VPS (fija)
VPS_IP="3.128.129.120"
VPS_USER="tunnel"
# Llave pública del tunnel (para que el cel la acepte)
VPS_TUNNEL_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAWXCv+THPKtTZAcNyP7Fyrz2s81E3CsuHmldCHXRn7p tunnel@ip-172-31-40-218"
# ============================================================

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   SETUP CELULAR  v3.0                ║${NC}"
echo -e "${BOLD}║   Auto-registro — cero pasos manuales║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# Verificar bootstrap key
if echo "$BOOTSTRAP_KEY" | grep -q "REPLACE_WITH"; then
    err "Configurá el BOOTSTRAP_KEY en este script primero.\nCorré vps.sh y copiá la llave que muestra al final."
fi

# ── Única pregunta: nombre del cel ───────────────────────────
echo -e "  ¿Cómo se llama este cel? (ej: A54, Samsung, Moto)"
read -p "  Nombre: " PHONE_NAME
[ -z "$PHONE_NAME" ] && err "El nombre no puede estar vacío"
PHONE_NAME=$(echo "$PHONE_NAME" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')

echo ""

# ── 1. Paquetes ──────────────────────────────────────────────
info "Instalando paquetes..."
pkg update -y -q && pkg upgrade -y -q 2>/dev/null
pkg install -y -q openssh rsync iproute2 termux-api autossh 2>/dev/null
log "Paquetes listos"

# ── 2. Almacenamiento ────────────────────────────────────────
if [ ! -d "$HOME/storage/dcim" ]; then
    warn "Configurando almacenamiento..."
    echo -e "${YELLOW}>>> ACEPTA EL POPUP <<<${NC}"
    termux-setup-storage && sleep 8
    [ ! -d "$HOME/storage/dcim" ] && err "Permisos no otorgados. Corré el script de nuevo."
fi
log "Almacenamiento OK"

# ── 3. Generar llave SSH ─────────────────────────────────────
info "Configurando SSH..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
CEL_PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
log "Llave SSH lista"

# ── 4. Configurar sshd ───────────────────────────────────────
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

for KEYTYPE in ed25519 rsa; do
    KEYFILE="$PREFIX/etc/ssh/ssh_host_${KEYTYPE}_key"
    [ ! -f "$KEYFILE" ] && ssh-keygen -t $KEYTYPE -N "" -f "$KEYFILE" -q
done

# Instalar llave del VPS tunnel user
if ! grep -qF "$VPS_TUNNEL_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$VPS_TUNNEL_PUBKEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

pkill sshd 2>/dev/null || true; sleep 1; sshd
pgrep sshd > /dev/null && log "sshd corriendo en puerto 8022" || err "sshd no arrancó"

# ── 5. AUTO-REGISTRO en el VPS ───────────────────────────────
info "Registrando con el VPS... (puede tardar ~10 seg)"

# Escribir bootstrap key a archivo temporal
BOOTSTRAP_FILE=$(mktemp "$TMPDIR/bs_XXXXXX")
printf '%s\n' "$BOOTSTRAP_KEY" > "$BOOTSTRAP_FILE"
chmod 600 "$BOOTSTRAP_FILE"

PHONE_USER=$(whoami)

# Enviar: "NOMBRE USUARIO LLAVE_PUBLICA"
# Recibir: "PORT=19999" + llaves del WSL
REGISTER_OUTPUT=$(printf '%s %s %s' "$PHONE_NAME" "$PHONE_USER" "$CEL_PUBKEY" | \
    ssh -i "$BOOTSTRAP_FILE" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=20 \
        -o BatchMode=yes \
        "$VPS_USER@$VPS_IP" 2>/dev/null || echo "")

rm -f "$BOOTSTRAP_FILE"

if echo "$REGISTER_OUTPUT" | grep -q "^PORT="; then
    TUNNEL_PORT=$(echo "$REGISTER_OUTPUT" | grep "^PORT=" | cut -d'=' -f2)
    WSL_KEYS=$(echo "$REGISTER_OUTPUT" | grep -v "^PORT=" | grep -v "^$" | grep "^ssh-")
    log "Registro exitoso — puerto asignado: $TUNNEL_PORT"
else
    err "No se pudo registrar con el VPS.\nVerificá que BOOTSTRAP_KEY sea correcto y el VPS esté accesible."
fi

# Instalar llaves del WSL en el cel
if [ -n "$WSL_KEYS" ]; then
    echo "$WSL_KEYS" >> ~/.ssh/authorized_keys
    sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    log "Llaves del WSL instaladas — daemon podrá conectarse"
else
    warn "Sin llaves del WSL todavía — corré compu.sh en la compu primero"
    warn "El cel se registró OK, el daemon se configurará cuando corras compu.sh"
fi

# ── 6. Script de tunnel reverso ───────────────────────────────
info "Configurando tunnel reverso (puerto $TUNNEL_PORT)..."
cat > ~/tunnel_reverso.sh << TUNNEL
#!/data/data/com.termux/files/usr/bin/bash
VPS_IP="${VPS_IP}"
VPS_USER="${VPS_USER}"
TUNNEL_PORT="${TUNNEL_PORT}"
while true; do
    ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || { sleep 30; continue; }
    autossh -M 0 -N \\
        -R \${TUNNEL_PORT}:localhost:8022 \\
        -i ~/.ssh/id_ed25519 \\
        -o ServerAliveInterval=30 \\
        -o ServerAliveCountMax=3 \\
        -o StrictHostKeyChecking=no \\
        -o ExitOnForwardFailure=yes \\
        -o ConnectTimeout=10 \\
        "\${VPS_USER}@\${VPS_IP}" 2>/dev/null
    sleep 10
done
TUNNEL
chmod +x ~/tunnel_reverso.sh
log "Tunnel configurado"

# ── 7. Autostart en .bashrc ───────────────────────────────────
if ! grep -q "auto_start_services" ~/.bashrc 2>/dev/null; then
    cat >> ~/.bashrc << 'AUTOSTART'

# Auto-arranque: sshd + tunnel al abrir Termux
auto_start_services() {
    pgrep sshd > /dev/null || sshd
    pgrep autossh > /dev/null || bash ~/tunnel_reverso.sh &
}
auto_start_services
AUTOSTART
    log "Autostart configurado en .bashrc"
fi

# Boot script para Termux:Boot
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/01_services.sh << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sleep 8
sshd
sleep 2
bash ~/tunnel_reverso.sh &
BOOT
chmod +x ~/.termux/boot/01_services.sh

# ── 8. Escanear carpetas y guardar config ────────────────────
info "Escaneando carpetas de medios..."
CARPETAS_ENCONTRADAS=()
for CARPETA in \
    "storage/dcim/Camera" "storage/dcim/Screenshots" \
    "storage/pictures" "storage/downloads" "storage/movies" \
    "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images" \
    "storage/shared/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video" \
    "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Images" \
    "storage/shared/Android/media/org.telegram.messenger/Telegram/Telegram Video" \
    "storage/shared/DCIM" "storage/shared/Pictures" \
    "storage/shared/Movies" "storage/shared/Download"; do
    RUTA="$HOME/$CARPETA"
    if [ -d "$RUTA" ]; then
        COUNT=$(find "$RUTA" -maxdepth 3 \
            \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.heic" \) \
            2>/dev/null | head -1 | wc -l)
        [ "$COUNT" -gt 0 ] && CARPETAS_ENCONTRADAS+=("$CARPETA") && log "  $CARPETA"
    fi
done

INFO_FILE="$HOME/storage/shared/.termux_backup_config"
{ echo "PHONE_USER=$(whoami)"; echo "PHONE_NAME=$PHONE_NAME"; echo "TUNNEL_PORT=$TUNNEL_PORT"
  echo "GENERATED=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "CARPETAS=("; for C in "${CARPETAS_ENCONTRADAS[@]}"; do echo "  \"$C\""; done; echo ")"; } \
  > "$INFO_FILE" 2>/dev/null && log "Config guardada" || warn "Config no guardada (storage no disponible)"

# ── 9. Arrancar tunnel ahora ──────────────────────────────────
pkill autossh 2>/dev/null || true
bash ~/tunnel_reverso.sh &
sleep 8

if ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes \
    -p 22 "$VPS_USER@$VPS_IP" "ss -tlnp | grep -q $TUNNEL_PORT" 2>/dev/null; then
    log "Tunnel ACTIVO en VPS:$TUNNEL_PORT ✓"
else
    warn "Tunnel conectando... (esperar ~15 seg)"
fi

# ── Resumen ───────────────────────────────────────────────────
IP_WIFI=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Sin WiFi")

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              LISTO ✓  —  ${PHONE_NAME}                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Cel          :${NC} $PHONE_NAME ($(whoami))"
echo -e "  ${CYAN}Puerto tunnel:${NC} $TUNNEL_PORT"
echo -e "  ${CYAN}Carpetas     :${NC} ${#CARPETAS_ENCONTRADAS[@]} detectadas"
echo -e "  ${CYAN}WiFi         :${NC} $IP_WIFI"
echo ""
echo -e "${YELLOW}━━━ SIGUIENTE PASO (solo si no corriste compu.sh aún) ━${NC}"
echo ""
echo -e "  En WSL: ${BOLD}bash compu.sh${NC}"
echo -e "  No necesitás pegar ninguna llave — es automático."
echo ""
echo -e "${YELLOW}━━━ AUTOSTART ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}✓ Abrís Termux → sshd + tunnel arrancan solos${NC}"
echo -e "  ${YELLOW}⚡ Tras reboot → instalar Termux:Boot desde F-Droid${NC}"
echo ""
