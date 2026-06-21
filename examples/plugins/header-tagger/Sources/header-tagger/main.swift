import Foundation

// P1: placeholder executable so the example installs as a real binary.
// P3 replaces this with the JSON-RPC-over-stdio onRequest handler that adds
// the X-Iris-Plugin header. Kept inert here on purpose.
try? FileHandle.standardError.write(contentsOf: Data("header-tagger: not yet wired (P3)\n".utf8))
