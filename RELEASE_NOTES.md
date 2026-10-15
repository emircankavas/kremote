## KRemote v1.7.4

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### New

**Copying a folder out of a session brings its contents too.** The previous
release created the folder but not what was inside it. The server sends a copied
tree as a flat list whose entries are *relative paths*
(`folder\sub\file.txt`), so the separators carry the structure: the bridge now
keeps the path instead of reducing it to a filename, creates any missing parent
directories, writes each file in place, and offers the top-level entries — a
copied folder arrives as one entry with its contents already beneath it.

Names from the server are still untrusted: every path component is cleaned and
`.`, `..`, empty components and absolute prefixes are dropped, so a descriptor
cannot steer a write outside the transfer directory.

All of v1.7.3 back to v1.6.0 is included.










