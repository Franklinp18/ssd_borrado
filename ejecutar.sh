#!/usr/bin/env bash
# secure_erase.sh - Borrado seguro de SSD SATA/NVMe segun NIST SP 800-88 Rev.1
# Requiere: hdparm, nvme-cli, smartmontools (opcional para SMART)
# Uso:
#   sudo ./secure_erase.sh --device /dev/sdX|/dev/nvme0n1 --operator "Nombre Apellido" [--allow-suspend]

set -euo pipefail

OPERATOR=""
DEVICE=""
ALLOW_SUSPEND=false
LOG_DIR="/var/log"
START_TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
HOSTNAME="$(hostname)"

die() { echo "ERROR: $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*" >&2; }

usage(){
  cat <<EOF
Uso:
  sudo $0 --device /dev/sdX|/dev/nvme0n1 --operator "Nombre Apellido" [--allow-suspend]

Opciones:
  --device         Ruta del dispositivo de bloque a borrar (OBLIGATORIO).
  --operator       Nombre del operador responsable (OBLIGATORIO).
  --allow-suspend  Permite suspender el sistema si el SSD SATA esta en estado 'frozen'.
  -h, --help       Muestra esta ayuda.
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2;;
    --operator) OPERATOR="${2:-}"; shift 2;;
    --allow-suspend) ALLOW_SUSPEND=true; shift;;
    -h|--help) usage; exit 0;;
    *) die "Argumento no reconocido: $1";;
  esac
done

[[ -n "$DEVICE" ]] || { usage; die "Debe especificar --device"; }
[[ -n "$OPERATOR" ]] || { usage; die "Debe especificar --operator"; }
[[ $EUID -eq 0 ]] || die "Debe ejecutarse como root."
command -v lsblk >/dev/null || die "lsblk no disponible."
[[ -b "$DEVICE" ]] || die "No existe dispositivo: $DEVICE"

# Detectar tipo por nombre
BASE="$(basename "$DEVICE")"
TYPE="sata"
[[ "$BASE" =~ ^nvme ]] && TYPE="nvme"

TS_ID="$(date +'%Y%m%d_%H%M%S')"
SAFE_DEV="$(echo "$BASE" | tr '/' '_')"
LOG_FILE="$LOG_DIR/secure_erase_${SAFE_DEV}_${TS_ID}.log"
REPORT_FILE="$LOG_DIR/secure_erase_report_${SAFE_DEV}_${TS_ID}.txt"

# Redirigir stdout/err al log (y a consola)
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

info "==== Borrado seguro iniciado ===="
info "Fecha (UTC): $START_TS"
info "Host: $HOSTNAME"
info "Operador: $OPERATOR"
info "Dispositivo: $DEVICE (tipo detectado: $TYPE)"
info "Log: $LOG_FILE"
info "Reporte: $REPORT_FILE"

# Verificar montajes y desmontar
MOUNTS=$(lsblk -no MOUNTPOINT "$DEVICE" | grep -v "^$" || true)
if [[ -n "$MOUNTS" ]]; then
  warn "Particiones montadas detectadas:"
  echo "$MOUNTS"
  warn "Desmontando y desactivando swap..."
  swapoff -a || true
  while read -r mp; do
    [[ -n "$mp" ]] && umount -f "$mp" || true
  done < <(lsblk -no MOUNTPOINT "$DEVICE" | grep -v "^$" || true)
fi

# Confirmacion explicita
echo
read -rp "CONFIRME: Se borrara COMPLETAMENTE $DEVICE. Escriba 'BORRAR' para continuar: " CONFIRM
[[ "$CONFIRM" == "BORRAR" ]] || die "Confirmacion no recibida. Abortando."

START_EPOCH=$(date +%s)

