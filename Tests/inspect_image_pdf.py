#!/usr/bin/env python3
"""Independent standard-PDF appearance/quality check; no Ecru renderer involved."""
import base64,json,sys
from io import BytesIO
from pathlib import Path
from PIL import Image
from pypdf import PdfReader
pdf=PdfReader(Path(sys.argv[1]));checks=0
carrier=next(a.get_object() for p in pdf.pages for a in p.get('/Annots',[]) if '/LeafInkDocument' in a.get_object())
envelope=json.loads(carrier['/LeafInkDocument']);model=json.loads(base64.b64decode(envelope['payload']))
for p in pdf.pages:
 for ref in p.get('/Annots',[]):
  annotation=ref.get_object()
  if annotation.get('/Subtype')!='/Stamp':continue
  geometry=json.loads(annotation['/EcruImageGeometry'])
  source=Image.open(BytesIO(base64.b64decode(model['imageAssets'][geometry['asset']]))).convert('RGBA')
  appearance=annotation['/AP']['/N'].get_object()
  resources=appearance['/Resources']['/XObject']
  images=[v.get_object() for v in resources.values() if v.get_object().get('/Subtype')=='/Image']
  assert images,'Missing standard image resource'
  x=images[0];assert (x['/Width'],x['/Height'])==source.size,'PDF appearance downsampled'
  assert x['/BitsPerComponent']==8 and '/DCTDecode' not in str(x.get('/Filter')),'Lossy image appearance'
  rgb=Image.frombytes('RGB',source.size,x.get_data())
  mask=x['/SMask'].get_object();alpha=Image.frombytes('L',source.size,mask.get_data())
  assert alpha.tobytes()==source.getchannel('A').tobytes(),'Alpha channel changed'
  error=max(max(abs(a-b) for a,b in zip(original[:3],saved)) for original,saved in zip(source.get_flattened_data() if hasattr(source,'get_flattened_data') else source.getdata(),rgb.get_flattened_data() if hasattr(rgb,'get_flattened_data') else rgb.getdata()) if original[3]==255)
  assert error<=1,f'Opaque source pixels changed by {error}'
  checks+=1;print('PASS: full-resolution lossless standard image appearance, identical alpha, opaque RGB error',error)
assert checks>0
assert 'original selectable text' in pdf.pages[0].extract_text()
print(checks,'standard image appearances verified; original selectable text retained')
