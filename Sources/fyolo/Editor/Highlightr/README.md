# Vendored Highlightr

Vendored from [raspu/Highlightr](https://github.com/raspu/Highlightr) 2.3.x
(five classes + `highlight.min.js` + the two xcode theme CSS files, which live
in `../../Resources/` and ship inside `fyolo_fyolo.bundle`).

Why vendored instead of a package dependency: with plain `swift build`, SwiftPM
generates every dependency's `Bundle.module` accessor with exactly two
candidate paths — the `.app` **root** (where codesign forbids bundles) and a
**hardcoded absolute path on the build machine**. A CI-built release therefore
finds neither and `fatalError`s the moment `Highlightr.init` runs (the v0.2.4
open-a-file crash). Vendoring routes resource lookups through
`Bundle.fyoloResources` instead, the same sign-safe shim the brand icons use.

Local changes are listed in the header of `Highlightr.swift`; everything else
is verbatim upstream.

## Upstream license (MIT)

```
Copyright (c) 2016 Illanes, Juan Pablo <jpillaness+highlightr@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

highlight.js itself is BSD-3-Clause, © highlight.js contributors.
