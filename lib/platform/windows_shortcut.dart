import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Windows only shows notifications for a desktop app that has a Start Menu shortcut carrying its app id (and the
/// id of the class that receives clicks). This makes that shortcut, "NoteDo", the first time the app runs from a
/// place (and again if the app is moved). It also puts NoteDo in the Start Menu.
class WindowsShortcut {
  WindowsShortcut({required this.appId, required this.activatorGuid, this.run = _runPowerShell});

  final String appId;
  final String activatorGuid;

  /// Runs a PowerShell script (replaced in tests).
  final Future<bool> Function(String script) run;

  /// Makes the shortcut for the program at [target] unless one for exactly that program is already there.
  /// [lnk] is the shortcut file; [marker] remembers which program it was made for. Returns true when it is in place.
  Future<bool> ensure({required String target, required File lnk, required File marker}) async {
    try {
      if (lnk.existsSync() && marker.existsSync() && marker.readAsStringSync().trim() == target) return true;
      await lnk.parent.create(recursive: true);
      final ok = await run(script(target: target, lnk: lnk.path));
      if (ok && lnk.existsSync()) {
        await marker.parent.create(recursive: true);
        await marker.writeAsString(target);
        return true;
      }
    } catch (e) {
      debugPrint('Could not make the NoteDo Start Menu shortcut: $e');
    }
    return false;
  }

  /// The script that writes the shortcut with its app id and activator set.
  String script({required String target, required String lnk}) {
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    return '\$Target = ${q(target)}\n\$Lnk = ${q(lnk)}\n\$Aumid = ${q(appId)}\n\$Clsid = ${q(activatorGuid)}\n\$Icon = ${q(target)}\n$_body';
  }

  static Future<bool> _runPowerShell(String script) async {
    final encoded = base64.encode(const Utf16LeCodec().encode(script));
    final r = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded]);
    if (r.exitCode != 0) debugPrint('Shortcut script failed: ${r.stderr}');
    return r.exitCode == 0;
  }

  /// Where Windows keeps the Start Menu entries of the signed-in person.
  static File defaultLink() => File('${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\NoteDo.lnk');

  static File defaultMarker() => File('${Platform.environment['APPDATA']}\\NoteDo\\shortcut-target.txt');
}

/// UTF-16 little-endian, which is what PowerShell's -EncodedCommand wants.
class Utf16LeCodec {
  const Utf16LeCodec();
  List<int> encode(String s) {
    final out = <int>[];
    for (final unit in s.codeUnits) {
      out
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return out;
  }
}

const _body = r'''
$src = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

[ComImport, Guid("00021401-0000-0000-C000-000000000046")] internal class CShellLink { }

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
internal interface IShellLinkW {
  void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
  void GetIDList(out IntPtr ppidl);
  void SetIDList(IntPtr pidl);
  void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
  void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
  void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
  void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
  void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
  void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
  void GetHotkey(out short pwHotkey);
  void SetHotkey(short wHotkey);
  void GetShowCmd(out int piShowCmd);
  void SetShowCmd(int iShowCmd);
  void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
  void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
  void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
  void Resolve(IntPtr hwnd, uint fFlags);
  void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
internal interface IPropertyStore {
  uint GetCount(out uint cProps);
  uint GetAt(uint iProp, out PropertyKey pkey);
  uint GetValue(ref PropertyKey key, out PropVariant pv);
  uint SetValue(ref PropertyKey key, ref PropVariant pv);
  uint Commit();
}

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010B-0000-0000-C000-000000000046")]
internal interface IPersistFile {
  void GetClassID(out Guid pClassID);
  [PreserveSig] int IsDirty();
  void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
  void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
  void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
  void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct PropertyKey { public Guid fmtid; public uint pid; }

[StructLayout(LayoutKind.Explicit)]
internal struct PropVariant {
  [FieldOffset(0)] public ushort vt;
  [FieldOffset(8)] public IntPtr p;
}

public static class StartMenuShortcut {
  static readonly Guid Fmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

  public static void Create(string target, string lnk, string aumid, string clsid, string icon) {
    var link = (IShellLinkW)new CShellLink();
    link.SetPath(target);
    link.SetWorkingDirectory(System.IO.Path.GetDirectoryName(target));
    link.SetDescription("NoteDo");
    if (!string.IsNullOrEmpty(icon)) link.SetIconLocation(icon, 0);
    var store = (IPropertyStore)link;

    var idKey = new PropertyKey { fmtid = Fmt, pid = 5 };
    var idVal = new PropVariant { vt = 31, p = Marshal.StringToCoTaskMemUni(aumid) };
    store.SetValue(ref idKey, ref idVal);

    var guidBytes = Marshal.AllocCoTaskMem(16);
    Marshal.Copy(new Guid(clsid).ToByteArray(), 0, guidBytes, 16);
    var clsKey = new PropertyKey { fmtid = Fmt, pid = 26 };
    var clsVal = new PropVariant { vt = 72, p = guidBytes };
    store.SetValue(ref clsKey, ref clsVal);

    store.Commit();
    ((IPersistFile)link).Save(lnk, true);
  }
}
"@
Add-Type -TypeDefinition $src
[StartMenuShortcut]::Create($Target, $Lnk, $Aumid, $Clsid, $Icon)
''';
