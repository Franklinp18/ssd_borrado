# secure-erase-ssd (NIST 800-88)

Borrado **seguro** de SSD **SATA/NVMe** en Linux usando `hdparm` y `nvme-cli`, con **evidencias en logs** y **reporte** para auditoría.

> ⚠️ **Advertencia**: Este procedimiento destruye *todo* el contenido del disco seleccionado. Verifica el dispositivo dos veces. Evita puentes USB–SATA que no pasen comandos ATA/NVMe.

---

## ✨ Características

- Detecta tipo de dispositivo: **SATA** (`hdparm`) o **NVMe** (`nvme-cli`).
- Ejecuta **ATA Secure Erase / Enhanced** (SATA) o **Sanitize / Format (SES)** (NVMe).
- Maneja estado **frozen** (opcional: suspensión).
- Genera **log detallado** (`/var/log/secure_erase_*.log`) y **reporte** (`/var/log/secure_erase_report_*.txt`).
- Verificaciones post-borrado (estado de seguridad, lectura inicial, SMART opcional).

---

## 📜 Cumplimiento

Alineado con **NIST SP 800-88 Rev.1**:
- Para SSD: **Purge** mediante ATA Secure Erase/Enhanced (SATA), **Sanitize/Format Secure** (NVMe), o **Crypto Erase** (SED).
- Si el saneamiento lógico no es posible → **Destroy** (físico) según política interna.

---

## 🧩 Requisitos

- Linux (Ubuntu/Debian recomendados).
- `sudo`/root.
- Paquetes:
  ```bash
  sudo apt-get update
  sudo apt-get install -y hdparm nvme-cli smartmontools
