"""Deterministic synthetic workloads; never overwrite existing trial inputs."""
from pathlib import Path
from reportlab.pdfgen import canvas
from PIL import Image
import random,sys
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
if not (root/'large.pdf').exists():
 rng=random.Random(87421);pdf=canvas.Canvas(str(root/'large.pdf'),pageCompression=1,invariant=1)
 for i in range(16):
  image=Image.frombytes('RGB',(512,512),rng.randbytes(512*512*3))
  pdf.drawInlineImage(image,0,0,512,512);pdf.drawString(20,700,'Ecru stability sample needle page '+str(i));pdf.showPage()
 pdf.save()
if not (root/'ordinary.pdf').exists():
 pdf=canvas.Canvas(str(root/'ordinary.pdf'),pageCompression=1,invariant=1)
 for i in range(4):pdf.drawString(20,700,'Ecru stability sample needle page '+str(i));pdf.showPage()
 pdf.save()
if not (root/'search.pdf').exists():
 pdf=canvas.Canvas(str(root/'search.pdf'),pageCompression=1,invariant=1)
 for i in range(800):
  for j in range(30):pdf.drawString(20,750-j*22,'needle alpha beta repeated sample page '+str(i))
  pdf.showPage()
 pdf.save()
