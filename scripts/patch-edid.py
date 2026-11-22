#!/usr/bin/env python3
"""Remove the CTA-861 extension block from an EDID to force DVI signaling."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys

EDID_HEADER = b"\x00\xff\xff\xff\xff\xff\xff\x00"
DUMMY_DESCRIPTOR = b"\x00\x00\x00\x10" + bytes(14)


def decode_active_resolution(dtd: bytes) -> tuple[int, int]:
    """Return (h_active, v_active) from an 18-byte Detailed Timing Descriptor."""
    h_active = dtd[2] | ((dtd[4] >> 4) << 8)
    v_active = dtd[5] | ((dtd[7] >> 4) << 8)
    return h_active, v_active


def decode_image_size_mm(dtd: bytes) -> tuple[int, int]:
    """Return (h_mm, v_mm) from an 18-byte Detailed Timing Descriptor."""
    h_mm = dtd[12] | ((dtd[14] >> 4) << 8)
    v_mm = dtd[13] | ((dtd[14] & 0x0F) << 8)
    return h_mm, v_mm


def build_1080p_cvt_rb_dtd(h_mm: int, v_mm: int) -> bytes:
    """Build DTD for 1920x1080 @ 60.003 Hz (138.66 MHz) [+/-] CVT-RB."""
    pclk = 13866  # 138.66 MHz in 10 kHz units
    h_active, h_blank = 1920, 160
    v_active, v_blank = 1080, 31
    h_fp, h_sync = 48, 32
    v_fp, v_sync = 3, 5

    dtd = bytearray(18)
    dtd[0] = pclk & 0xFF
    dtd[1] = (pclk >> 8) & 0xFF
    dtd[2] = h_active & 0xFF
    dtd[3] = h_blank & 0xFF
    dtd[4] = (((h_active >> 8) & 0x0F) << 4) | ((h_blank >> 8) & 0x0F)
    dtd[5] = v_active & 0xFF
    dtd[6] = v_blank & 0xFF
    dtd[7] = (((v_active >> 8) & 0x0F) << 4) | ((v_blank >> 8) & 0x0F)
    dtd[8] = h_fp & 0xFF
    dtd[9] = h_sync & 0xFF
    dtd[10] = ((v_fp & 0x0F) << 4) | (v_sync & 0x0F)
    dtd[11] = (
        (((h_fp >> 8) & 0x03) << 6)
        | (((h_sync >> 8) & 0x03) << 4)
        | (((v_fp >> 4) & 0x03) << 2)
        | ((v_sync >> 4) & 0x03)
    )
    dtd[12] = h_mm & 0xFF
    dtd[13] = v_mm & 0xFF
    dtd[14] = (((h_mm >> 8) & 0x0F) << 4) | ((v_mm >> 8) & 0x0F)
    dtd[15] = 0
    dtd[16] = 0
    dtd[17] = 0x1A  # Non-interlaced, digital separate sync, H+, V-
    return bytes(dtd)


def patch_edid(raw: bytes, inject_1080p: bool = True) -> bytes:
    """Strip extension blocks from raw EDID and optionally inject 1080p CVT-RB."""
    if len(raw) < 128:
        raise ValueError(f"EDID invalido: tamanho {len(raw)} bytes (esperado >= 128).")
    if raw[:8] != EDID_HEADER:
        raise ValueError("EDID invalido: cabecalho EDID 1.x nao encontrado.")

    edid = bytearray(raw[:128])
    slots = [bytes(edid[54 + i * 18 : 54 + (i + 1) * 18]) for i in range(4)]

    dtds: list[bytes] = []
    display_descs: list[bytes] = []
    for slot in slots:
        if slot[0] != 0 or slot[1] != 0:
            dtds.append(slot)
        elif slot != bytes(18) and slot[:4] != b"\x00\x00\x00\x10":
            display_descs.append(slot)

    if inject_1080p:
        has_1080p = any(decode_active_resolution(d) == (1920, 1080) for d in dtds)
        if not has_1080p:
            if len(dtds) >= 4:
                raise ValueError(
                    "Nao ha espaco no Bloco 0 para adicionar o DTD 1920x1080 (ja existem 4 DTDs)."
                )
            h_mm, v_mm = decode_image_size_mm(dtds[0]) if dtds else (575, 323)
            dtds.append(build_1080p_cvt_rb_dtd(h_mm, v_mm))

        remaining_slots = 4 - len(dtds)
        kept_descs = display_descs[:remaining_slots]
        final_slots = dtds + kept_descs
        while len(final_slots) < 4:
            final_slots.append(DUMMY_DESCRIPTOR)

        for idx, slot in enumerate(final_slots):
            edid[54 + idx * 18 : 54 + (idx + 1) * 18] = slot

    edid[126] = 0x00
    edid[127] = (256 - (sum(edid[:127]) % 256)) % 256
    return bytes(edid)


def verify_with_edid_decode(path: Path) -> None:
    """Validate generated EDID using edid-decode if installed."""
    edid_decode_bin = shutil.which("edid-decode")
    if not edid_decode_bin:
        print("Aviso: 'edid-decode' nao encontrado no PATH; pulando validacao.", file=sys.stderr)
        return

    proc = subprocess.run([edid_decode_bin, str(path)], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise RuntimeError(f"edid-decode falhou com codigo {proc.returncode}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Remove o bloco de extensao CTA-861 de um arquivo EDID para forcar modo DVI "
            "e injeta 1920x1080@60Hz CVT-RB no Bloco 0."
        )
    )
    parser.add_argument(
        "-i",
        "--input",
        required=True,
        type=Path,
        help="Caminho do EDID original (ex: /sys/class/drm/card1-HDMI-A-1/edid)",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        type=Path,
        help="Caminho de saida para o EDID de 128 bytes em modo DVI",
    )
    parser.add_argument(
        "--no-1080p",
        action="store_true",
        help="Apenas remove o bloco CTA-861 sem injetar o modo 1920x1080@60Hz CVT-RB",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="Pula a validacao automatica via edid-decode",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    raw = args.input.read_bytes()
    patched = patch_edid(raw, inject_1080p=not args.no_1080p)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(patched)

    if not args.no_verify:
        verify_with_edid_decode(args.output)

    print(f"EDID DVI gerado com sucesso: {args.output} ({len(patched)} bytes, checksum 0x{patched[127]:02x})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
