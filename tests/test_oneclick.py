import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'be3600-oneclick.sh'
LIBRARY = SOURCE.read_text().rsplit('main "$@"', 1)[0]

MOCK = r'''#!/usr/bin/env python3
import json,os,re,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
root=pathlib.Path(os.environ['FIXTURE'])
if name=='curl':
 out=a[a.index('-o')+1]
 if a[-1].endswith('/releases/latest'):
  pathlib.Path(out).write_bytes((root/'release.json').read_bytes())
 else:
  pathlib.Path(out).write_bytes((root/'payload').read_bytes())
 with open(root/'requests','a') as f:f.write(a[-1]+'\n')
elif name=='jsonfilter':
 data=json.loads(pathlib.Path(a[a.index('-i')+1]).read_text()) if '-i' in a else json.load(sys.stdin)
 expr=a[a.index('-e')+1]
 try:
  for field,index in re.findall(r'\.([A-Za-z_]+)(?:\[(\d+)\])?',expr):
   data=data[field]
   if index:data=data[int(index)]
 except (KeyError,IndexError):sys.exit(1)
 if data is None:sys.exit(0)
 if isinstance(data,bool):print(str(data).lower())
 elif isinstance(data,(dict,list)):print(json.dumps(data))
 else:print(data)
elif name=='id':print('0')
elif name=='uname':print('Linux' if a==['-s'] else 'aarch64')
elif name=='ubus':
 config=root/'fs/etc/openwrt_release'
 text=config.read_text() if config.exists() else ''
 m=re.search(r"^DISTRIB_DESCRIPTION='([^']*)'",text,re.M)
 print(json.dumps({'model':os.environ.get('MODEL','GL.iNet BE3600'),
                   'release':{'description':m[1] if m else ''}}))
elif name=='uci':
 if a and a[0]=='-q':a=a[1:]
 if a[0] in ('show','get'):sys.exit(1)
 with open(root/'uci-writes','a') as f:f.write(' '.join(a)+'\n')
elif name=='opkg':
 if a[0]=='status':
  current=os.environ.get('CURRENT','')
  if not current:sys.exit(1)
  print('Package: '+a[1]+'\nVersion: '+current+'\nStatus: install ok installed')
 elif a[0]=='compare-versions':
  ver=lambda s:tuple(int(x) for x in re.findall(r'\d+',s))
  current,target=ver(a[1]),ver(a[3])
  result=current>target if a[2]=='>>' else current>=target if a[2] in ('>','>=') else False
  sys.exit(0 if result else 1)
 else:
  with open(root/'opkg-writes','a') as f:f.write(' '.join(a)+'\n')
elif name=='pidof':sys.exit(1)
else:sys.exit(0)
'''


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fs = self.root / 'fs'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ['curl','jsonfilter','id','uname','ubus','uci','opkg','pidof','fw4']:
            p = self.bin / name
            p.write_text(MOCK)
            p.chmod(0o755)
        self.work = self.root / 'downloads'
        self.work.mkdir()
        self.asset = 'luci-app-andeyproxy_9.8.7-1_aarch64_cortex-a53.ipk'
        payload = b'this stands for a newly published asset\n'
        (self.root / 'payload').write_bytes(payload)
        self.release = {'tag_name':'v9.8.7','draft':False,'prerelease':False,'assets':[
            {'name':'luci-app-andeyproxy_9.8.7-1_x86_64.ipk','digest':'sha256:'+'a'*64},
            {'name':self.asset,'digest':'sha256:'+hashlib.sha256(payload).hexdigest()}]}

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, body, **extra):
        (self.root / 'release.json').write_text(json.dumps(self.release))
        library = re.sub(r'(?<![A-Za-z0-9_/])/(etc|usr|rom|www|var|lib|tmp|proc)/',
                         lambda m: str(self.fs)+m.group(0), LIBRARY)
        env = dict(os.environ, FIXTURE=str(self.root), PATH=str(self.bin)+':'+os.environ['PATH'])
        env.update(extra)
        script = library + '\nWORK=' + repr(str(self.work)) + '\n' + body + '\n'
        return subprocess.run(['sh'], input=script, text=True, errors='replace', capture_output=True, env=env)

    def fetch(self):
        return self.run_shell("fetch_release wubin0532/Reverse_Proxy andey 'luci-app-andeyproxy_*_aarch64_cortex-a53.ipk'\nprintf done > \"$WORK/mutated\"")

    def test_picks_new_latest_version_and_correct_architecture(self):
        r = self.fetch()
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        self.assertEqual((self.work/'andey-tag').read_text().strip(), 'v9.8.7')
        self.assertEqual((self.work/'andey-name').read_text().strip(), self.asset)
        self.assertIn('/download/v9.8.7/'+self.asset, (self.root/'requests').read_text())

    def test_checksum_failure_stops_before_later_work(self):
        self.release['assets'][1]['digest'] = 'sha256:'+'b'*64
        r = self.fetch()
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.work/'mutated').exists())

    def test_missing_digest_refuses_installation(self):
        self.release['assets'][1]['digest'] = None
        r = self.fetch()
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.work/self.asset).exists())

    def test_prerelease_is_rejected(self):
        self.release['prerelease'] = True
        r = self.fetch()
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.work/self.asset).exists())

    def test_draft_is_rejected(self):
        self.release['draft'] = True
        self.assertNotEqual(self.fetch().returncode,0)

    def test_ambiguous_architecture_assets_are_rejected(self):
        self.release['assets'].append(dict(self.release['assets'][1]))
        self.assertNotEqual(self.fetch().returncode,0)

    def test_no_architecture_asset_is_rejected(self):
        self.release['assets'] = self.release['assets'][:1]
        self.assertNotEqual(self.fetch().returncode,0)

    def test_newer_installed_version_is_not_downgraded(self):
        r = self.run_shell('no_downgrade luci-app-andeyproxy 1.0.0-1', CURRENT='9.9.9-1')
        self.assertNotEqual(r.returncode,0)
        self.assertIn('拒绝自动降级',r.stderr)
        self.assertFalse((self.root/'opkg-writes').exists())

    def test_same_installed_version_is_allowed(self):
        r = self.run_shell('no_downgrade luci-app-andeyproxy 1.0.0-1', CURRENT='1.0.0-1')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)

    def test_older_installed_version_can_be_upgraded(self):
        r = self.run_shell('no_downgrade luci-app-andeyproxy 2.0.0-1', CURRENT='1.0.0-1')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)

    def test_wrong_router_refused_before_download_or_uninstall(self):
        r = self.run_shell('preflight', MODEL='GL.iNet MT3000')
        self.assertNotEqual(r.returncode,0)
        self.assertIn('机型不匹配',r.stderr)
        self.assertFalse((self.root/'requests').exists())
        self.assertFalse((self.root/'opkg-writes').exists())

    def fixture_file(self, path, text='sentinel'):
        p = self.fs / path.lstrip('/')
        p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(text)
        return p

    def fixture_firewall(self):
        p = self.fixture_file('/etc/init.d/firewall','#!/bin/sh\nexit 0\n')
        p.chmod(0o755)
        self.fixture_file('/proc/mounts','')

    def test_adguard_removal_preserves_custom_tailscale_identity(self):
        self.fixture_firewall()
        identity = self.fixture_file('/etc/tailscale/tailscaled.state','private-test-identity')
        config = self.fixture_file('/etc/config/tailscale','existing-config')
        adg = self.fixture_file('/etc/AdGuardHome/config.yaml')
        r = self.run_shell('TS_VENDOR=0; TS_CUSTOM=1; ADG_VENDOR=1; remove_vendor')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(identity.read_text(),'private-test-identity')
        self.assertEqual(config.read_text(),'existing-config')
        self.assertFalse(adg.exists())

    def test_vendor_tailscale_cleanup_removes_identity_and_hotplug(self):
        self.fixture_firewall()
        identity = self.fixture_file('/etc/tailscale/tailscaled.state')
        hotplug = self.fixture_file('/etc/hotplug.d/net/19-tailscale-net')
        core = self.fixture_file('/usr/sbin/tailscaled')
        unrelated = self.fixture_file('/etc/config/wireless','wifi-must-survive')
        r = self.run_shell('TS_VENDOR=1; TS_CUSTOM=0; ADG_VENDOR=0; remove_vendor')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse(identity.exists())
        self.assertFalse(hotplug.exists())
        self.assertFalse(core.exists())
        self.assertEqual(unrelated.read_text(),'wifi-must-survive')

    def test_actual_version_is_derived_from_rom_only_description_changes(self):
        rom = "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='23.05-SNAPSHOT'\nDISTRIB_REVISION=''\nDISTRIB_ARCH='original-arch'\n"
        self.fixture_file('/rom/etc/openwrt_release',rom)
        old = rom+"DISTRIB_DESCRIPTION='custom branding'\nDISTRIB_TAINTS='keep-this'\n"
        current = self.fixture_file('/etc/openwrt_release',old)
        r = self.run_shell('restore_description')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(current.read_text(),old.replace("DISTRIB_DESCRIPTION='custom branding'","DISTRIB_DESCRIPTION='OpenWrt 23.05-SNAPSHOT'"))

    def test_same_custom_install_skips_native_installer(self):
        manifest = self.fixture_file('/usr/share/tailscale-luci/installed-files','')
        executable = self.fixture_file('/usr/sbin/tailscale','#!/bin/sh\nprintf "1.104.1\\n"\n')
        executable.chmod(0o755)
        manifest.write_text(str(executable)+'\n')
        body = '''
ANDEY_VERSION=2.2.0-r2; TS_VERSION=2.2.0-r2; SCREEN_VERSION=2.2.0-r2
ANDEY_ASSET=unused; TS_ASSET=must-not-run.run; SCREEN_ASSET=unused
ensure_ipk() { :; }
install_plugins
'''
        r = self.run_shell(body, CURRENT='2.2.0-r2')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('保留身份',r.stdout)


if __name__=='__main__':
    unittest.main(verbosity=2)
