"""Fault boundaries for candidate signing/notarization, using disposable fixtures."""
from pathlib import Path
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
import tempfile, unittest, json, plistlib
s=SourceFileLoader('signing',str(Path(__file__).resolve().parents[1]/'Scripts/release-signing.py')).load_module()
CONFIG=dict(ECRU_SIGN_IDENTITY='identity',ECRU_SIGN_TEAM='TEAM',ECRU_NOTARY_PROFILE='profile')
DETAILS='Authority=Developer ID Application: Test (TEAM)\nTeamIdentifier=TEAM\nTimestamp=Oct 14\nflags=0x10000(runtime)\n'

class SigningTests(unittest.TestCase):
 def test_protect_installed_and_external(self):
  for path in ['/Applications/Ecru.app','/Applications/Ecru.app/nested.app','/tmp/Ecru.app','/tmp/Ecru.dmg']:
   with self.assertRaises(ValueError):s.protected(path)
 def test_signing_requires_explicit_configuration(self):
  with patch.dict(s.os.environ,{},clear=True),self.assertRaises(ValueError):s.configuration()
 def test_reject_wrong_certificate_team_timestamp_runtime(self):
  for details in [DETAILS.replace('TEAM','OTHER'),DETAILS.replace('Developer ID Application','Apple Development'),DETAILS.replace('Timestamp=Oct 14\n',''),DETAILS.replace('runtime','')]:
   with self.subTest(details=details),patch.object(s,'run',side_effect=lambda *a,**k: details if '-dv' in a else ''),self.assertRaises(ValueError):s.verify(Path('Ecru.app'),'TEAM')
 def test_reject_entitlements(self):
  xml=plistlib.dumps({'com.apple.security.get-task-allow':True}).decode()
  with patch.object(s,'run',side_effect=lambda *a,**k: DETAILS if '-dv' in a else xml if '--entitlements' in a else ''),self.assertRaises(ValueError):s.verify(Path('Ecru.app'),'TEAM')
 def test_reject_development_before_signing(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'Ecru.app';(p/'Contents').mkdir(parents=True);(p/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.ecru.reader.development','EcruBuildChannel':'development'}))
   with patch.object(s,'protected',return_value=p),patch.object(s,'run') as tool,self.assertRaises(ValueError):s.sign(p,CONFIG)
   tool.assert_not_called()
 def exercise(self,status='Accepted',prior=False,mutate=False,unknown=False):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);p=root/'Ecru.dmg';p.write_bytes(b'signed fixture');folder=root/'.build/notary'/s.digest(p);folder.mkdir(parents=True)
   if prior:s.write_json(folder/'submission.json',{'id':'same-id'})
   if unknown:(folder/'submit-output.json').write_text('interrupted')
   calls=[]
   def tool(*args,**kwargs):
    calls.append(args)
    if args[1:3]==('notarytool','info'):
     if mutate:p.write_bytes(b'changed')
     return json.dumps({'id':'same-id','status':status})
    return ''
   with patch.object(s,'ROOT',root),patch.object(s,'protected',return_value=p),patch.object(s,'verify'),patch.object(s,'run',side_effect=tool),patch.object(s.subprocess,'run') as upload:
    if status!='Accepted' or mutate or unknown:
     with self.assertRaises((ValueError,RuntimeError)):s.notarize(p,CONFIG)
     self.assertFalse(any('staple' in c for c in calls))
    else:
     s.notarize(p,CONFIG);self.assertTrue((folder/'completed.json').exists())
     s.notarize(p,CONFIG) # Completed artifacts validate without another submission.
    upload.assert_not_called() # Interrupted/pending work is never silently re-uploaded.
 def test_resume_without_duplicate_upload(self):self.exercise(prior=True)
 def test_invalid_never_stapled(self):self.exercise(status='Invalid',prior=True)
 def test_mutated_candidate_never_stapled(self):self.exercise(prior=True,mutate=True)
 def test_unknown_upload_preserved(self):self.exercise(unknown=True)
 def test_timeout_preserves_submission(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);p=root/'Ecru.dmg';p.write_bytes(b'x');folder=root/'.build/notary'/s.digest(p);folder.mkdir(parents=True);s.write_json(folder/'submission.json',{'id':'pending'})
   with patch.object(s,'ROOT',root),patch.object(s,'protected',return_value=p),patch.object(s,'verify'),patch.object(s,'run',return_value='{"status":"In Progress"}'),self.assertRaises(TimeoutError):s.notarize(p,CONFIG,timeout=-1)
   self.assertEqual(json.loads((folder/'submission.json').read_text())['id'],'pending');self.assertFalse((folder/'completed.json').exists())

unittest.main()
