# MAL — Mobile Automatic Link
## Backup Automático y Silencioso de Celulares
**Documentación Técnica v3.0** — Jozet Mendoza · OnAxis Consulting ERP

---

## 1. Descripción General

MAL es un sistema de backup silencioso que sincroniza fotos y videos de uno o más celulares Android hacia la PC, sin necesidad de abrir puertos en el router ni intervención manual.

El sistema usa un túnel SSH reverso a través de un VPS en AWS como puente. El celular siempre inicia la conexión hacia afuera, por lo que funciona desde cualquier red WiFi o datos móviles.

### Arquitectura

```
Celular (Termux)
    │
    │  autossh — túnel reverso SSH permanente
    ▼
VPS AWS  ← puerto 19999 (cel1), 19998 (cel2) ...
    │
    │  rsync via ProxyJump — cada 30 minutos
    ▼
PC Windows (WSL)  →  F:\BACKUPS\nombre_cel\
```

### Componentes del Sistema

| Archivo | Dónde se corre | Qué hace | Frecuencia |
|---|---|---|---|
| `vps.sh` | AWS EC2 (ubuntu) | Configura servidor puente, usuario tunnel, bootstrap keypair y auto-registro | Una sola vez |
| `celu.sh` | Termux en el cel | Instala SSH, genera llaves, se auto-registra en el VPS y configura el túnel | Por cada cel nuevo |
| `compu.sh` | WSL en la PC | Configura llaves, daemon maestro de rsync y cron cada 30 min | Una sola vez |
| `parche.sh` | WSL en la PC | Aplica parches al daemon ya instalado | Cuando hay cambios |
| `limpiar.sh` | WSL en la PC | Reset completo: WSL, VPS y comandos para el cel | Para reinstalación |

---

## 2. Prerequisitos

### VPS (AWS EC2)
- Instancia EC2 — t2.micro (free tier es suficiente)
- Sistema operativo: Ubuntu 22.04 LTS
- Security Group: solo puerto 22 abierto (SSH)
- Llave `.pem` descargada guardada en `~/.ssh/MAL.pem`

### Celular
- Termux instalado desde **F-Droid** (NO desde Play Store — versión desactualizada)
- Termux:Boot instalado desde F-Droid (para autostart tras reinicio)
- Permisos de almacenamiento concedidos a Termux

### PC (WSL)
- WSL Ubuntu corriendo en Windows
- Llave `.pem` del EC2 en `~/.ssh/MAL.pem`
- `rsync` y `openssh-client` instalados

> **NOTA:** Los puertos del túnel (19999, 19998...) NO necesitan estar abiertos en el Security Group del VPS. El acceso siempre va por puerto 22 via ProxyJump.

---

## 3. Guía de Instalación

### Paso 1 — VPS (una sola vez)

```bash
ssh -i ~/.ssh/MAL.pem ubuntu@TU_IP_AWS
curl -O https://raw.githubusercontent.com/TU_USER/mal/main/vps.sh
sudo bash vps.sh
```

El script muestra al final el **BOOTSTRAP PRIVATE KEY**. Copiarlo y pegarlo en `celu.sh` donde dice `KEYEOF`.

> `vps.sh` es idempotente — se puede correr múltiples veces sin romper nada.

### Paso 2 — Celular (por cada cel)

```bash
bash celu.sh

# El script pregunta el nombre del cel (ej: A54, Samsung, Moto)
# Luego hace todo solo: paquetes, SSH, registro en VPS, tunnel
```

Al finalizar muestra el puerto asignado automáticamente (19999, 19998, etc.) y confirma que el tunnel está activo.

### Paso 3 — PC (una sola vez)

```bash
bash compu.sh

# Pide: ruta al .pem y carpeta base de backups
# Detecta todos los cels registrados automáticamente
```

El daemon maestro (`recolector_master.sh`) se instala en cron cada 30 minutos y sincroniza todos los cels activos.

---

## 4. Referencia de Scripts

### vps.sh — Configuración del Servidor Puente

Corre en AWS EC2 como root (`sudo bash vps.sh`). Solo se ejecuta una vez.

