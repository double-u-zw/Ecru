#!/usr/bin/env python3
"""Disposable synthetic PDF corpus. No personal PDFs or signing keys are committed."""
from pathlib import Path
import argparse, io, re, subprocess, tempfile
from reportlab.pdfgen import canvas
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DictionaryObject as D, NameObject as N, ArrayObject as A, TextStringObject as T, NumberObject as I, ByteStringObject as B, DecodedStreamObject

def dictionary(**kwargs): return D({N('/'+k):v for k,v in kwargs.items()})
def generate(destination):
    destination.mkdir(parents=True, exist_ok=True)
    buf=io.BytesIO(); c=canvas.Canvas(buf,pagesize=(612,792));c.setFont('Helvetica',16)
    c.drawString(50,700,'Ecru complex PDF synthetic fixture');c.drawString(50,650,'Searchable compatibility text')
    c.acroForm.textfield(name='sample',value='Preserved field value',x=50,y=560,width=260,height=25,forceBorder=True)
    c.showPage();c.setPageSize((792,612));c.drawString(40,540,'Second page landscape');c.save()
    base=buf.getvalue()
    def writer(form=False):
        w=PdfWriter();w.clone_document_from_reader(PdfReader(io.BytesIO(base)))
        if not form:
            w.root_object.pop(N('/AcroForm'),None)
            w.pages[0].pop(N('/Annots'),None)
        return w
    def write(name,w):
        path=destination/(name+'.pdf')
        with path.open('wb') as f:w.write(f)
        return path
    write('ordinary',writer());write('acroform',writer(True))
    w=writer(True);w.root_object['/AcroForm']['/Fields'][0].get_object()[N('/V')]=T('Tampered value');write('tampered-form',w)
    w=writer(); w.pages[1].rotate(90);write('rotated',w)
    w=writer();w._ID=None;w.encrypt('reader-secret','owner-secret',algorithm='AES-256');write('password',w)
    w=writer();w._ID=None;w.encrypt('','owner-secret',algorithm='AES-256',permissions_flag=4);write('restricted',w)
    w=writer();w._ID=None;w.encrypt('reader-secret','owner-secret',algorithm='RC4-128');write('password-rc4',w)
    def attachment(w):
        w.add_attachment('synthetic.txt',b'Embedded attachment must survive\n')
        names=w.root_object['/Names']['/EmbeddedFiles']['/Names']; spec=names[1]
        a=dictionary(Type=N('/Annot'),Subtype=N('/FileAttachment'),Rect=A([I(330),I(560),I(350),I(580)]),FS=spec,Contents=T('Synthetic attachment'))
        w.pages[0][N('/Annots')]=A(list(w.pages[0].get('/Annots',[]))+[w._add_object(a)])
        w.root_object[N('/AF')]=A([spec])
    w=writer();attachment(w);write('attachments',w)
    w=writer(True);attachment(w);write('form-attachments',w)
    w=writer();attachment(w);w.root_object['/Names']['/EmbeddedFiles']['/Names'][1]['/EF']['/F']._data=b'Lost attachment';write('tampered-attachment',w)
    w=writer(True);xfa=DecodedStreamObject();xfa.set_data(b'<xdp:xdp xmlns:xdp="http://ns.adobe.com/xdp/"><template/></xdp:xdp>')
    w.root_object['/AcroForm'][N('/XFA')]=w._add_object(xfa);write('xfa-static',w)
    def actions(w):
        # Direct dictionaries test recursive classification, not byte-label matching.
        w.root_object[N('/OpenAction')]=dictionary(S=N('/JavaScript'),JS=T('app.alert("never executed")'))
        w.pages[0][N('/AA')]=dictionary(O=dictionary(S=N('/Launch'),F=T('never-launch')))
        media=dictionary(Type=N('/Annot'),Subtype=N('/RichMedia'),Rect=A([I(400),I(500),I(450),I(550)]))
        w.pages[0][N('/Annots')]=A([w._add_object(media)])
    w=writer();actions(w);write('active',w)
    w=writer();w.root_object[N('/OpenAction')]=dictionary(S=N('/URI'),URI=T('https://example.invalid/never-open'));write('automatic-uri',w)
    w=writer();actions(w);w.pages[1].rotate(90);w.pages[0].cropbox.lower_left=(20,20);write('active-rotated',w)
    w=writer();w.root_object[N('/Collection')]=dictionary(Type=N('/Collection'));attachment(w);write('portfolio',w)
    w=writer(True);attachment(w);actions(w);w.root_object['/AcroForm'][N('/XFA')]=T('dynamic form');write('combined',w)
    w=writer(); w.root_object[N('/MetadataLabel')]=T('/ByteRange is merely text, not a signature');write('false-signature-label',w)
    w=writer();sig=dictionary(Type=N('/Sig'),Filter=N('/Adobe.PPKLite'),SubFilter=N('/adbe.pkcs7.detached'),ByteRange=A([I(0),I(1111111111),I(2222222222),I(3333333333)]),Contents=B(bytes(8192)))
    field=dictionary(Type=N('/Annot'),Subtype=N('/Widget'),FT=N('/Sig'),T=T('SyntheticSignature'),Rect=A([I(50),I(450),I(300),I(500)]),V=w._add_object(sig))
    ref=w._add_object(field);w.pages[0][N('/Annots')]=A([ref]);w.root_object[N('/AcroForm')]=dictionary(Fields=A([ref]),SigFlags=I(3))
    signed=write('signed',w);raw=signed.read_bytes();m=re.search(rb'/Contents\s*(<[0-9a-fA-F]{16384}>)',raw);start,end=m.span(1)
    br=re.search(rb'/ByteRange\s*(\[[^\]]+\])',raw);span=br.span(1);replacement=f'[0 {start} {end} {len(raw)-end}]'.encode();raw=raw[:span[0]]+replacement.ljust(span[1]-span[0])+raw[span[1]:]
    covered=raw[:start]+raw[end:]
    with tempfile.TemporaryDirectory(prefix='ecru-signature-') as td:
        t=Path(td);(t/'data').write_bytes(covered)
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(t/'key'),'-out',str(t/'cert'),'-subj','/CN=Ecru Synthetic Test Only','-days','2'],check=True,capture_output=True)
        subprocess.run(['openssl','cms','-sign','-binary','-in',str(t/'data'),'-signer',str(t/'cert'),'-inkey',str(t/'key'),'-outform','DER','-out',str(t/'cms')],check=True,capture_output=True)
        subprocess.run(['openssl','cms','-verify','-binary','-inform','DER','-in',str(t/'cms'),'-content',str(t/'data'),'-noverify','-out',str(t/'verified')],check=True,capture_output=True)
        hexdata=(t/'cms').read_bytes().hex().encode();assert len(hexdata)<16384
    signed.write_bytes(raw[:start+1]+hexdata.ljust(16384,b'0')+raw[end-1:])
    (destination/'damaged.pdf').write_bytes(b'%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 42 0 R >> endobj\n%%EOF')
    (destination/'truncated.pdf').write_bytes((destination/'password.pdf').read_bytes()[:150])
    print('Generated synthetic corpus at',destination)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('destination',type=Path);generate(parser.parse_args().destination)
