#!/usr/bin/env python3
import pathlib
import plistlib
import json

root = pathlib.Path(__file__).resolve().parents[1]
for extension, package, identifier in [('vst3', 'BNDL', 'audio.hasio.loop.vst3'), ('app', 'APPL', 'audio.hasio.loop.standalone'), ('component', 'BNDL', 'audio.hasio.loop.au')]:
    contents = root / 'releases/0.6.0' / f'Hasio Loop.{extension}' / 'Contents'
    data = dict(CFBundleExecutable='HasioLoop', CFBundleIdentifier=identifier,
                CFBundleName='Hasio Loop', CFBundleDisplayName='Hasio Loop',
                CFBundlePackageType=package, CFBundleShortVersionString='0.6.0',
                CFBundleVersion='8', CFBundleInfoDictionaryVersion='6.0',
                LSMinimumSystemVersion='27.0', NSHighResolutionCapable=True)
    if extension == 'component':
        data['AudioComponents'] = [dict(type='aumu', subtype='HsLp', manufacturer='Hasi', name='hasio: Hasio Loop', description='Hasio Loop Sampler', version=0x000600, factoryFunction='HasioLoopAUFactory', sandboxSafe=True, tags=['Synthesizer', 'Sampler'])]
    if extension == 'app':
        data['NSPrincipalClass'] = 'NSApplication'
    (contents / 'Info.plist').write_bytes(plistlib.dumps(data))
    (contents / 'PkgInfo').write_bytes((package + '????').encode())

module = {
    'Name': 'Hasio Loop', 'Version': '0.6.0',
    'Factory Info': {'Vendor': 'hasio', 'URL': '', 'E-Mail': '', 'Flags': {'Unicode': True, 'Classes Discardable': False, 'Component Non Discardable': False}},
    'Classes': [{'CID': '484153494F4C4F4F5056535433000001', 'Category': 'Audio Module Class',
                 'Name': 'Hasio Loop', 'Vendor': 'hasio', 'Version': '0.6.0', 'SDKVersion': 'VST 3.8.0',
                 'Sub Categories': ['Instrument', 'Sampler'], 'Class Flags': 0, 'Cardinality': 2147483647}]
}
(root / 'releases/0.6.0/Hasio Loop.vst3/Contents/Resources/moduleinfo.json').write_text(json.dumps(module, indent=2))
