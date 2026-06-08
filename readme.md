# MAL — Backup Automático de Celulares

Backup silencioso de fotos y videos del celular a la computadora, sin necesidad de abrir puertos en el router. Funciona desde cualquier red WiFi o datos móviles.

## Arquitectura

```
Celular (Termux)
    │
    │  autossh — túnel reverso SSH permanente
    ▼
VPS AWS (puente)  ← puerto 19999 (cel1), 19998 (cel2), ...
    │
    │  rsync via ProxyJump — cada 30 minutos
    ▼
PC Windows (WSL)  →  F:\TELEFONO\
```

El celular siempre *sale* hacia el VPS (no necesita puertos abiertos en el router). La compu se conecta al cel *a través* del VPS usando ProxyJump.

## Componentes

| Archivo | Dónde se corre | Qué hace |
|---------|----------------|----------|
| `vps.sh` | AWS EC2 (una vez) | Configura el servidor puente |
| `celu.sh` | Termux en cada cel | Instala SSH + tunnel reverso |
| `compu.sh` | WSL en la compu | Configura el daemon de backup |

## Prerequisitos

- **VPS**: Instancia EC2 en AWS (t2.micro free tier alcanza). Security group: solo puerto 22 abierto.
- **Celular**: [Termux](https://f-droid.org/packages/com.termux/) instalado desde F-Droid.
- **Compu**: WSL Ubuntu en Windows. Llave `.pem` de la instancia EC2.
- **Opcional pero recomendado**: [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) para autostart tras reinicio del cel.

## Setup (orden importante)

### 1. VPS — una sola vez

```bash
# Conectarse al VPS con la llave .pem
ssh -i MAL.pem ubuntu@TU_IP_AWS

# Correr el setup
curl -O https://raw.githubusercontent.com/TU_USER/mal/main/vps.sh
sudo bash vps.sh
```

Guarda la llave pública que muestra al final — celu.sh la instala automáticamente.

### 2. Celular — por cada cel

En Termux:

```bash
curl -O https://raw.githubusercontent.com/TU_USER/mal/main/celu.sh
bash celu.sh
# Ingresar el puerto tunnel (19999 para el primero, 19998 para el segundo, etc.)
# Copiar la llave pública que muestra al final
```

### 3. Compu — por cada cel

En WSL:

```bash
bash compu.sh
# Ingresar: nombre del cel, puerto (mismo que en celu.sh), usuario Termux, carpeta destino
# Pegar la llave pública del cel cuando la pida
```

## Multi-celular

Cada celular usa un puerto distinto en el VPS:

```
cel1  →  puerto 19999  →  F:\TELEFONO_CEL1
cel2  →  puerto 19998  →  F:\TELEFONO_CEL2
cel3  →  puerto 19997  →  F:\TELEFONO_CEL3
```

`compu.sh` genera un daemon y config separados por celular:
- `~/.phone_backup_NOMBRE.conf`
- `~/recolector_NOMBRE.sh`

## Comandos útiles

```bash
# Sync manual de un cel
bash ~/recolector_NOMBRE.sh

# Ver log en tiempo real
tail -f /mnt/f/TELEFONO/.backup.log

# Estado del tunnel en el VPS
ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120 tunnel_status.sh

# Ver todos los tunnels activos
ssh -i ~/.ssh/MAL.pem ubuntu@3.128.129.120 "ss -tlnp | grep 199"

# Ver cron jobs
crontab -l

# Estado de sshd y tunnel en el cel (Termux)
pgrep sshd && echo "sshd OK" || echo "sshd DOWN"
pgrep autossh && echo "tunnel OK" || echo "tunnel DOWN"
```

## Autostart del celular

**Al abrir Termux**: `sshd` y el tunnel arrancan automáticamente vía `.bashrc` (instalado por celu.sh). No se necesita hacer nada.

**Tras reiniciar el cel**: Instalar [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) desde F-Droid. El boot script ya está en `~/.termux/boot/01_start_services.sh`.

## Bugs encontrados y corregidos (historial)

Durante el desarrollo se encontraron varios problemas no documentados de esta stack:

**SSH / Autenticación**
- `CEL_PUBKEY` no se instalaba en el VPS → el tunnel nunca podía autenticarse. Fix: compu.sh instala ambas llaves en el mismo paso.
- `SSH ProxyJump` usa la llave default del sistema para el salto intermedio, no la `-i` especificada. Fix: agregar la llave default del WSL (`~/.ssh/id_ed25519.pub`) al tunnel user en el VPS.
- El VPS no puede conectarse a su propio IP externo (Security Group de AWS lo bloquea). Fix: usar `localhost` como destino del tunnel, no el IP externo.

**Termux / Android**
- `UsePAM no` en sshd_config no está soportado en Termux → sshd fallaba al arrancar. Fix: eliminado.
- `sshd -D` (foreground mode) causa problemas en Termux. Fix: usar `sshd` directo (daemoniza solo).
- `termux-services` con runit genera locks que entran en bucle. Fix: reemplazado por autostart simple en `.bashrc`.
- La ruta `/data/data/com.termux/files/usr/sbin/sshd` no existe en Termux (está en `/usr/bin/`). Fix: usar `sshd` sin path absoluto.

**rsync**
- `rsync --dry-run` sin `--itemize-changes` no imprime nada a stdout → `grep -c "^>"` siempre devuelve 0 → el rsync real nunca corría. Fix: agregar `--itemize-changes`.
- `grep -c "^>" || echo 0` producía `0\n0` cuando no había archivos nuevos → error `integer expression expected`. Fix: eliminar `|| echo 0`.
- Sin `--include="*/"` rsync no recursa en subdirectorios. Fix: agregar `--include="*/"`.
- `--remove-source-files` borraba las fotos del celular tras el backup. Fix: eliminado.

## Estructura de archivos generados

```
~/.phone_backup_NOMBRE.conf   ← config por cel
~/recolector_NOMBRE.sh        ← daemon de backup por cel
~/tunnel_reverso.sh           ← script del tunnel (en Termux)
~/.termux/boot/               ← scripts de autostart
~/.bashrc                     ← auto_start_services() agregado
```

## Notas de seguridad

- El usuario `tunnel` en el VPS solo puede hacer SSH — no tiene sudo ni shell útil.
- Las conexiones usan claves Ed25519 (sin contraseña).
- El Security Group del VPS tiene abierto solo el puerto 22.
- El puerto del tunnel (19999, 19998, etc.) **no** necesita estar abierto en el Security Group — el acceso es siempre a través del puerto 22 via ProxyJump.
