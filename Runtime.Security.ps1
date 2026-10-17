# Embedded into the administrator-only task definition; never imported by the task.
function Lock-GuardDataPath([string]$Path) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace AceGuard {
    [StructLayout(LayoutKind.Sequential)] public struct AttributeTag { public uint Attributes; public uint Tag; }
    public static class Pin {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass,
            out AttributeTag info, uint size);
    }
}
'@
    $paths=[Collections.Generic.List[string]]::new()
    $directory=[IO.DirectoryInfo]::new($Path)
    while ($null -ne $directory) { $paths.Add($directory.FullName); $directory=$directory.Parent }
    $ordered=$paths.ToArray(); [array]::Reverse($ordered)
    $handles=[Collections.Generic.List[Microsoft.Win32.SafeHandles.SafeFileHandle]]::new()
    try {
        foreach ($part in $ordered) {
            # Inspect the directory itself, not a junction target; prevent delete/rename sharing.
            $handle=[AceGuard.Pin]::CreateFile($part,0x80,3,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
            if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
            $handles.Add($handle)
            $info=[AceGuard.AttributeTag]::new()
            if (-not [AceGuard.Pin]::GetFileInformationByHandleEx($handle,9,[ref]$info,8)) { throw 'Cannot inspect pinned directory.' }
            if ($info.Attributes -band 0x400) { throw ('Reparse point is not permitted in runtime path: '+$part) }
        }
        $writeRights=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
        foreach ($protected in @($Path,[IO.Directory]::GetParent($Path).FullName)) {
            $acl=Get-Acl -LiteralPath $protected
            $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -notin @('S-1-5-32-544','S-1-5-18')) { throw 'Runtime directory does not have an administrator/SYSTEM owner.' }
            foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-32-544','S-1-5-18') -and ($rule.FileSystemRights -band $writeRights)) {
                    throw 'Runtime data directory permits nonadministrator modifications.'
                }
            }
        }
        # Return the list as a single object; keep every ancestor pinned for this process lifetime.
        return ,$handles
    } catch {
        foreach ($handle in $handles) { $handle.Dispose() }
        throw
    }
}
