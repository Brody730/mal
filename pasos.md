# Backup Automático de Celulares — Pasos

## Primera vez (VPS ya está listo)

### Por cada celular nuevo:

**1. En Termux (cel):**
```bash
bash celu.sh
```
→ Elegir puerto: `19999` primer cel, `19998` segundo, `19997` tercero...
→ Copiar la llave pública que muestra al final

**2. En WSL (compu):**
```bash
bash compu.sh
```
→ Ingresar: nombre del cel, puerto (mismo que arriba), usuario Termux, carpeta destino
→ Pegar la llave pública del paso anterior

**Listo.** El backup corre solo cada 30 min.

---

## Reset completo

**1. WSL** (también limpia el VPS):
```bash
bash limpiar.sh
```

**2. Termux** (pegar en el cel):
```bash
pkill autossh; pkill sshd; rm -rf ~/.ssh ~/.termux/boot; sed -i '/auto_start_services/d' ~/.bashrc; echo OK
```

Luego volver al paso 1 de arriba.

---

## Comandos del día a día

```bash
# Ver si está jalando
ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120 tunnel_status.sh

# Forzar sync ahora
bash ~/recolector_NOMBRE.sh

# Ver log
tail -f /mnt/f/TELEFONO/.backup.log
```

## Puertos por cel
| Cel | Puerto |
|-----|--------|
| 1er cel | 19999 |
| 2do cel | 19998 |
| 3er cel | 19997 |

