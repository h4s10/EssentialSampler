#!/usr/bin/env python3
import pathlib
import plistlib
import json

root = pathlib.Path(__file__).resolve().parents[1]
for extension, package, identifier in [('vst3', 'BNDL', 'audio.hasio.loop.vst3'), ('app', 'APPL', 'audio.hasio.loop.standalone'), ('component', 'BNDL', 'audio.hasio.loop.au')]:
    contents = root / 'releases/0.6.2' / f'Essential Sampler.{extension}' / 'Contents'
    data = dict(CFBundleExecutable='EssentialSampler', CFBundleIdentifier=identifier,
                CFBundleName='Essential Sampler', CFBundleDisplayName='Essential Sampler',
                CFBundlePackageType=package, CFBundleShortVersionString='0.6.2',
                CFBundleVersion='10', CFBundleInfoDictionaryVersion='6.0',
                LSMinimumSystemVersion='27.0', NSHighResolutionCapable=True)
    if extension == 'component':
        data['AudioComponents'] = [dict(type='aumu', subtype='HsLp', manufacturer='Hasi', name='hasio: Essential Sampler', description='Essential Sampler Sampler', version=0x000602, factoryFunction='HasioLoopAUFactory', sandboxSafe=True, tags=['Synthesizer', 'Sampler'])]
    if extension == 'app':
        data['NSPrincipalClass'] = 'NSApplication'
    (contents / 'Info.plist').write_bytes(plistlib.dumps(data))
    (contents / 'PkgInfo').write_bytes((package + '????').encode())

module = {
    'Name': 'Essential Sampler', 'Version': '0.6.2',
    'Factory Info': {'Vendor': 'hasio', 'URL': '', 'E-Mail': '', 'Flags': {'Unicode': True, 'Classes Discardable': False, 'Component Non Discardable': False}},
    'Classes': [{'CID': '484153494F4C4F4F5056535433000001', 'Category': 'Audio Module Class',
                 'Name': 'Essential Sampler', 'Vendor': 'hasio', 'Version': '0.6.2', 'SDKVersion': 'VST 3.8.0',
                 'Sub Categories': ['Instrument', 'Sampler'], 'Class Flags': 0, 'Cardinality': 2147483647}]
}
(root / 'releases/0.6.2/Essential Sampler.vst3/Contents/Resources/moduleinfo.json').write_text(json.dumps(module, indent=2))
