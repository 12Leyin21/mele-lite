"""苹果要的 ES256 签名 JWT（推送和 Apple Music 共用，09-30 从 apns.py 抽出来）。"""
from __future__ import annotations

import base64
import json

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def sign(pem: bytes, kid: str, claims: dict) -> str:
    header = _b64(json.dumps({"alg": "ES256", "kid": kid}, separators=(",", ":")).encode())
    body = _b64(json.dumps(claims, separators=(",", ":")).encode())
    key = serialization.load_pem_private_key(pem, password=None)
    r, s = decode_dss_signature(key.sign(f"{header}.{body}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{header}.{body}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
