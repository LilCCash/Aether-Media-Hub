Copy of flutter_chrome_cast 2.0.0 (MIT, felnanuke2) with one change: the iOS minimum is 16.0 in `ios/Package.swift`,
`ios/flutter_chrome_cast/Package.swift` and the podspec, because the Google Cast SDK it depends on requires iOS 16 and the
published package declared 15.0 (Xcode's «Target Integrity» check then refuses to build).
