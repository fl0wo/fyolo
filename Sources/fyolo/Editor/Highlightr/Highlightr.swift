//
//  Highlightr.swift
//
//  Vendored from raspu/Highlightr 2.3.x (MIT, © 2016 Illanes, Juan Pablo — see
//  the license text in this directory's README.md). Vendored because SwiftPM's
//  `swift build` generates the dependency's `Bundle.module` accessor with only
//  two candidates — the `.app` ROOT and a hardcoded build-machine path — so a
//  CI-built release fatalErrors the moment the file editor opens (v0.2.4
//  crash). Inside the fyolo target the resources travel in
//  `fyolo_fyolo.bundle` and resolve through `Bundle.fyoloResources`, the
//  same sign-safe shim the brand icons use.
//
//  Local changes, kept minimal:
//   - `Bundle.module` → `Bundle.fyoloResources`
//   - startup theme "pojoaque" → "xcode" (only the two xcode themes ship)
//   - Swift 6: `safeMainSync` boxes its closure to cross onto the main queue —
//     the call is synchronous, so the captures never outlive the caller
//   - two never-read initializations discarded with `_ =` to quiet the build
//
//  The `NSScanner` deprecations in `processHTMLString` are left as upstream
//  wrote them: `scanLocation` is a UTF-16 offset the parser does arithmetic on,
//  and the modern `String.Index` API is not a mechanical swap. Silent
//  mistranslation there corrupts highlighting for no user-visible gain.
//

import Foundation
import JavaScriptCore

#if os(OSX)
    import AppKit
#endif

/// Utility class for generating a highlighted NSAttributedString from a String.
open class Highlightr
{
    /// Returns the current Theme.
    open var theme : Theme!
    {
        didSet
        {
            themeChanged?(theme)
        }
    }
    
    /// This block will be called every time the theme changes.
    open var themeChanged : ((Theme) -> Void)?

    /// Defaults to `false` - when `true`, forces highlighting to finish even if illegal syntax is detected.
    open var ignoreIllegals = false

    private let hljs: JSValue

    private let bundle : Bundle
    private let htmlStart = "<"
    private let spanStart = "span class=\""
    private let spanStartClose = "\">"
    private let spanEnd = "/span>"
    private let htmlEscape = try! NSRegularExpression(pattern: "&#?[a-zA-Z0-9]+?;", options: .caseInsensitive)
    
    /**
     Default init method.

     - parameter highlightPath: The path to `highlight.min.js`. Defaults to `Highlightr.framework/highlight.min.js`

     - returns: Highlightr instance.
     */
    public init?(highlightPath: String? = nil)
    {
        // Each `return nil` says which guard failed. Callers degrade to unhighlighted
        // text rather than trapping, so without this a failure is invisible until
        // someone notices their code is not colored.
        guard let jsContext = JSContext() else
        {
            Log.app.error("highlightr: JSContext() returned nil")
            return nil
        }
        _ = JSValue(newObjectIn: jsContext)

        let bundle = Bundle.fyoloResources
        self.bundle = bundle
        guard let hgPath = highlightPath ?? bundle.path(forResource: "highlight.min", ofType: "js") else
        {
            Log.app.error(
                "highlightr: highlight.min.js missing from \(bundle.bundleURL.path, privacy: .public)")
            return nil
        }

        guard let hgJs = try? String.init(contentsOfFile: hgPath) else
        {
            Log.app.error("highlightr: could not read \(hgPath, privacy: .public)")
            return nil
        }
        _ = jsContext.evaluateScript(hgJs)
        guard let hljs = jsContext.objectForKeyedSubscript("hljs") else
        {
            Log.app.error("highlightr: highlight.min.js defined no hljs global")
            return nil
        }

        self.hljs = hljs

        guard setTheme(to: "xcode") else
        {
            Log.app.error(
                "highlightr: xcode.min.css missing from \(bundle.bundleURL.path, privacy: .public)")
            return nil
        }

    }
    
    /**
     Set the theme to use for highlighting.
     
     - parameter to: Theme name
     
     - returns: true if it was possible to set the given theme, false otherwise
     */
    @discardableResult
    open func setTheme(to name: String) -> Bool
    {
        guard let defTheme = bundle.path(forResource: name+".min", ofType: "css") else
        {
            return false
        }
        guard let themeString = try? String.init(contentsOfFile: defTheme) else { return false }
        theme =  Theme(themeString: themeString)

        
        return true
    }
    
