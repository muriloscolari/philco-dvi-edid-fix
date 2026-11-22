#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Uso: sudo $(basename "$0")

Remove o firmware EDID instalado (/usr/lib/firmware/edid/philco.bin), os drop-ins
do mkinitcpio e do GRUB, e regenera as configuracoes de boot.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 0 ]]; then
    echo "ERRO: Argumento inesperado: $1" >&2
    usage >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERRO: Execute este script com sudo:" >&2
    echo "  sudo $(readlink -f "$0")" >&2
    exit 1
fi

echo "==> Removendo firmware EDID e arquivos de configuracao"
rm -f /usr/lib/firmware/edid/philco.bin
rm -f /etc/mkinitcpio.conf.d/philco-edid.conf
rm -f /etc/default/grub.d/99-philco-edid.cfg

if command -v mkinitcpio >/dev/null 2>&1; then
    echo "==> Regenerando imagens initramfs (mkinitcpio -P)"
    mkinitcpio -P
fi

if command -v update-grub >/dev/null 2>&1; then
    echo "==> Atualizando configuracao do GRUB (update-grub)"
    update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    echo "==> Atualizando configuracao do GRUB (grub-mkconfig)"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

cat <<'EOF'

Remocao concluida com sucesso!
Reinicie o computador para voltar a usar o EDID original da TV.
EOF
