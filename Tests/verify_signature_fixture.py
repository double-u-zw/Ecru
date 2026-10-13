#!/usr/bin/env python3
"""Fixture validation only. Ecru itself does not perform cryptographic signature verification."""
import re, subprocess, tempfile, sys
from pathlib import Path

def verifies(path):
 raw=path.read_bytes()
 match=re.search(rb'/ByteRange\s*\[([0-9\s]+)\]',raw)
 if match is None:return False
 ranges=[int(n) for n in match.group(1).split()]
 if len(ranges)!=4 or ranges[0]!=0 or not 0<=ranges[1]<=ranges[2] or ranges[2]+ranges[3]>len(raw):return False
 signature=re.search(rb'/Contents\s*<([0-9A-Fa-f\s]+)>',raw)
 if signature is None:return False
 der=bytes.fromhex(signature.group(1).decode())
 covered=raw[:ranges[1]]+raw[ranges[2]:ranges[2]+ranges[3]]
 with tempfile.TemporaryDirectory(prefix='ecru-signature-verify-') as td:
  t=Path(td);(t/'cms').write_bytes(der);(t/'data').write_bytes(covered)
  result=subprocess.run(['openssl','cms','-verify','-binary','-inform','DER','-in',str(t/'cms'),'-content',str(t/'data'),'-noverify','-out',str(t/'verified')],capture_output=True)
 return result.returncode==0
root=Path(sys.argv[1])
assert not verifies(root/'fixtures/ordinary.pdf'),'unsigned PDF must never verify'
assert verifies(root/'fixtures/signed.pdf'),'synthetic original must have a valid detached CMS signature'
assert not verifies(root/'pdfkit-probe/signed.pdf'),'PDFKit direct rewrite must not be mistaken for a verified signature'
print('PASS: synthetic original CMS verifies; raw PDFKit rewrite has no valid original signature')
