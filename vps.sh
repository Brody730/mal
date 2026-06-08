#!/bin/bash
# ============================================================
#  VPS SETUP v3.0 — Servidor Puente + Broker de Llaves
#  Correr en AWS EC2: sudo bash vps.sh
#  Solo se corre UNA vez (es idempotente)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   VPS SETUP  v3.0 — Servidor Puente  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── 1. Dependencias ──────────────────────────────────────────
info "Instalando dependencias..."
apt-get update -qq && apt-get install -y -qq openssh-server autossh
log "Dependencias listas"

# ── 2. Configurar sshd para tunnels ──────────────────────────
info "Configurando SSH..."
grep -q "GatewayPorts yes" /etc/ssh/sshd_config      || echo "GatewayPorts yes"      >> /etc/ssh/sshd_config
grep -q "AllowTcpForwarding yes" /etc/ssh/sshd_config || echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
grep -q "ClientAliveInterval" /etc/ssh/sshd_config    || echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
sed -i 's/^#GatewayPorts.*/GatewayPorts yes/'         /etc/ssh/sshd_config
sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
systemctl restart ssh
log "SSH configurado"

# ── 3. Crear usuario tunnel ───────────────────────────────────
info "Configurando usuario tunnel..."
id tunnel &>/dev/null || useradd -m -s /bin/bash tunnel
mkdir -p /home/tunnel/.ssh
chmod 700 /home/tunnel/.ssh

# Llave propia del tunnel (para que celu.sh la instale)
if [ ! -f /home/tunnel/.ssh/id_ed25519 ]; then
    sudo -u tunnel ssh-keygen -t ed25519 -N "" -f /home/tunnel/.ssh/id_ed25519 -q
fi

# ── 4. Bootstrap keypair — para auto-registro de cels ────────
info "Generando bootstrap keypair..."
if [ ! -f /home/tunnel/.ssh/bootstrap_key ]; then
    sudo -u tunnel ssh-keygen -t ed25519 -N "" \
        -f /home/tunnel/.ssh/bootstrap_key -q -C "bootstrap@mal-register"
fi

# ── 5. Script de registro ─────────────────────────────────────
# register.sh: el cel lo llama con su bootstrap key para auto-registrarse
# Recibe por stdin: "PHONE_NAME PHONE_USER ssh-ed25519 AAAA... comment"
# Devuelve: "PORT=19999" + llaves del WSL (para que el cel las agregue)
cat > /home/tunnel/register.sh << 'REGISTER'
#!/bin/bash
REGISTRY="/home/tunnel/keys/registry"
WSL_KEYS="/home/tunnel/keys/wsl_keys"
LOG="/home/tunnel/keys/register.log"
AUTH="/home/tunnel/.ssh/authorized_keys"
mkdir -p /home/tunnel/keys

# Leer datos del cel
read -r PHONE_NAME PHONE_USER KEY_TYPE KEY_DATA KEY_COMMENT 2>/dev/null || true

# Validar
if [ -z "$PHONE_NAME" ] || [ -z "$KEY_TYPE" ] || [ -z "$KEY_DATA" ]; then
    echo "ERROR: datos incompletos"
    exit 1
fi
echo "$KEY_TYPE" | grep -qE "^ssh-(ed25519|rsa|ecdsa)" || { echo "ERROR: llave inválida"; exit 1; }

PHONE_PUBKEY="$KEY_TYPE $KEY_DATA${KEY_COMMENT:+ $KEY_COMMENT}"
PHONE_ID=$(echo "$KEY_DATA" | sha256sum | cut -c1-8)

# ¿Ya registrado?
EXISTING=$(grep "^$PHONE_ID " "$REGISTRY" 2>/dev/null | head -1)
if [ -n "$EXISTING" ]; then
    PORT=$(echo "$EXISTING" | awk '{print $2}')
    echo "$(date '+%Y-%m-%d %H:%M:%S') RE-REGISTER $PHONE_NAME port=$PORT" >> "$LOG"
