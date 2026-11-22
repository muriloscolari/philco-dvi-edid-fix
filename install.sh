#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONNECTOR="HDMI-A-1"
EDID_SRC="$SCRIPT_DIR/edid/philco-dvi.bin"
POSITIONAL_SET=0

usage() {
    cat <<EOF
Uso: sudo $(basename "$0") [OPCOES] [CONECTOR]

Instala o EDID em modo DVI para a TV Philco no initramfs (mkinitcpio) e no GRUB.

Opcoes:
  -c, --connector <NOME>   Nome do conector DRM (padrao: HDMI-A-1)
  -e, --edid <CAMINHO>     Caminho para o arquivo EDID .bin
                           (padrao: $SCRIPT_DIR/edid/philco-dvi.bin)
  -h, --help               Exibe esta ajuda e sai

Exemplos:
  sudo $(basename "$0")
  sudo $(basename "$0") --connector HDMI-A-2
  sudo $(basename "$0") -c HDMI-A-1 -e ./meu-edid-dvi.bin
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--connector)
            if [[ $# -lt 2 ]]; then
                echo "ERRO: A opcao $1 exige um argumento." >&2
                exit 1
            fi
            CONNECTOR="$2"
            shift 2
            ;;
        -e|--edid)
            if [[ $# -lt 2 ]]; then
                echo "ERRO: A opcao $1 exige um argumento." >&2
                exit 1
            fi
            EDID_SRC="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERRO: Opcao desconhecida: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ "$POSITIONAL_SET" -eq 1 ]]; then
                echo "ERRO: Argumento posicional inesperado: $1" >&2
                usage >&2
                exit 1
            fi
            CONNECTOR="$1"
            POSITIONAL_SET=1
            shift
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERRO: Execute este script com sudo:" >&2
    echo "  sudo $(readlink -f "$0")${CONNECTOR:+ --connector $CONNECTOR}" >&2
    exit 1
fi

if [[ ! "$CONNECTOR" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "ERRO: Nome de conector invalido: '$CONNECTOR' (use apenas letras, numeros e hifens, ex: HDMI-A-1)." >&2
    exit 1
fi

if [[ ! -f "$EDID_SRC" ]]; then
    echo "ERRO: Arquivo EDID nao encontrado: $EDID_SRC" >&2
    exit 1
fi

EDID_SIZE="$(wc -c < "$EDID_SRC")"
if [[ "$EDID_SIZE" -eq 0 ]] || (( EDID_SIZE % 128 != 0 )); then
    echo "ERRO: Tamanho invalido de $EDID_SRC ($EDID_SIZE bytes; esperado multiplo de 128 bytes)." >&2
    exit 1
fi

if [[ "$EDID_SIZE" -ne 128 ]]; then
    echo "AVISO: O arquivo EDID tem $EDID_SIZE bytes (EDIDs sem extensao CTA-861 tem 128 bytes)." >&2
fi

if ! compgen -G "/sys/class/drm/card*-${CONNECTOR}" >/dev/null; then
    echo "AVISO: Conector '$CONNECTOR' nao encontrado em /sys/class/drm/." >&2
    echo "       Conectores disponiveis neste sistema:" >&2
    for d in /sys/class/drm/card*-*; do
        [[ -e "$d/status" ]] || continue
        name="$(basename "$d")"
        name="${name#card*-}"
        echo "         - $name ($(cat "$d/status"))" >&2
    done
    echo "       Continuando a instalacao mesmo assim..." >&2
fi

echo "==> Instalando firmware EDID em /usr/lib/firmware/edid/philco.bin"
install -Dm644 "$EDID_SRC" /usr/lib/firmware/edid/philco.bin

MISSING_TOOLS=0
if ! command -v mkinitcpio >/dev/null 2>&1; then
    MISSING_TOOLS=1
fi
if ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-mkconfig >/dev/null 2>&1; then
    MISSING_TOOLS=1
fi

if [[ "$MISSING_TOOLS" -eq 1 ]]; then
    cat >&2 <<EOF
ERRO: Este instalador automatizado suporta sistemas com mkinitcpio e GRUB (Arch / CachyOS).
O arquivo EDID ja foi copiado para /usr/lib/firmware/edid/philco.bin.
Consulte a secao "Outras distribuicoes e bootloaders" no README.md para configurar
seu initramfs (dracut / initramfs-tools) e bootloader (systemd-boot / GRUB) manualmente.
EOF
    exit 1
fi

echo "==> Configurando drop-in do mkinitcpio (/etc/mkinitcpio.conf.d/philco-edid.conf)"
install -d /etc/mkinitcpio.conf.d
cat <<'EOF' > /etc/mkinitcpio.conf.d/philco-edid.conf
FILES+=(/usr/lib/firmware/edid/philco.bin)
EOF

echo "==> Configurando drop-in do GRUB (/etc/default/grub.d/99-philco-edid.cfg)"
install -d /etc/default/grub.d
cat <<EOF > /etc/default/grub.d/99-philco-edid.cfg
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} drm.edid_firmware=${CONNECTOR}:edid/philco.bin"
EOF

echo "==> Regenerando imagens initramfs (mkinitcpio -P)"
mkinitcpio -P

echo "==> Verificando inclusao do EDID nas imagens initramfs"
found_initramfs=0
for img in /boot/initramfs-*.img; do
    [[ -e "$img" ]] || continue
    found_initramfs=1
    if ! lsinitcpio "$img" | grep -E '(^|/)lib/firmware/edid/philco\.bin$' >/dev/null; then
        echo "ERRO: /usr/lib/firmware/edid/philco.bin nao encontrado dentro de $img" >&2
        exit 1
    fi
    echo "    OK: $img"
done
if [[ "$found_initramfs" -eq 0 ]]; then
    echo "ERRO: Nenhuma imagem /boot/initramfs-*.img encontrada para verificacao." >&2
    exit 1
fi

echo "==> Atualizando configuracao do GRUB"
if command -v update-grub >/dev/null 2>&1; then
    update-grub
else
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "==> Verificando parametro no /boot/grub/grub.cfg"
if ! grep -q "drm.edid_firmware=${CONNECTOR}:edid/philco.bin" /boot/grub/grub.cfg; then
    echo "ERRO: Parametro drm.edid_firmware=${CONNECTOR}:edid/philco.bin nao encontrado em /boot/grub/grub.cfg" >&2
    exit 1
fi
echo "    OK: Parametro presente em /boot/grub/grub.cfg"

cat <<EOF

Instalacao concluida com sucesso!
Reinicie o computador para aplicar o EDID DVI na porta ${CONNECTOR}.

Apos reiniciar, verifique com:
  edid-decode /sys/class/drm/card*-${CONNECTOR}/edid
  journalctl -k -b 0 | grep -i edid
EOF
