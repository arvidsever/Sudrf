#!/usr/bin/env python3
# © 2026 Воробьёв Виктор Викторович. See LICENSE.md.
"""Check the real Settings scene with synthetic state, never launch Sudrf."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
args.output_dir.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[3]
source = (root / 'Sources/SudrfApp/SettingsHub.swift').read_text()
shell = source[source.index('struct SettingsHub: View {'):source.index('// MARK: - Обновление')]
# Exercise pane switching without loading real AI credentials or user preferences.
shell = shell.replace('.frame(width: 720, height: 470)', '''.frame(width: 720, height: 470)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("qa-pane"))) {
            selection = Pane(rawValue: $0.object as! String)
        }''')
refresh = source[source.index('private struct RefreshSettingsPane: View {'):source.index('// MARK: - Поиск и Spotlight')]
refresh = refresh.replace('@AppStorage(RefreshSettings.ttlKey)', '@State')
refresh = refresh.replace('RefreshSettings.ttlOptions', '[1, 3, 6, 12, 24]')
panes = refresh + '\n' + '\n'.join(
    f'struct {name}: View {{ var body: some View {{ Form {{ Section("Synthetic section") {{ Text("Synthetic content") }} }}.formStyle(.grouped).navigationTitle("{title}") }} }}'
    for name, title in [('SpotlightSettingsPane', 'Поиск'), ('CaptchaSettingsPane', 'CAPTCHA'),
                        ('AIPrivacyPane', 'AI и приватность'), ('ExperimentalPane', 'Экспериментальные')])
scene = r'''
@MainActor enum Bridge { static var reopen: (() -> Void)? }
struct Launcher: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text("Settings layout check").onAppear {
            Bridge.reopen = { openSettings() }
            openSettings()
        }
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var launcher: NSWindow?
    var samples: [[String: Any]] = []
    let panes = ["refresh", "spotlight", "captcha", "ai", "experimental"]
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Launcher())
        launcher = window
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.capture(0) }
    }
    @MainActor func capture(_ index: Int) {
        guard let window = NSApp.windows.first(where: { $0.title == "Обновление" ||
            $0.title == "Поиск" || $0.title == "CAPTCHA" || $0.title == "AI и приватность" ||
            $0.title == "Экспериментальные" }), let view = window.contentView else {
            fatalError("Native Settings window is missing")
        }
        view.layoutSubtreeIfNeeded()
        samples.append(["title": window.title, "toolbarStyle": window.toolbarStyle.rawValue,
            "topInset": view.safeAreaInsets.top, "height": window.frame.height,
            "contentHeight": window.contentLayoutRect.height])
        if index == 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = rep.representation(using: .png, properties: [:])!
            try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".png"))
        }
        if index < 4 {
            NotificationCenter.default.post(name: Notification.Name("qa-pane"), object: panes[index + 1])
        } else if index == 4 {
            window.close()
            Bridge.reopen?()
        } else {
            let data = try! JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".json"))
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.capture(index + 1) }
    }
}
@main struct ProbeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsHub().buttonBorderShape(.capsule) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sudrf-native-settings-') as temporary:
    for variant in ['before', 'after']:
        layout = shell if variant == 'after' else shell.replace('.background(SettingsWindowToolbar())', '')
        bundle = Path(temporary) / (variant + '.app')
        executable = bundle / 'Contents/MacOS/Probe'
        executable.parent.mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'ru.sudrf.qa.settings366.' + uuid.uuid4().hex,
            'CFBundleExecutable': 'Probe', 'CFBundleName': 'Settings layout check',
            'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication'}))
        swift = Path(temporary) / 'Probe.swift'
        swift.write_text('import AppKit\nimport SwiftUI\n' + layout + panes + scene)
        subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
        output = (args.output_dir / ('native-settings-' + variant)).resolve()
        subprocess.run([str(executable), str(output)], check=True, timeout=20)
        samples = json.loads(output.with_suffix('.json').read_text())
        assert len(samples) == 6, samples
        assert {row['title'] for row in samples} == {'Обновление', 'Поиск', 'CAPTCHA', 'AI и приватность', 'Экспериментальные'}, samples
        assert all(row['toolbarStyle'] == (4 if variant == 'after' else 2) for row in samples), samples
        assert all(row['contentHeight'] == 470 for row in samples), samples
        assert all(row['topInset'] <= 44 if variant == 'after' else row['topInset'] > 44 for row in samples), samples
        print(variant, samples)