**Qué hace internamente:**
- Instala `openssh-server` y `autossh`
- Habilita `GatewayPorts` y `AllowTcpForwarding` en `sshd_config`
- Crea usuario `tunnel` (sin sudo, solo SSH)
- Genera bootstrap keypair (Ed25519) para auto-registro de cels
- Instala `register.sh` — script que asigna puertos y distribuye llaves
- Crea `tunnel_status.sh` en `/usr/local/bin`

**register.sh (instalado en el VPS):**

El cel lo llama via SSH con la bootstrap key. Recibe por stdin `PHONE_NAME PHONE_USER LLAVE_PUBLICA`. Responde con `PORT=XXXXX` y las llaves del WSL para instalar en el cel.

```bash
# Lógica de asignación de puertos:
# Primer cel  → 19999
# Segundo cel → 19998
# Tercer cel  → 19997
# Máximo ~100 cels (hasta puerto 19900)
```

---

### celu.sh — Setup del Celular

Corre en Termux. Solo pregunta el nombre del cel; hace todo lo demás solo.

**Flujo de ejecución:**
1. Instala paquetes: `openssh`, `rsync`, `autossh`, `termux-api`, `iproute2`
2. Configura almacenamiento con `termux-setup-storage`
3. Genera llave SSH Ed25519 del cel
4. Configura `sshd` en puerto 8022 (solo `PubkeyAuthentication`)
5. Llama al VPS con la bootstrap key para auto-registrarse
6. Recibe el puerto asignado y las llaves del WSL
7. Genera `tunnel_reverso.sh` con el puerto asignado
8. Configura autostart en `.bashrc` y `~/.termux/boot/`
9. Escanea carpetas de medios y guarda config en `.termux_backup_config`
10. Arranca el tunnel y verifica que está activo

**Autostart configurado:**

```bash
# En .bashrc (al abrir Termux):
auto_start_services() {
    pgrep sshd > /dev/null || sshd
    pgrep autossh > /dev/null || bash ~/tunnel_reverso.sh &
}

# En ~/.termux/boot/01_services.sh (tras reinicio del cel):
termux-wake-lock
sleep 8; sshd; sleep 2
bash ~/tunnel_reverso.sh &
```

---

### compu.sh — Setup de la PC

Corre en WSL. Setup único que detecta todos los cels automáticamente.

**Qué hace internamente:**
- Busca `MAL.pem` en `~/.ssh/` o pide la ruta
- Genera llave SSH backup: `~/.ssh/id_ed25519_backup`
- Sube las llaves del WSL al VPS (para distribución a nuevos cels)
- Guarda config maestra en `~/.mal_master.conf`
- Genera daemon maestro: `~/recolector_master.sh`
- Instala cron cada 30 minutos
- Corre primera sync inmediata

**Daemon maestro — recolector_master.sh:**

Lee el registro del VPS (`/home/tunnel/keys/registry`) para descubrir todos los cels. Por cada cel:
- Verifica si el tunnel está activo en el VPS (`ss -tlnp`)
- Intenta conectar via SSH (ProxyJump a través del VPS)
- Lee las carpetas de medios desde `.termux_backup_config` del cel
- Corre `rsync --dry-run` para contar archivos nuevos
- Descarga solo archivos nuevos (jpg, png, mp4, mov, gif, webp, heic, 3gp)
- Guarda log en `DEST/.backup.log`

> **IMPORTANTE:** rsync NO borra archivos del cel. El flag `--remove-source-files` fue removido (ver `parche.sh`).

---

### parche.sh — Parches Rápidos

Aplica correcciones al daemon ya instalado sin necesidad de reinstalar todo.

```bash
# En WSL:
bash parche.sh

# Qué hace la versión actual (v2.1):
# - Quita --remove-source-files del daemon (ya no borra fotos del cel)
# - Hace backup del daemon original (.bak)
```

---

### limpiar.sh — Reset Completo

Limpia todo para empezar de cero. Corre en WSL; también limpia el VPS automáticamente.

**Lo que limpia en WSL:**
- Daemons y configs: `recolector_*.sh`, `.mal_master.conf`
- Llave SSH backup: `id_ed25519_backup`
- Cron jobs del backup
- Líneas de autostart en `.bashrc` y `.zshrc`
- `known_hosts` (evita conflictos de fingerprint)

