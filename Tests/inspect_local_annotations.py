#!/usr/bin/env python3
"""Verify sharing through standard PDF objects using an independent parser."""
from pathlib import Path
import sys
from pypdf import PdfReader
root=Path(sys.argv[1]);checks=0
for path in sorted(root.glob('*-shared.pdf')):
    pdf=PdfReader(path)
    assert not pdf.is_encrypted,path.name
    annotations=[a.get_object() for p in pdf.pages for a in p.get('/Annots',[])]
    comments=[a for a in annotations if a.get('/Subtype')=='/Text']
    assert any(a.get('/Contents')=='Shared **note**' for a in comments),path.name
    inks=[a for a in annotations if a.get('/Subtype')=='/Ink']
    assert inks and all(a.get('/InkList') and a['/AP']['/N'].get_data() for a in inks),path.name
    assert any('compatibility' in (p.extract_text() or '') for p in pdf.pages),path.name
    checks+=4
    print('PASS:',path.name,'standard comments, InkList, appearance stream and searchable page text')
assert checks>=32,'Expected all shareable compatibility samples'
assert not (root/'print-denied-shared.pdf').exists()
print(checks,'independent sharing checks passed')
