#!/bin/bash
# ============================================================
#  SETUP VPS (AWS) - Servidor puente
#  Correr en el VPS: bash setup_vps.sh
#  Solo se corre UNA vez
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   VPS SETUP  -  Servidor Puente      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── 1. Dependencias ──────────────────────────────────────────
info "Instalando dependencias..."
apt update -qq && apt install -y -qq openssh-server autossh
log "Dependencias instaladas"

# ── 2. Configurar sshd para permitir tunnels ─────────────────
info "Configurando SSH para tunnels..."
sed -i 's/#GatewayPorts no/GatewayPorts yes/'         /etc/ssh/sshd_config
sed -i 's/GatewayPorts no/GatewayPorts yes/'           /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/' /etc/ssh/sshd_config
sed -i 's/#ClientAliveInterval 0/ClientAliveInterval 30/'  /etc/ssh/sshd_config
sed -i 's/#ClientAliveCountMax 3/ClientAliveCountMax 3/'   /etc/ssh/sshd_config

# Asegurar que estén aunque no existieran
grep -q "GatewayPorts yes"      /etc/ssh/sshd_config || echo "GatewayPorts yes"      >> /etc/ssh/sshd_config
grep -q "AllowTcpForwarding yes" /etc/ssh/sshd_config || echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
grep -q "ClientAliveInterval"    /etc/ssh/sshd_config || echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config

systemctl restart ssh
log "SSH configurado"

# ── 3. Crear usuario tunnel ───────────────────────────────────
info "Creando usuario tunnel..."
id tunnel &>/dev/null || useradd -m -s /bin/bash tunnel
mkdir -p /home/tunnel/.ssh
chmod 700 /home/tunnel/.ssh
chown -R tunnel:tunnel /home/tunnel/.ssh

# Generar llave SSH para tunnel
if [ ! -f /home/tunnel/.ssh/id_ed25519 ]; then
    sudo -u tunnel ssh-keygen -t ed25519 -N "" -f /home/tunnel/.ssh/id_ed25519 -q
fi
chown tunnel:tunnel /home/tunnel/.ssh/id_ed25519*
log "Usuario tunnel listo"

# ── 4. Guardar config ─────────────────────────────────────────
VPS_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com)
TUNNEL_PUBKEY=$(cat /home/tunnel/.ssh/id_ed25519.pub)

cat > /home/tunnel/vps_info.txt << INFO
VPS_IP=$VPS_IP
TUNNEL_USER=tunnel
TUNNEL_PORT=19999
TUNNEL_PUBKEY=$TUNNEL_PUBKEY
INFO
chown tunnel:tunnel /home/tunnel/vps_info.txt

# ── 5. Crear script monitor de tunnel ────────────────────────
cat > /usr/local/bin/tunnel_status.sh << 'STATUS'
#!/bin/bash
echo "=== Estado del Tunnel Reverso ==="
if ss -tlnp | grep -q ":19999"; then
    echo "✓ Tunnel ACTIVO en puerto 19999"
    echo "  Celular accesible via: ssh -p 19999 localhost"
else
    echo "✗ Tunnel NO activo (celular desconectado o sin WiFi)"
fi
echo ""
echo "Conexiones activas:"
ss -tlnp | grep -E "19999|2222|8022" || echo "  Ninguna"
STATUS
chmod +x /usr/local/bin/tunnel_status.sh

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              VPS LISTO ✓                            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}IP VPS         :${NC} $VPS_IP"
echo -e "  ${CYAN}Usuario tunnel :${NC} tunnel"
echo -e "  ${CYAN}Puerto tunnel  :${NC} 19999"
echo ""
echo -e "${YELLOW}━━━ LLAVE PÚBLICA DEL TUNNEL (para el celular) ━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}$TUNNEL_PUBKEY${NC}"
echo ""
echo -e "${YELLOW}  El setup_cel.sh la instalará automáticamente${NC}"
echo -e "${YELLOW}  El setup_compu.sh la usará para conectarse${NC}"
echo ""
echo -e "  Ver estado del tunnel : ${BOLD}tunnel_status.sh${NC}"
echo ""

