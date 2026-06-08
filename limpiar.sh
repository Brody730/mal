#!/bin/bash
# ============================================================
#  LIMPIAR — Reset completo del sistema de backup
#  Limpia WSL, da comandos para Termux y VPS
#  Correr en WSL: bash limpiar.sh
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   LIMPIAR — Reset completo           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Limpiar WSL ───────────────────────────────────────────────
info "Limpiando WSL..."

# Daemons y configs
rm -f ~/recolector_*.sh ~/recolector_daemon.sh ~/recolector_daemon.sh.bak
rm -f ~/.phone_backup_*.conf ~/.phone_backup.conf
log "Daemons y configs eliminados"

# Llave SSH backup de la compu
rm -f ~/.ssh/id_ed25519_backup ~/.ssh/id_ed25519_backup.pub
log "Llave SSH backup eliminada"

# Copia redundante del pem (MAL.pem es el original, no necesita copia)
rm -f ~/.ssh/aws_mal.pem
log "aws_mal.pem eliminado (MAL.pem se queda)"

# Cron jobs del backup
(crontab -l 2>/dev/null | grep -v recolector) | crontab - 2>/dev/null || true
log "Cron jobs del backup eliminados"

# Líneas de autostart del cron en .bashrc / .zshrc
for RC in ~/.bashrc ~/.zshrc; do
    [ -f "$RC" ] && sed -i '/service cron start/d' "$RC"
done
log ".bashrc limpiado"

# Tunnel status known_hosts (evita conflictos en nuevo setup)
ssh-keygen -R "[localhost]:19999" 2>/dev/null || true
ssh-keygen -R "[localhost]:19998" 2>/dev/null || true
ssh-keygen -R "[localhost]:19997" 2>/dev/null || true
ssh-keygen -R "3.128.129.120" 2>/dev/null || true
log "known_hosts limpiado"

echo ""
echo -e "${GREEN}WSL limpio ✓${NC}"

# ── Limpiar VPS (via MAL.pem) ─────────────────────────────────
echo ""
echo -e "${YELLOW}━━━ LIMPIANDO VPS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
info "Conectando al VPS..."

PEM_KEY=""
for F in ~/.ssh/MAL.pem ~/.ssh/*.pem; do
    [ -f "$F" ] && PEM_KEY="$F" && break
done

if [ -n "$PEM_KEY" ]; then
    # Limpiar authorized_keys del tunnel user (dejar solo la propia llave del tunnel)
    ssh -i "$PEM_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        ubuntu@3.128.129.120 \
        "sudo -u tunnel bash -c '
            # Guardar solo la propia llave del tunnel (no las del cel ni compu)
            OWN_KEY=\$(cat /home/tunnel/.ssh/id_ed25519.pub 2>/dev/null)
            echo \"\$OWN_KEY\" > /home/tunnel/.ssh/authorized_keys
            chmod 600 /home/tunnel/.ssh/authorized_keys
            echo \"authorized_keys reseteado. Solo queda la llave propia del tunnel.\"
            cat /home/tunnel/.ssh/authorized_keys
        '" 2>/dev/null && \
        log "VPS tunnel user limpiado ✓" || \
        echo -e "  ${RED}No se pudo conectar al VPS. Correlo manualmente:${NC}"

    echo ""
    echo -e "  Si necesitás limpiar el VPS manualmente:"
    echo -e "  ${CYAN}ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120${NC}"
    echo -e "  ${CYAN}sudo -u tunnel bash -c 'cat /home/tunnel/.ssh/id_ed25519.pub > /home/tunnel/.ssh/authorized_keys && chmod 600 /home/tunnel/.ssh/authorized_keys'${NC}"
else
    echo -e "  ${RED}No se encontró MAL.pem. Limpiá el VPS manualmente.${NC}"
fi

# ── Instrucciones para el Celular ─────────────────────────────
echo ""
echo -e "${YELLOW}━━━ LIMPIAR EL CELULAR (pegar en Termux) ━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Pegá estos comandos en Termux del cel:"
echo ""
echo -e "${CYAN}pkill autossh 2>/dev/null; pkill sshd 2>/dev/null${NC}"
echo -e "${CYAN}rm -f ~/tunnel_reverso.sh ~/celu.sh${NC}"
echo -e "${CYAN}rm -rf ~/.ssh${NC}"
echo -e "${CYAN}rm -rf ~/.termux/boot ~/.termux/service${NC}"
echo -e "${CYAN}sed -i '/auto_start_services/,/^# ─/d' ~/.bashrc 2>/dev/null; true${NC}"
echo -e "${CYAN}sed -i '/auto_start_services/d' ~/.bashrc 2>/dev/null; true${NC}"
echo -e "${CYAN}echo 'Cel limpio ✓'${NC}"
echo ""

# ── Resumen final ─────────────────────────────────────────────
echo -e "${YELLOW}━━━ SETUP LIMPIO — ORDEN DE RE-INSTALACIÓN ━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}1.${NC} VPS ya está limpio ✓ (vps.sh no necesita re-correrse)"
echo -e "  ${BOLD}2.${NC} En cada celular (Termux):"
echo -e "     ${CYAN}bash celu.sh${NC}"
echo -e "     Puerto: 19999 para primer cel, 19998 para el segundo, etc."
echo ""
echo -e "  ${BOLD}3.${NC} En WSL, por cada cel:"
echo -e "     ${CYAN}bash compu.sh${NC}"
echo -e "     Pegar la llave pública que mostró celu.sh"
echo ""
echo -e "  ${GREEN}¡Listo! El sistema queda corriendo solo.${NC}"
echo ""

