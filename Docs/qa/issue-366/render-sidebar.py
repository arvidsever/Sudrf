#!/usr/bin/env python3
# © 2026 Воробьёв Виктор Викторович. See LICENSE.md.
"""Render the actual settings shell with synthetic panes; never launch Sudrf."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
args.output_dir.mkdir(parents=True, exist_ok=True)
source = (Path(__file__).resolve().parents[3] / 'Sources/SudrfApp/SettingsHub.swift').read_text()
shell = source[source.index('struct SettingsHub: View {'):source.index('// MARK: - Обновление')]
# Substitute only pane bodies: real AI panes can load credentials or translation.
refresh = source[source.index('private struct RefreshSettingsPane: View {'):source.index('// MARK: - Поиск и Spotlight')]
refresh = refresh.replace('@AppStorage(RefreshSettings.ttlKey)', '@State')
refresh = refresh.replace('RefreshSettings.ttlOptions', '[1, 3, 6, 12, 24]')
panes = refresh + '\n' + '\n'.join(
    f'struct {name}: View {{ var body: some View {{ Form {{ Section("{heading}") {{ Text("Synthetic content") }} }}.formStyle(.grouped).navigationTitle("{title}") }} }}'
    for name, heading, title in [
        ('SpotlightSettingsPane', 'Системный поиск', 'Поиск'),
        ('CaptchaSettingsPane', 'Распознавание', 'CAPTCHA'),
        ('AIPrivacyPane', 'Провайдер', 'AI и приватность'),
        ('ExperimentalPane', 'Перевод через английский', 'Экспериментальные')]
)
with tempfile.TemporaryDirectory(prefix='sudrf-366-') as temporary:
    for variant in ['before', 'after']:
        layout = shell
        if variant == 'before':
            layout = layout.replace('.navigationSplitViewColumnWidth(min: 220, ideal: 220)',
                                    '.navigationSplitViewColumnWidth(184)')
        output = (args.output_dir / f'sidebar-{variant}-720pt.png').resolve()
        # Pass the path as argv, avoiding Swift source interpolation.
        program = 'import AppKit\nimport SwiftUI\n' + layout + panes + '''
let app = NSApplication.shared
let host = NSHostingView(rootView: SettingsHub())
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
    styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host
host.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
    fatalError("Cannot capture settings shell")
}
host.cacheDisplay(in: host.bounds, to: rep)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode capture")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
'''
        path = Path(temporary) / 'Probe.swift'
        binary = Path(temporary) / 'Probe'
        path.write_text(program)
        subprocess.run(['swiftc', str(path), '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(output)], check=True)
        print(output)
