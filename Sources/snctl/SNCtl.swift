// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog
import SNCloud

/// `snctl` — the protocol, from a terminal, against a real account.
///
/// For whoever develops this package: every command is one call or a few, and
/// `SNCLOUD_WIRE_LOG=headers` (or `bodies`) shows the exchange with every
/// credential masked. The password is asked for at the terminal and never kept;
/// the token, the account and the installation's UUID are kept in
/// `~/.config/snctl/secrets.json` (see `FileSecrets`).
@main
struct SNCtl {
    static let usage = """
    usage: snctl [--private <url>] [--china] [-v] <command> [arguments]

    account
      login <account> [--country N] [--password-file F]
                                     log in; asks for the password (or reads it from a 0600 file),
                                     and for an emailed code if the service wants one
      whoami                         who is logged in, the token's expiry, this installation's device name
      logout                         log out at the service and here
      forget                         forget the session here only

    device API (viewer.supernote.com, as the official app)
      ls [path] [-r]                 list a folder (default /), -r for the whole tree
      stat <path>                    one entry by path
      get <path> [local]             download, checked against the content hash
      put <local> <path>             upload to the whole destination path
      mkdir <path>                   make a folder
      rm <path>                      delete a file (or a folder)
      mv <from> <to>                 move or rename (whole destination path)
      space                          storage in use

    web API (cloud.supernote.com, with XSRF)
      web-ls [folderID]              list a folder by identifier (default the root)
      user                           the account as the web API has it
      folders [folderID]             the folders in a folder, and nothing else
      bin                            what is in the recycle bin
      restore <id>…                  put entries back from the recycle bin
      purge <id>…                    delete entries from the recycle bin for good
      empty-bin                      delete everything in the recycle bin for good
      png <path> [directory]         a note's pages as PNG images, rendered by the service

    changes (socket.io, as the official app)
      watch [--seconds N]            print what the service announces for N seconds (default 60)

    to-do and digests (viewer.supernote.com)
      todo                           every task, by list
      digests                        every digest, with its group and tags

    check [--write]                  run the read-only checks; --write also creates, uploads (small and
                                     multipart), downloads and deletes in /INBOX/snctl-check-<time>,
                                     restores one from the recycle bin and deletes them there for good,
                                     and makes, changes and deletes a to-do list, a task and a digest tag
    check --write --digests          also a digest group and a digest — which the service only marks deleted

    -v  log the package's own lines; SNCLOUD_WIRE_LOG=headers|bodies adds the wire
    """

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var endpoints = SNEndpoints.official
        var verbose = false
        while let first = arguments.first, first.hasPrefix("-") {
            arguments.removeFirst()
            switch first {
            case "--private":
                guard let value = arguments.first, let url = URL(string: value) else { fail("--private needs a URL") }
                arguments.removeFirst()
                endpoints = .privateCloud(url)
            case "--china":
                endpoints = .officialChina
            case "-v", "--verbose":
                verbose = true
            case "-h", "--help":
                print(usage)
                return
            default:
                fail("unknown option \(first)\n\n\(usage)")
            }
        }
        let wire = SNWireLog.level != .off
        if verbose || wire {
            Log.bootstrap(sinks: [StandardErrorSink(minimum: wire ? .debug : .info)])
        }
        guard let command = arguments.first else { fail(usage) }
        arguments.removeFirst()

        do {
            let secrets = try FileSecrets(for: endpoints)
            let session = SNSession(endpoints: endpoints, secrets: secrets)
            let tool = Commands(session: session, arguments: arguments)
            try await tool.run(command)
        } catch {
            fail(describe(error))
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? SNError else { return String(describing: error) }
        switch error {
        case .notLoggedIn: return "not logged in: run `snctl login <account>`"
        case .sessionExpired: return "the session has ended: log in again"
        default: return String(describing: error)
        }
    }

    static func fail(_ message: String) -> Never {
        Terminal.note("snctl: \(message)")
        exit(1)
    }
}
