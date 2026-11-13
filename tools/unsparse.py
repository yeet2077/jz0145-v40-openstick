#!/usr/bin/env python3
"""Convert an Android sparse image to a raw image (minimal simg2img)."""
import struct
import sys

CHUNK_RAW, CHUNK_FILL, CHUNK_DONT_CARE, CHUNK_CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4


def unsparse(src, dst):
    with open(src, "rb") as f, open(dst, "wb") as o:
        magic, _maj, _min, fhs, chs, bs, total_blocks, total_chunks, _ = struct.unpack(
            "<IHHHHIIII", f.read(28)
        )
        if magic != 0xED26FF3A:
            sys.exit(f"{src}: not an Android sparse image")
        f.seek(fhs)
        for _ in range(total_chunks):
            ctype, _, blocks, total = struct.unpack("<HHII", f.read(chs))
            data_len = total - chs
            if ctype == CHUNK_RAW:
                o.write(f.read(data_len))
            elif ctype == CHUNK_FILL:
                o.write(f.read(4) * (blocks * bs // 4))
            elif ctype == CHUNK_DONT_CARE:
                o.seek(blocks * bs, 1)
            else:
                f.read(data_len)
        o.truncate(total_blocks * bs)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: unsparse.py <sparse.img> <raw.img>")
    unsparse(sys.argv[1], sys.argv[2])