**Lo que limpia en el VPS:**
- `authorized_keys` del usuario tunnel (deja solo la llave propia del tunnel)

**Comandos para limpiar el cel (pegar en Termux):**

```bash
pkill autossh 2>/dev/null; pkill sshd 2>/dev/null
rm -f ~/tunnel_reverso.sh ~/celu.sh
rm -rf ~/.ssh
rm -rf ~/.termux/boot ~/.termux/service
sed -i '/auto_start_services/d' ~/.bashrc 2>/dev/null; true
echo 'Cel limpio OK'
```

---

## 5. Soporte Multi-Celular

El sistema soporta múltiples celulares sin configuración adicional. Cada cel que corra `celu.sh` se registra automáticamente y recibe un puerto único.

| Celular | Puerto Tunnel | Carpeta Destino |
|---|---|---|
| 1er cel | 19999 | `BASE_DIR/nombre_cel1/` |
| 2do cel | 19998 | `BASE_DIR/nombre_cel2/` |
| 3er cel | 19997 | `BASE_DIR/nombre_cel3/` |
| N-ésimo cel | 20000 - N | `BASE_DIR/nombre_celN/` |

El daemon maestro lee el registro del VPS en cada ejecución, detectando nuevos cels automáticamente sin necesidad de re-correr `compu.sh`.

---

## 6. Carpetas Sincronizadas

`celu.sh` escanea automáticamente las siguientes carpetas al registrarse. Solo incluye las que existen y contienen archivos de media:

| Carpeta | Contenido |
|---|---|
| `storage/dcim/Camera` | Fotos y videos de la cámara principal |
| `storage/dcim/Screenshots` | Capturas de pantalla |
| `storage/pictures` | Imágenes generales |
| `storage/downloads` | Descargas |
| `storage/movies` | Videos |
| `storage/shared/Android/media/com.whatsapp/.../WhatsApp Images` | Imágenes de WhatsApp |
| `storage/shared/Android/media/com.whatsapp/.../WhatsApp Video` | Videos de WhatsApp |
| `storage/shared/Android/media/org.telegram.messenger/.../Telegram Images` | Imágenes de Telegram |
| `storage/shared/Android/media/org.telegram.messenger/.../Telegram Video` | Videos de Telegram |
| `storage/shared/DCIM` | DCIM compartido |
| `storage/shared/Pictures` | Fotos compartidas |
| `storage/shared/Download` | Descargas compartidas |

**Tipos de archivo sincronizados:** `.jpg` `.jpeg` `.png` `.mp4` `.mov` `.gif` `.webp` `.heic` `.3gp`

---

## 7. Comandos del Día a Día

### Desde WSL

```bash
# Sync manual inmediata
bash ~/recolector_master.sh

# Ver log en tiempo real
tail -f /mnt/f/BACKUPS/.master.log

# Ver log de un cel específico
tail -f /mnt/f/BACKUPS/nombre_cel/.backup.log

# Estado del VPS y tunnels activos
ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120 tunnel_status.sh

# Ver tunnels activos en el VPS
ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120 "ss -tlnp | grep 199"

# Ver cels registrados
ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120 \
  'sudo -u tunnel cat /home/tunnel/keys/registry'

# Ver cron instalado
crontab -l
```

### Desde Termux (cel)

```bash
# Verificar sshd y tunnel corriendo
pgrep sshd && echo "sshd OK" || echo "sshd DOWN"
pgrep autossh && echo "tunnel OK" || echo "tunnel DOWN"

# Reiniciar tunnel manualmente
pkill autossh; bash ~/tunnel_reverso.sh &

# Ver config del cel (puerto y carpetas)
cat ~/storage/shared/.termux_backup_config
```

---

## 8. Bugs Encontrados y Corregidos

### SSH / Autenticación

| Problema | Causa | Fix aplicado |
|---|---|---|
| `CEL_PUBKEY` no se instalaba en el VPS | El tunnel nunca podía autenticarse | `compu.sh` instala ambas llaves en el mismo paso |
| SSH ProxyJump ignora `-i` para el salto intermedio | Usa la llave default del sistema | Se agrega `id_ed25519.pub` del WSL al tunnel user del VPS |
| VPS no conecta a su propio IP externo | Security Group de AWS lo bloquea internamente | Usar `localhost` como destino del tunnel, no el IP externo |

