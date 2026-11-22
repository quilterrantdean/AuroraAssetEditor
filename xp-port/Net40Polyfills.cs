//
// Net40Polyfills.cs
// AuroraAssetEditor
//
// Minimal .NET 4.0 polyfills for compiler services that the upstream sources
// use but that only ship with .NET Framework 4.5+.
//
// Roslyn recognises the caller-info attributes by their full name, so the
// compiler fills the optional parameter in even when the attribute type is
// defined in the project being compiled.  Nothing here is used at runtime.
//
// Copied by apply-xp-fixes.ps1 next to the upstream sources at build time.
//

namespace System.Runtime.CompilerServices
{
    using System;

    [AttributeUsage(AttributeTargets.Parameter, Inherited = false)]
    internal sealed class CallerMemberNameAttribute : Attribute
    {
    }

    [AttributeUsage(AttributeTargets.Parameter, Inherited = false)]
    internal sealed class CallerFilePathAttribute : Attribute
    {
    }

    [AttributeUsage(AttributeTargets.Parameter, Inherited = false)]
    internal sealed class CallerLineNumberAttribute : Attribute
    {
    }
}
