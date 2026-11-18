"""Swan's stand-in for the two helpers SolidLSP imports from the Serena application.

SolidLSP (MIT) imports `serena.util.file_system.match_path` and
`serena.util.text_utils.MatchedConsecutiveLines`; the Serena application they
live in is GPL-3.0-or-later. This package is Swan's own (MIT), written from how
SolidLSP's MIT code calls them, so SolidLSP runs without any Serena application
code. C#, F# and VB.NET in SolidLSP need more of Serena (`serena.util.dotnet`)
and are not offered through the bridge.
"""
