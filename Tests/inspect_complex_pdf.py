#!/usr/bin/env python3
"""Independent pypdf checks of canonical fields, widget appearances and attachment relations."""
import sys
from pathlib import Path
from pypdf import PdfReader
root=Path(sys.argv[1]);checks=0
def check(ok,label):
 global checks
 assert ok,label
 checks+=1;print('PASS:',label)
for name in ['acroform','form-attachments']:
 for suffix in ['', '-save-as']:
  reader=PdfReader(root/(name+suffix+'.pdf'))
  fields=reader.get_fields()
  check(fields['sample']['/V']=='Preserved field value',name+suffix+' canonical field value')
  widgets=[a.get_object() for p in reader.pages for a in p.get('/Annots',[]) if a.get_object().get('/Subtype')=='/Widget']
  check(len(widgets)==1,name+suffix+' Widget count')
  widget=widgets[0];field=widget.get('/Parent',widget).get_object()
  check(field['/V']==fields['sample']['/V'],name+suffix+' Widget/field value agrees')
  check(len(widget['/AP']['/N'].get_data())>0,name+suffix+' retained appearance stream')
  canonical=reader.trailer['/Root']['/AcroForm']['/Fields'][0]
  check(canonical.idnum==widget.indirect_reference.idnum or widget.get('/Parent').idnum==canonical.idnum,name+suffix+' canonical field relationship')
for name in ['attachments','form-attachments']:
 for suffix in ['', '-save-as']:
  r=PdfReader(root/(name+suffix+'.pdf'));catalog=r.trailer['/Root'];names=catalog['/Names']['/EmbeddedFiles']['/Names'];spec=names[1].get_object()
  check(spec['/EF']['/F'].get_data()==b'Embedded attachment must survive\n',name+suffix+' embedded bytes')
  attachment=[a.get_object() for p in r.pages for a in p.get('/Annots',[]) if a.get_object().get('/Subtype')=='/FileAttachment'][0]
  check(attachment.raw_get('/FS').idnum==names[1].idnum,name+suffix+' FileAttachment name-tree relationship')
  check(catalog['/AF'][0].idnum==names[1].idnum,name+suffix+' associated file relationship')
print(checks,'independent structure checks passed')