if [[ "$TYPE" == "sata" ]]; then
  command -v hdparm >/dev/null || die "hdparm no disponible."
  info "=== SATA / hdparm ==="
  hdparm -I "$DEVICE" | egrep -i 'Model|Serial|firmware|Security|erase|frozen|enhanced' || true

  # Estado frozen
  if hdparm -I "$DEVICE" | grep -qi "frozen"; then
    if $ALLOW_SUSPEND; then
      warn "El dispositivo esta 'frozen'. Intentando suspension..."
      systemctl suspend || die "Fallo al suspender. Intente manualmente."
      sleep 3
      info "Reanudado. Re-verificando estado 'frozen'..."
      hdparm -I "$DEVICE" | grep -i frozen || true
      hdparm -I "$DEVICE" | grep -qi "not.*frozen" || die "Sigue 'frozen'. Intente reconectar SATA o BIOS AHCI."
    else
      die "Dispositivo 'frozen'. Reejecute con --allow-suspend o haga hot-plug/BIOS AHCI."
    fi
  fi

  # Establecer contrasena temporal 'p'
  info "Estableciendo contrasena temporal..."
  hdparm --user-master u --security-set-pass p "$DEVICE"

  # Ejecutar erase (enhanced si soportado)
  if hdparm -I "$DEVICE" | grep -qi "supported: enhanced erase"; then
    info "Ejecutando SECURITY ERASE ENHANCED..."
    hdparm --user-master u --security-erase-enhanced p "$DEVICE"
  else
    info "Enhanced no soportado. Ejecutando SECURITY ERASE..."
    hdparm --user-master u --security-erase p "$DEVICE"
  fi

  # Deshabilitar contrasena
  info "Deshabilitando contrasena..."
  hdparm --security-disable p "$DEVICE" || true

  # Verificacion
  info "Verificacion post-borrado (estado de seguridad):"
  hdparm -I "$DEVICE" | egrep -i 'Security|frozen|enhanced|erase' || true

  info "Lectura inicial (4 KiB) para inspeccion (puede no ser concluyente):"
  hexdump -C -n 4096 "$DEVICE" | head -n 20 || true

  if command -v smartctl >/dev/null; then
    info "SMART (resumen):"
    smartctl -a "$DEVICE" | egrep -i 'Model|Serial|Reallocated|Media_Wearout|Power_On_Hours|Power_Cycle_Count' || true
  fi

elif [[ "$TYPE" == "nvme" ]]; then
  command -v nvme >/dev/null || die "nvme-cli no disponible."
  info "=== NVMe / nvme-cli ==="
  nvme id-ctrl "$DEVICE" || true

  # Preferir sanitize crypto erase
  SANITIZE_OK=false
  if nvme id-ctrl "$DEVICE" | grep -qi "sanicap"; then
    info "Intentando SANITIZE (Crypto Erase)..."
    if nvme sanitize "$DEVICE" -a3 -n 0 -N 0; then
      SANITIZE_OK=true
    else
      warn "Sanitize Crypto fallo. Intentando Sanitize Block Erase..."
      nvme sanitize "$DEVICE" -a1 -n 0 -N 0 && SANITIZE_OK=true || warn "Sanitize fallo."
    fi
  fi

  if ! $SANITIZE_OK; then
    info "Usando FORMAT con Secure Erase Setting (SES)."
    if nvme format "$DEVICE" -s2; then
      info "FORMAT -s2 (crypto erase) ejecutado."
    else
      info "FORMAT -s2 no soportado. Probando -s1 (user data erase)."
      nvme format "$DEVICE" -s1
    fi
  fi

  info "Verificando estado sanitize/format:"
  nvme smart-log "$DEVICE" || true
  nvme sanitize-log "$DEVICE" || true

  info "Lectura inicial (4 KiB) para inspeccion:"
  dd if="$DEVICE" bs=4096 count=1 status=none | hexdump -C | head -n 20 || true

else
  die "Tipo de dispositivo no reconocido."
fi

END_EPOCH=$(date +%s)
DUR=$((END_EPOCH - START_EPOCH))
END_TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

info "==== Borrado seguro finalizado ===="
info "Duracion (s): $DUR"
info "Fecha fin (UTC): $END_TS"

# Construir reporte
{
  echo "==== REPORTE DE BORRADO SEGURO ===="
  echo "Fecha inicio (UTC): $START_TS"
  echo "Fecha fin (UTC)  : $END_TS"
  echo "Host             : $HOSTNAME"
  echo "Operador         : $OPERATOR"
  echo "Dispositivo      : $DEVICE"
  echo "Tipo detectado   : $TYPE"
  echo "Log detallado    : $LOG_FILE"
  echo "Duracion (s)     : $DUR"
  echo "Resultado        : COMPLETADO (verificar evidencias y politicas internas)"
} | tee "$REPORT_FILE"

exit 0
