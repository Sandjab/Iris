import Foundation

/// Pure patching logic for MCP server config files. No I/O, no daemon
/// dependencies — input is an `OrderedJSONDocument` + broker listen
/// address + CA cert path; output is the patched document + a summary.
public enum MCPPatcher {
    public struct Summary: Equatable, Sendable {
        public var patched: Int
        public var alreadyCompliant: Int
        public var skippedHttpSse: Int

        public init(patched: Int = 0, alreadyCompliant: Int = 0, skippedHttpSse: Int = 0) {
            self.patched = patched
            self.alreadyCompliant = alreadyCompliant
            self.skippedHttpSse = skippedHttpSse
        }
    }

    // MARK: - Env var keys

    private static let envVarsProxy = ["HTTPS_PROXY", "HTTP_PROXY"]
    private static let envVarsCAPath = [
        "CURL_CA_BUNDLE", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE",
    ]

    // MARK: - Public API

    public static func patch(
        document: OrderedJSONDocument,
        brokerListen: String,
        caPemPath: String
    ) throws -> (OrderedJSONDocument, Summary) {
        var doc = document
        var summary = Summary()

        guard let mcpPath = locateMcpServersPath(in: doc.root) else {
            return (doc, summary)
        }

        let serversNode = getValue(at: mcpPath, in: doc.root)
        guard case .object(let serverEntries) = serversNode else {
            return (doc, summary)
        }

        let proxyURL = "http://\(brokerListen)"

        // Build the sorted list of (varName, value) pairs we need to inject.
        // Sorted alphabetically for determinism.
        let needed: [(String, String)] =
            (envVarsProxy.map { ($0, proxyURL) } + envVarsCAPath.map { ($0, caPemPath) })
            .sorted { $0.0 < $1.0 }

        for (serverName, entry) in serverEntries {
            guard case .object(let entryPairs) = entry else { continue }

            // Determine transport type
            let transportType: String? = {
                guard let idx = entryPairs.firstIndex(where: { $0.0 == "type" }),
                    case .string(let v) = entryPairs[idx].1
                else { return nil }
                return v
            }()

            let isHttpOrSse = transportType == "http" || transportType == "sse"
            let hasExistingEnv = entryPairs.contains(where: { $0.0 == "env" })

            // Skip http/sse entries that have no env block at all
            if isHttpOrSse && !hasExistingEnv {
                summary.skippedHttpSse += 1
                continue
            }

            // Gather existing env pairs
            let existingEnv: [(String, OrderedJSONValue)] = {
                guard let idx = entryPairs.firstIndex(where: { $0.0 == "env" }),
                    case .object(let envPairs) = entryPairs[idx].1
                else { return [] }
                return envPairs
            }()

            // Append only vars not yet present.
            // Proxy vars (HTTPS_PROXY / HTTP_PROXY) are treated as a unit: if
            // either is already set by the user (perhaps to a custom proxy), we
            // skip adding both — we must not inject a conflicting HTTP_PROXY
            // alongside a user-managed HTTPS_PROXY.
            let proxyAlreadySet = existingEnv.contains(where: {
                $0.0 == "HTTPS_PROXY" || $0.0 == "HTTP_PROXY"
            })
            let proxyKeys: Set<String> = ["HTTPS_PROXY", "HTTP_PROXY"]
            var newEnv = existingEnv
            var added = false
            for (key, value) in needed {
                if proxyKeys.contains(key) && proxyAlreadySet { continue }
                if newEnv.contains(where: { $0.0 == key }) { continue }
                newEnv.append((key, .string(value)))
                added = true
            }

            if added {
                let envPath = mcpPath + [serverName, "env"]
                try doc.setValue(.object(newEnv), atPath: envPath)
                summary.patched += 1
            } else {
                summary.alreadyCompliant += 1
            }
        }

        return (doc, summary)
    }

    // MARK: - Helpers

    private static func locateMcpServersPath(in root: OrderedJSONValue) -> [String]? {
        guard case .object(let topLevel) = root else { return nil }

        // Root-level mcpServers
        if topLevel.contains(where: { $0.0 == "mcpServers" }) {
            return ["mcpServers"]
        }

        // One level of nesting — first object key that contains mcpServers
        for (key, value) in topLevel {
            if case .object(let nested) = value,
                nested.contains(where: { $0.0 == "mcpServers" })
            {
                return [key, "mcpServers"]
            }
        }

        return nil
    }

    private static func getValue(at path: [String], in node: OrderedJSONValue) -> OrderedJSONValue {
        var current = node
        for key in path {
            guard case .object(let pairs) = current,
                let idx = pairs.firstIndex(where: { $0.0 == key })
            else { return .null }
            current = pairs[idx].1
        }
        return current
    }
}