else
    # Asignar siguiente puerto (19999 → 19998 → 19997...)
    LAST=$(grep -v '^#' "$REGISTRY" 2>/dev/null | awk '{print $2}' | sort -rn | head -1)
    PORT=$((${LAST:-20000} - 1))
    [ "$PORT" -lt 19900 ] && echo "ERROR: demasiados cels registrados" && exit 1
    echo "$PHONE_ID $PORT $PHONE_NAME $PHONE_USER $(date '+%Y-%m-%d')" >> "$REGISTRY"
    echo "$(date '+%Y-%m-%d %H:%M:%S') NEW $PHONE_NAME user=$PHONE_USER port=$PORT" >> "$LOG"
fi

# Agregar llave del cel al authorized_keys
if ! grep -qF "$KEY_DATA" "$AUTH" 2>/dev/null; then
    echo "$PHONE_PUBKEY" >> "$AUTH"
    sort -u "$AUTH" -o "$AUTH"
    chmod 600 "$AUTH"
fi

# Responder: puerto + llaves del WSL
echo "PORT=$PORT"
cat "$WSL_KEYS" 2>/dev/null
REGISTER
chmod +x /home/tunnel/register.sh

# ── 6. Agregar bootstrap key a authorized_keys con restricción ──
BOOTSTRAP_PUBKEY=$(cat /home/tunnel/.ssh/bootstrap_key.pub)
# Solo agregar si no está ya
if ! grep -qF "bootstrap@mal-register" /home/tunnel/.ssh/authorized_keys 2>/dev/null; then
    printf 'command="%s",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding %s\n' \
        "/home/tunnel/register.sh" "$BOOTSTRAP_PUBKEY" \
        >> /home/tunnel/.ssh/authorized_keys
    chmod 600 /home/tunnel/.ssh/authorized_keys
fi

# ── 7. Directorio de llaves del WSL ──────────────────────────
mkdir -p /home/tunnel/keys
touch /home/tunnel/keys/wsl_keys
touch /home/tunnel/keys/registry
chown -R tunnel:tunnel /home/tunnel/.ssh /home/tunnel/keys /home/tunnel/register.sh
chmod 700 /home/tunnel/keys
log "Infraestructura de registro lista"

# ── 8. Script de estado del tunnel ───────────────────────────
cat > /usr/local/bin/tunnel_status.sh << 'STATUS'
#!/bin/bash
echo "=== Estado del Tunnel Reverso ==="
PUERTOS=$(ss -tlnp | grep -oP ':\K1999\d' | sort -rn)
if [ -n "$PUERTOS" ]; then
    for P in $PUERTOS; do
        echo "✓ Puerto $P ACTIVO"
    done
else
    echo "✗ Sin tunnels activos"
fi
echo ""
echo "=== Cels registrados ==="
cat /home/tunnel/keys/registry 2>/dev/null | grep -v '^#' | \
    awk '{printf "  %-8s puerto %-6s %s\n", $3, $2, $5}' || echo "  Ninguno"
STATUS
chmod +x /usr/local/bin/tunnel_status.sh

# ── Resumen ───────────────────────────────────────────────────
VPS_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
BOOTSTRAP_PRIVKEY=$(cat /home/tunnel/.ssh/bootstrap_key)
TUNNEL_PUBKEY=$(cat /home/tunnel/.ssh/id_ed25519.pub)

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                VPS LISTO ✓                          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}IP del VPS:${NC} $VPS_IP"
echo ""
echo -e "${YELLOW}━━━ PASO SIGUIENTE — IMPORTANTE ━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Copiá el BOOTSTRAP PRIVATE KEY de abajo"
echo -e "  y pegalo en ${BOLD}celu.sh${NC} donde dice REPLACE_WITH_..."
echo ""
echo -e "${YELLOW}━━━ BOOTSTRAP PRIVATE KEY (para celu.sh) ━━━━━━━━━━━━━${NC}"
echo ""
echo "$BOOTSTRAP_PRIVKEY"
echo ""
echo -e "${YELLOW}━━━ LLAVE DEL TUNNEL (ya incluida en celu.sh) ━━━━━━━━━${NC}"
echo ""
echo "$TUNNEL_PUBKEY"
echo ""
