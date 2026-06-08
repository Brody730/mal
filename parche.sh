#!/bin/bash
# ============================================================
#  PARCHE RÁPIDO - Aplica cambios al sistema ya instalado
#  Correr en WSL: bash parche.sh
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   PARCHE v2.1 — WSL                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

DAEMON="$HOME/recolector_daemon.sh"

# ── 1. Quitar --remove-source-files del daemon ────────────────
info "Parcheando daemon (quitar --remove-source-files)..."

if [ ! -f "$DAEMON" ]; then
    warn "No se encontró $DAEMON"
    exit 1
fi

if grep -q "\-\-remove-source-files" "$DAEMON"; then
    # Backup primero
    cp "$DAEMON" "${DAEMON}.bak"
    # Quitar el flag
    sed -i 's/--remove-source-files //' "$DAEMON"
    log "Removido --remove-source-files del daemon"
    log "Backup guardado en ${DAEMON}.bak"
else
    log "--remove-source-files ya no estaba (parche ya aplicado)"
fi

# ── 2. Verificar que quedó bien ───────────────────────────────
if grep -q "\-\-remove-source-files" "$DAEMON"; then
    warn "FALLO: todavía aparece --remove-source-files"
else
    log "Verificación OK — daemon no borra archivos del cel"
fi

# ── 3. Resumen ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Parche aplicado ✓                                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  El daemon ya ${GREEN}NO borra${NC} las fotos del celular después del backup"
echo ""
echo -e "${YELLOW}━━━ PENDIENTE: activar tunnel en el cel ━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  En Termux, corre estos comandos:"
echo ""
echo -e "  ${BOLD}# 1. Instalar termux-services (autostart al abrir Termux):${NC}"
echo -e "  ${CYAN}pkg install termux-services cronie${NC}"
echo ""
echo -e "  ${BOLD}# 2. Configurar sshd como servicio:${NC}"
echo -e "  ${CYAN}mkdir -p ~/.termux/service/sshd${NC}"
echo -e "  ${CYAN}echo -e '#!/data/data/com.termux/files/usr/bin/sh\nexec /data/data/com.termux/files/usr/sbin/sshd -D' > ~/.termux/service/sshd/run${NC}"
echo -e "  ${CYAN}chmod +x ~/.termux/service/sshd/run${NC}"
echo -e "  ${CYAN}sv-enable sshd${NC}"
echo ""
echo -e "  ${BOLD}# 3. Configurar tunnel como servicio:${NC}"
echo -e "  ${CYAN}mkdir -p ~/.termux/service/tunnel${NC}"
cat << 'TEMPLATE'
  # Pega esto completo en Termux:
  cat > ~/.termux/service/tunnel/run << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
sleep 10
exec autossh -M 0 \
    -N \
    -R 19999:localhost:8022 \
    -i $HOME/.ssh/id_ed25519 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    -o ConnectTimeout=10 \
    tunnel@3.128.129.120
EOF
  chmod +x ~/.termux/service/tunnel/run
  sv-enable tunnel
TEMPLATE
echo ""
echo -e "  ${BOLD}# 4. Para reinicios del cel — instalar Termux:Boot:${NC}"
echo -e "  ${CYAN}https://f-droid.org/packages/com.termux.boot/${NC}"
echo ""
echo -e "  ${BOLD}# Verificar que todo corre:${NC}"
echo -e "  ${CYAN}sv status sshd tunnel${NC}"
echo ""