    /**
     Takes a String and returns a NSAttributedString with the given language highlighted.
     
     - parameter code:           Code to highlight.
     - parameter languageName:   Language name or alias. Set to `nil` to use auto detection.
     - parameter fastRender:     Defaults to true - When *true* will use the custom made html parser rather than Apple's solution.
     
     - returns: NSAttributedString with the detected code highlighted.
     */
    open func highlight(_ code: String, as languageName: String? = nil, fastRender: Bool = true) -> NSAttributedString?
    {
        let ret: JSValue?
        if let languageName = languageName
        {
            let result: JSValue = hljs.invokeMethod("highlight", withArguments: [languageName, code, ignoreIllegals])
			 if result.isUndefined {
				// If highlighting failed, use highlightAuto
				ret = hljs.invokeMethod("highlightAuto", withArguments: [code])
			} else {
				ret = result
			}
        }else
        {
            // language auto detection
            ret = hljs.invokeMethod("highlightAuto", withArguments: [code])
        }

        guard let res = ret?.objectForKeyedSubscript("value"), var string = res.toString() else
        {
            return nil
        }
        
        var returnString : NSAttributedString?
        if(fastRender)
        {
            returnString = processHTMLString(string)
        }else
        {
            string = "<style>"+theme.lightTheme+"</style><pre><code class=\"hljs\">"+string+"</code></pre>"
            let opt: [NSAttributedString.DocumentReadingOptionKey : Any] = [
             .documentType: NSAttributedString.DocumentType.html,
             .characterEncoding: String.Encoding.utf8.rawValue
             ]
            
            guard let data = string.data(using: String.Encoding.utf8) else { return nil }
            safeMainSync
            {
                returnString = try? NSMutableAttributedString(data:data, options: opt, documentAttributes:nil)
            }
        }
        
        return returnString
    }
    
    /**
     Returns a list of all the available themes.
     
     - returns: Array of Strings
     */
    open func availableThemes() -> [String]
    {
        let paths = bundle.paths(forResourcesOfType: "css", inDirectory: nil) as [NSString]
        var result = [String]()
        for path in paths {
            result.append(path.lastPathComponent.replacingOccurrences(of: ".min.css", with: ""))
        }
        
        return result
    }
    
    /**
     Returns a list of all supported languages.
     
     - returns: Array of Strings
     */
    open func supportedLanguages() -> [String]
    {
        let res = hljs.invokeMethod("listLanguages", withArguments: [])
        return (res?.toArray() as? [String]) ?? []
    }
    
    /**
     Execute the provided block in the main thread synchronously.
     */
    private struct UncheckedSendableClosure: @unchecked Sendable {
        let run: () -> ()
    }

    private func safeMainSync(_ block: @escaping ()->())
    {
        if Thread.isMainThread
        {
            block()
        }else
        {
            let boxed = UncheckedSendableClosure(run: block)
            DispatchQueue.main.sync { boxed.run() }
        }
    }
    
    private func processHTMLString(_ string: String) -> NSAttributedString?
    {
        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = nil
        var scannedString: NSString?
        let resultString = NSMutableAttributedString(string: "")
        var propStack = ["hljs"]
        
        while !scanner.isAtEnd
        {
            var ended = false
            if scanner.scanUpTo(htmlStart, into: &scannedString)
            {
                if scanner.isAtEnd
                {
                    ended = true
                }
            }
            
            if scannedString != nil && scannedString!.length > 0 {
                let attrScannedString = theme.applyStyleToString(scannedString! as String, styleList: propStack)
                resultString.append(attrScannedString)
                if ended
                {
                    continue
                }
            }
            
            scanner.scanLocation += 1
            
            let string = scanner.string as NSString
            let nextChar = string.substring(with: NSMakeRange(scanner.scanLocation, 1))
            if(nextChar == "s")
            {
                scanner.scanLocation += (spanStart as NSString).length
                scanner.scanUpTo(spanStartClose, into:&scannedString)
                scanner.scanLocation += (spanStartClose as NSString).length
                propStack.append(scannedString! as String)
            }
            else if(nextChar == "/")
            {
                scanner.scanLocation += (spanEnd as NSString).length
                propStack.removeLast()
            }else
            {
                let attrScannedString = theme.applyStyleToString("<", styleList: propStack)
                resultString.append(attrScannedString)
                scanner.scanLocation += 1
            }
            
            scannedString = nil
        }
        
        let results = htmlEscape.matches(in: resultString.string,
                                               options: [.reportCompletion],
                                               range: NSMakeRange(0, resultString.length))
        var locOffset = 0
        for result in results
        {
            let fixedRange = NSMakeRange(result.range.location-locOffset, result.range.length)
            let entity = (resultString.string as NSString).substring(with: fixedRange)
            if let decodedEntity = HTMLUtils.decode(entity)
            {
                resultString.replaceCharacters(in: fixedRange, with: String(decodedEntity))
                locOffset += result.range.length-1;
            }
            

        }

        return resultString
    }
    
}