### Termux / Android

| Problema | Causa | Fix aplicado |
|---|---|---|
| `UsePAM no` en sshd_config | No soportado en Termux → sshd falla al arrancar | Eliminado del `sshd_config` |
| `sshd -D` causa problemas | Foreground mode inestable en Termux | Usar `sshd` directo (daemoniza solo) |
| `termux-services` con runit genera locks | Bucle infinito en `sv-enable` | Reemplazado por autostart en `.bashrc` |
| Ruta `/usr/sbin/sshd` no existe en Termux | sshd está en `/usr/bin/` | Usar `sshd` sin path absoluto |

### rsync

| Problema | Causa | Fix aplicado |
|---|---|---|
| `--dry-run` sin `--itemize-changes` | No imprime a stdout → `grep -c` siempre 0 → rsync real nunca corre | Agregar `--itemize-changes` |
| `grep -c \|\| echo 0` produce `0\n0` | Error: `integer expression expected` | Eliminar `\|\| echo 0` |
| rsync no recursa en subdirectorios | Falta `--include="*/"` | Agregar `--include="*/"` antes de `--exclude="*"` |
| `--remove-source-files` borraba fotos del cel | Flag incluido por error | Eliminado (`parche.sh` lo quita del daemon existente) |

---

## 9. Notas de Seguridad

- El usuario `tunnel` en el VPS no tiene sudo ni shell útil — solo puede establecer tunnels SSH
- Todas las conexiones usan claves Ed25519 (sin contraseña)
- La bootstrap key tiene restricciones en `authorized_keys`: `no-pty`, `no-port-forwarding`, `no-X11-forwarding` — solo puede ejecutar `register.sh`
- El Security Group del VPS tiene abierto solo el puerto 22
- Los puertos del tunnel (19999, 19998...) NO están abiertos hacia internet — solo se accede via ProxyJump por puerto 22
- Las llaves privadas del cel nunca salen del dispositivo

> **MODELO DE AMENAZA:** El sistema asume que el VPS y la PC son de confianza. Si el VPS es comprometido, un atacante podría acceder a los cels via tunnel. Recomendación: rotar llaves periódicamente con `limpiar.sh` + reinstalación.

---

## 10. Estructura de Archivos

### En WSL (PC)

```
~/.mal_master.conf                ← Config maestra (VPS IP, PEM, carpeta base)
~/.ssh/id_ed25519_backup          ← Llave SSH backup generada por compu.sh
~/.ssh/id_ed25519_backup.pub
~/recolector_master.sh            ← Daemon de sync (generado por compu.sh)

BASE_DIR/
├── .master.log                   ← Log general de todas las syncs
├── nombre_cel1/                  ← Fotos del primer cel
│   └── .backup.log
├── nombre_cel2/                  ← Fotos del segundo cel
│   └── .backup.log
└── ...
```

### En Termux (cel)

```
~/.ssh/id_ed25519                 ← Llave SSH del cel
~/.ssh/authorized_keys            ← Llaves del VPS tunnel y WSL
~/tunnel_reverso.sh               ← Script del tunnel autossh
~/.termux/boot/01_services.sh     ← Autostart tras reinicio
~/.bashrc                         ← auto_start_services() agregado

~/storage/shared/
└── .termux_backup_config         ← Config del cel (puerto, carpetas)
```

### En el VPS

```
/home/tunnel/
├── .ssh/
│   ├── id_ed25519                ← Llave del usuario tunnel
│   ├── bootstrap_key             ← Bootstrap keypair para auto-registro
│   └── authorized_keys           ← Llaves autorizadas (cels + WSL + bootstrap)
├── register.sh                   ← Script de auto-registro
└── keys/
    ├── registry                  ← Registro de cels (ID, puerto, nombre, user)
    └── wsl_keys                  ← Llaves del WSL (para distribuir a nuevos cels)

/usr/local/bin/tunnel_status.sh   ← Diagnóstico rápido
```
