#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  SETUP TERMUX - AUTO CONFIGURADOR
#  Corre esto una sola vez en Termux y ya.
#  Si borras Termux, vuelves a correrlo y queda igual.
# ============================================================

set -e

# ── Colores ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   TERMUX AUTO-SETUP  v1.0            ║${NC}"
echo -e "${BOLD}║   Backup daemon de imágenes          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── 1. Paquetes ──────────────────────────────────────────────
info "Actualizando paquetes..."
pkg update -y -q && pkg upgrade -y -q 2>/dev/null
log "Paquetes actualizados"

info "Instalando dependencias..."
pkg install -y -q openssh rsync iproute2 termux-api 2>/dev/null
log "openssh rsync iproute2 termux-api instalados"

# ── 2. Almacenamiento ────────────────────────────────────────
if [ ! -d "$HOME/storage/dcim" ]; then
    warn "Configurando acceso al almacenamiento..."
    echo ""
    echo -e "${YELLOW}>>> ACEPTA EL POPUP DE PERMISOS EN TU PANTALLA <<<${NC}"
    echo ""
    termux-setup-storage
    sleep 8
    if [ ! -d "$HOME/storage/dcim" ]; then
        err "No se otorgaron permisos. Vuelve a correr el script y acepta el popup."
        exit 1
    fi
fi
log "Almacenamiento accesible"

# ── 3. Generar llave SSH del celular ─────────────────────────
info "Configurando SSH..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
    log "Llave SSH generada"
else
    log "Llave SSH ya existe, skip"
fi

# Levantar sshd sin contraseña (solo llaves)
# Configurar sshd para solo aceptar llaves
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

# Generar host keys si no existen
[ ! -f $PREFIX/etc/ssh/ssh_host_ed25519_key ] && ssh-keygen -t ed25519 -N "" -f $PREFIX/etc/ssh/ssh_host_ed25519_key -q
[ ! -f $PREFIX/etc/ssh/ssh_host_rsa_key ]     && ssh-keygen -t rsa     -N "" -f $PREFIX/etc/ssh/ssh_host_rsa_key -q

pkill sshd 2>/dev/null || true
sleep 1
sshd
log "sshd corriendo en puerto 8022"

# ── 4. Autostart con Termux:Boot ─────────────────────────────
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/01_start_sshd.sh << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Autostart al encender el celular
termux-wake-lock
sshd
BOOT
chmod +x ~/.termux/boot/01_start_sshd.sh
log "Autostart configurado (requiere Termux:Boot de F-Droid)"

# ── 5. Detectar carpetas de imágenes automáticamente ─────────
info "Escaneando carpetas de imágenes en el dispositivo..."

CARPETAS_ENCONTRADAS=()
CARPETAS_CANDIDATAS=(
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
    "storage/shared/Android/media/com.tiktok.android"
    "storage/shared/DCIM"
    "storage/shared/Pictures"
    "storage/shared/Movies"
    "storage/shared/Download"
)

for CARPETA in "${CARPETAS_CANDIDATAS[@]}"; do
    RUTA="$HOME/$CARPETA"
    if [ -d "$RUTA" ]; then
        # Verificar que tenga al menos 1 archivo de imagen/video
        COUNT=$(find "$RUTA" -maxdepth 3 \
            \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
               -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.gif" \
               -o -iname "*.webp" -o -iname "*.heic" \) \
            2>/dev/null | head -1 | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            CARPETAS_ENCONTRADAS+=("$CARPETA")
            log "Encontrada: ~/$CARPETA"
        fi
    fi
done

if [ ${#CARPETAS_ENCONTRADAS[@]} -eq 0 ]; then
    warn "No se encontraron carpetas con imágenes. Usando rutas base."
    CARPETAS_ENCONTRADAS=("storage/dcim/" "storage/pictures/" "storage/movies/")
fi

# ── 6. Guardar config para que la compu la lea ───────────────
INFO_FILE="$HOME/storage/shared/.termux_backup_config"
cat > "$INFO_FILE" << CONF
# Generado automáticamente por setup_termux.sh
# La compu lee este archivo para saber las rutas
PHONE_USER=$(whoami)
PHONE_PORT=8022
GENERATED=$(date '+%Y-%m-%d %H:%M:%S')
CONF

echo "CARPETAS=(" >> "$INFO_FILE"
for C in "${CARPETAS_ENCONTRADAS[@]}"; do
    echo "    \"$C\"" >> "$INFO_FILE"
done
echo ")" >> "$INFO_FILE"

log "Config guardada en $INFO_FILE"

# ── 7. Mostrar info final ────────────────────────────────────
USUARIO=$(whoami)
IP_TS=$(ip -4 addr show tailscale0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
IP_WIFI=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
LLAVE_PUB=$(cat ~/.ssh/id_ed25519.pub)

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              SETUP COMPLETADO ✓                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Usuario  :${NC} $USUARIO"
echo -e "  ${CYAN}IP VPN   :${NC} ${IP_TS:-"Tailscale no activo - ábrela primero"}"
echo -e "  ${CYAN}IP WiFi  :${NC} ${IP_WIFI:-"Sin WiFi"}"
echo -e "  ${CYAN}Puerto   :${NC} 8022"
echo ""
echo -e "  ${CYAN}Carpetas detectadas:${NC} ${#CARPETAS_ENCONTRADAS[@]}"
echo ""
echo -e "${YELLOW}━━━ SIGUIENTE PASO (en tu compu WSL) ━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. Corre ${BOLD}setup_compu.sh${NC} en WSL"
echo -e "  2. Cuando pida la IP Tailscale, pon: ${BOLD}${IP_TS:-"[la IP de la app Tailscale]"}${NC}"
echo -e "  3. Cuando pida el usuario, pon: ${BOLD}$USUARIO${NC}"
echo ""
echo -e "${YELLOW}━━━ LLAVE PÚBLICA DE ESTE CELULAR ━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}$LLAVE_PUB${NC}"
echo ""
echo -e "${YELLOW}  (Guarda esta llave, setup_compu.sh te la pedirá)${NC}"
echo ""
echo -e "${YELLOW}━━━ OPCIONAL: Termux:Boot ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Instala 'Termux:Boot' desde F-Droid para que sshd"
echo -e "  arranque automático cuando reinicies el celular."
echo ""
