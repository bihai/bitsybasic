/*
Copyright (c) 2015 Kristopher Johnson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import Foundation

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Return string value currently on clipboard
func getPasteboardContents() -> String? {
    #if os(iOS)

        let pasteboard = UIPasteboard.generalPasteboard()
        return pasteboard.string

    #else

        let pasteboard = NSPasteboard.generalPasteboard()
        return pasteboard.stringForType(NSPasteboardTypeString)

    #endif
}

/// Write a string value to the pasteboard
func copyToPasteboard(text: String) {
    #if os(iOS)

        let pasteboard = UIPasteboard.generalPasteboard()
        pasteboard.string = text

    #else

        let pasteboard = NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: NSPasteboardTypeString)

    #endif
}
