#!/usr/bin/env swift
// PaperWalls feed manifest signer (spec §4).
//
// Usage:
//   export PAPERWALLS_SIGNING_KEY='<private key, base64 raw 32 bytes>'
//   ./sign-manifest.swift path/to/catalog.json
//
// Writes catalog.json.sig (base64 Ed25519 signature over the exact manifest
// bytes) next to the manifest and prints the matching PUBLIC key so you can
// confirm it equals the one baked into the app (RemoteFeed.appCurated) or
// configured via orgCatalogPublicKey.
//
// Publish both files together — the app refuses any manifest whose
// signature is missing or stale:
//   npx wrangler r2 object put <bucket>/catalog.json     --file catalog.json     --cache-control "max-age=300" --remote
//   npx wrangler r2 object put <bucket>/catalog.json.sig --file catalog.json.sig --cache-control "max-age=300" --remote

import CryptoKit
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sign-manifest: " + message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    die("usage: PAPERWALLS_SIGNING_KEY=<base64> sign-manifest.swift <catalog.json>")
}
guard let keyBase64 = ProcessInfo.processInfo.environment["PAPERWALLS_SIGNING_KEY"],
      let keyData = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    die("PAPERWALLS_SIGNING_KEY must hold the base64 raw-32-byte Ed25519 private key")
}

let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let manifestData = try? Data(contentsOf: manifestURL), !manifestData.isEmpty else {
    die("cannot read manifest at \(manifestURL.path)")
}

// Sanity-check the manifest before signing it.
guard let object = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      object["version"] as? Int == 2,
      object["wallpapers"] is [[String: Any]] else {
    die("manifest is not valid catalog.json v2 ({\"version\": 2, \"wallpapers\": [...]})")
}

guard let signature = try? privateKey.signature(for: manifestData) else {
    die("signing failed")
}
let sigURL = manifestURL.appendingPathExtension("sig")
do {
    try signature.base64EncodedString().write(to: sigURL, atomically: true, encoding: .utf8)
} catch {
    die("cannot write \(sigURL.path): \(error.localizedDescription)")
}

print("signed:      \(manifestURL.lastPathComponent) → \(sigURL.lastPathComponent)")
print("public key:  \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
print("(must match the app's baked-in key / orgCatalogPublicKey)")
