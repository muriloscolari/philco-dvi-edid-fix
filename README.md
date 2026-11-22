# philco-dvi-edid-fix

![Linux](https://img.shields.io/badge/Linux-DRM%20%2F%20KMS-blue?logo=linux&logoColor=white)
![AMDGPU](https://img.shields.io/badge/GPU-AMDGPU%20%2F%20DRM-red?logo=amd&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

Fix via override de **EDID** para forçar modo **DVI** em TVs **Philco** no Linux, eliminando o *sharpening* exagerado, overscan e pós-processamento de imagem aplicados quando a TV recebe sinal HDMI.

---

## 📌 O Problema

TVs Philco de entrada (como modelos com ID EDID `AAA0000 - PHILCO`) aplicam processamento agressivo de vídeo (*sharpening* artificial, realce de bordas e redução de nitidez em textos) sempre que detectam um sinal **HDMI**. Além disso, muitas delas reiniciam o modo de imagem ao ligar/desligar, exigindo que você troque manualmente para o modo *Graphic* ou *PC* no menu da TV toda vez.

No Windows, esse problema costuma ser resolvido usando o **Custom Resolution Utility (CRU)** para apagar todos os *Extension Blocks* e adicionar `1920x1080 @ 60Hz` como *Detailed Resolution* no Bloco 0 — fazendo a TV reconhecer a entrada como **DVI** e desativar o pós-processamento automaticamente.

Este repositório traz o mesmo fix pronto para Linux usando `drm.edid_firmware`, além de um script Python para gerar o EDID corrigido para qualquer outra TV semelhante.

---

## 🧠 Como este fix funciona (HDMI → DVI)

O EDID original da TV possui dois blocos de 128 bytes (`256 bytes` no total):
1. **Block 0 (Base EDID):** contém as resoluções básicas (no caso da Philco, apenas até `1360x768`).
2. **Block 1 (CTA-861 Extension Block):** contém o bloco **HDMI Vendor-Specific Data Block (VSDB `00-0C-03`)**, áudio HDMI, YCbCr e os modos `1920x1080`.

Quando o kernel Linux (ex.: `amdgpu` / `i915` / `nouveau`) lê o bloco HDMI VSDB no CTA-861, ele envia **sinal HDMI** (com InfoFrames AVI/Vendor e áudio). Ao substituir o EDID por uma versão de **128 bytes sem o bloco CTA-861**, o driver passa a enviar **sinal DVI single-link puro** (RGB sem metadados/áudio HDMI), fazendo a TV exibir a entrada como **DVI** e entregar imagem limpa 1:1.

Como o modo `1920x1080` originalmente só existia dentro do bloco CTA-861 removido, o arquivo [`edid/philco-dvi.bin`](edid/philco-dvi.bin) injeta `1920x1080 @ 60.003 Hz (138.66 MHz) [+/-]` (CVT-RB) diretamente no Bloco 0 junto com `1360x768 @ 60.015 Hz`, exatamente como na configuração do CRU no Windows.

---

## 📋 Especificações do EDID incluído

| Propriedade | Valor (`edid/philco-dvi.bin`) |
| --- | --- |
| **Fabricante / Modelo** | `AAA0000 - PHILCO` (EDID 1.3) |
| **Tamanho do arquivo** | `128 bytes` |
| **Blocos de extensão** | `0` (CTA-861 removido) |
| **Checksum** | `0x20` (válido) |
| **DTD 1 (Preferida)** | `1360x768 @ 60.015 Hz` (`85.50 MHz`, polaridade `+/+`) |
| **DTD 2 (CVT-RB)** | `1920x1080 @ 60.003 Hz` (`138.66 MHz`, polaridade `+/-`) |
| **Limites de faixa** | `24-85 Hz` V, `15-80 kHz` H, pixel clock máx. `160 MHz` |

---

## 📥 Instalação Rápida (Arch / CachyOS + GRUB)

Clone o repositório e execute o instalador:

```bash
git clone https://github.com/muriloscolari/philco-dvi-edid-fix.git
cd philco-dvi-edid-fix
sudo ./install.sh
```

Por padrão, o `install.sh` aplica o override na porta **`HDMI-A-1`**. Para descobrir o nome exato da porta da sua TV:

```bash
for d in /sys/class/drm/card*-*; do [ -e "$d/status" ] && echo "$(basename "$d"): $(cat "$d/status")"; done
```

Caso sua TV esteja conectada em outra porta (ex.: `HDMI-A-2`), passe `--connector`:

```bash
sudo ./install.sh --connector HDMI-A-2
```

O que o `install.sh` faz:
1. Instala o firmware em `/usr/lib/firmware/edid/philco.bin`.
2. Cria o drop-in `/etc/mkinitcpio.conf.d/philco-edid.conf` (`FILES+=(/usr/lib/firmware/edid/philco.bin)`), garantindo carregamento no Early KMS.
3. Cria o drop-in `/etc/default/grub.d/99-philco-edid.cfg` adicionando `drm.edid_firmware=<CONECTOR>:edid/philco.bin`.
4. Executa `mkinitcpio -P`, verifica a inclusão dentro das imagens `/boot/initramfs-*.img` com `lsinitcpio`, atualiza o GRUB e valida o `/boot/grub/grub.cfg`.

Após a conclusão, **reinicie o computador**.

---

## 🛠️ Gerando um EDID para outra TV

Se o seu modelo de TV for diferente e você quiser remover o bloco CTA-861 a partir do próprio EDID dela (preservando nome, dimensões físicas e DTD original):

```bash
# 1. Extraia o EDID atual da porta da TV
cat /sys/class/drm/card1-HDMI-A-1/edid > edid-original.bin

# 2. Gere a versão DVI de 128 bytes (injeta 1920x1080@60Hz CVT-RB se não existir no Bloco 0)
./scripts/patch-edid.py -i edid-original.bin -o meu-edid-dvi.bin

# 3. Instale usando o arquivo gerado
sudo ./install.sh --connector HDMI-A-1 --edid ./meu-edid-dvi.bin
```

Use `--no-1080p` no `patch-edid.py` se quiser apenas remover o bloco CTA-861 sem adicionar `1920x1080`.

---

## ⚙️ Outras distribuições e bootloaders

O `install.sh` configura automaticamente apenas **Arch/CachyOS com `mkinitcpio` e GRUB**. Em outros sistemas:

1. Copie o firmware:
   ```bash
   sudo install -Dm644 edid/philco-dvi.bin /usr/lib/firmware/edid/philco.bin
   ```
2. Inclua `/usr/lib/firmware/edid/philco.bin` no initramfs:
   - **dracut (Fedora / openSUSE / CachyOS-dracut):**
     ```bash
     echo 'install_items+=" /usr/lib/firmware/edid/philco.bin "' | sudo tee /etc/dracut.conf.d/99-philco-edid.conf
     sudo dracut --regenerate-all --force
     ```
   - **Debian / Ubuntu (`initramfs-tools`):** crie um hook em `/etc/initramfs-tools/hooks/` copiando `/usr/lib/firmware/edid/philco.bin` para `${DESTDIR}/lib/firmware/edid/philco.bin` (ou `/usr/lib/firmware/edid/philco.bin`) e rode `sudo update-initramfs -u`.
3. Adicione à linha de comando do kernel (ex.: na linha `options` de `/boot/loader/entries/*.conf` para `systemd-boot` ou em `/etc/default/grub`):
   ```text
   drm.edid_firmware=HDMI-A-1:edid/philco.bin
   ```
4. Reinicie o sistema.

---

## 🔍 Verificação após reiniciar

Confirme que o kernel carregou o EDID de `128 bytes` sem o bloco CTA-861:

```bash
wc -c /sys/class/drm/card*-HDMI-A-1/edid
edid-decode /sys/class/drm/card*-HDMI-A-1/edid
journalctl -k -b 0 | grep -i edid
```

A saída do `edid-decode` deve exibir apenas o **Block 0, Base EDID** (sem `Block 1, CTA-861 Extension Block`).

---

## ⚠️ Observações

- **Áudio HDMI:** assim como no Windows com CRU em modo DVI, enviar sinal DVI puro **desativa o áudio via HDMI** para a TV.
- **Resolução no KDE / ambiente gráfico:** no primeiro boot após aplicar o fix, o compositor pode selecionar a DTD 1 (`1360x768`) por padrão; basta escolher `1920x1080 @ 60Hz` nas Configurações de Tela do sistema.
- **Vínculo com a porta física:** o parâmetro `drm.edid_firmware` aplica-se à porta especificada (ex.: `HDMI-A-1`). Se mudar o cabo de porta na placa de vídeo, atualize o conector com `sudo ./install.sh --connector <NOVA_PORTA>`.

---

## 🗑️ Desinstalação

Para remover completamente o override e voltar ao EDID original da TV:

```bash
sudo ./uninstall.sh
```

Em seguida, reinicie o computador.

---

## 📄 Licença

Distribuído sob a licença **MIT**. Veja o arquivo [LICENSE](LICENSE) para mais detalhes.
