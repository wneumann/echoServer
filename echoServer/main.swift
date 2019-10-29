//
//  main.swift
//  echoServer
//
//  Created by Will Neumann on 10/29/19.
//  Copyright © 2019 Will Neumann. All rights reserved.
//

// Adapted from echod located at https://gist.github.com/op183/776ef9b5ee0a77cd4dd759ff470e7b11

import Foundation
import Network

// MARK: IO Shit that I'm not sure we really need
// see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
//func enableRawMode(fileHandle: FileHandle) -> termios {
//    var raw = termios()
//    tcgetattr(fileHandle.fileDescriptor, &raw)
//    let original = raw
//    raw.c_lflag &= ~(UInt(ECHO | ICANON))
//    tcsetattr(fileHandle.fileDescriptor, TCSAFLUSH, &raw);
//    return original
//}
//
//func restoreRawMode(fileHandle: FileHandle, originalTerm: termios) {
//    var term = originalTerm
//    tcsetattr(fileHandle.fileDescriptor, TCSAFLUSH, &term);
//}


// MARK: Default params and command line argument parsing
let nwParams: NWParameters?
//let originalTerm = enableRawMode(fileHandle: FileHandle.standardInput)
let type = "_echo._tcp"
var isTCP = true
//var portNumber: UInt16 = 2345
var psk: UnsafeMutablePointer<Int8>? = nil
var timeout = 10.0
var portNumber: UInt16 = 7

// MARK: Parse options
let usage = """
Usage:
echod [-uh?] [-k key] [port]
-u          use udp instead of tcp
-h, -?      help
-k key      TLS/DTLS with TLS_PSK key
-w timeout  cancel raw udp connection silently
            when receiveloop is idle for more
            then timeout seconds (default 10)
port        port number (default 7)
            if 0, port will be assign by the system
"""

func die(_ msg: String) -> Never {
    fputs(msg, stderr)
    exit(1)
}

guard CommandLine.argc > 1 else { die(usage) }

while case let opt = getopt(CommandLine.argc, CommandLine.unsafeArgv, "uh?k:w:"), opt != -1 {
    switch UnicodeScalar(CUnsignedChar(opt)) {
    case "u": isTCP = false
    case "h", "?": die(usage)
    case "k": psk = optarg
    case "w": timeout = Double(String(cString: optarg))!
    default: die("Unknown option: -\(UnicodeScalar(CUnsignedChar(opt)))\n\n\(usage)")
    }
}
let dropOpts = CommandLine.arguments.suffix(from: Int(optind))
if let portNo = dropOpts.first {
    if let iPort = UInt16(portNo) {
            portNumber = iPort
    } else {
        die("invalid port number (\(portNo))\n\n\(usage)")
    }
}
guard !(1...1024 ~= portNumber) || NSUserName() == "root" else {
    die("Port number (\(portNumber)) requires root to use.\n\n\(usage)")
}

// MARK: Set up network parameters
guard let port = NWEndpoint.Port(rawValue: portNumber) else {
    print("Bad port, bro.") //usage)
    exit(0)
}

if let psk = psk {
    // Theoretically this works, I haven't tested it with actual keys
    let dd = DispatchData(bytes: UnsafeRawBufferPointer(start: psk, count: strlen(psk))) as __DispatchData
    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, dd, dd)
    sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    nwParams = isTCP ? NWParameters(tls: tlsOptions) : NWParameters(dtls: tlsOptions)
} else {
    nwParams = isTCP ? NWParameters.tcp : NWParameters.udp
}

let echoQ = DispatchQueue(label: "echoQ", qos: .default)
let dispatchGroup = DispatchGroup()

func receive(connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 0, maximumLength: Int(UInt16.max)) { [unowned connection] (data, _, _, error) in

        guard let data = data, !data.isEmpty else {
            print(connection.endpoint, "nil or empty data received. cancel()")
            connection.cancel()
            return
        }
        print(connection.endpoint, "received", data)
        print(connection.endpoint, "send", data)
        connection.send(content: data, completion: .contentProcessed({ (e) in
            print(connection.endpoint, "sent")
            if let e = e {
                print(connection.endpoint, "send error:", e, ", cancel()")
                connection.cancel()
            } else {
                receive(connection: connection)
            }
        }))
        if let error = error {
            print(connection.endpoint, "receive error:", error, ", cancel()")
            connection.cancel()
        }
    }
}

var listener: NWListener? = nil

var killListener: DispatchWorkItem?
killListener = DispatchWorkItem {
    print("Error: \(type) port \(portNumber) already in use")
//    restoreRawMode(fileHandle: FileHandle.standardInput, originalTerm: originalTerm)
    killListener = nil
    listener = nil
    exit(10)
}

do {
    listener = try NWListener(using: nwParams!, on: port)
    guard let listener = listener else { print("BORK!"); exit(100) }

    listener.newConnectionHandler = { connection in
        connection.stateUpdateHandler = { [unowned connection] state in
            print("\(connection.endpoint)", state)
            switch state {
            case .ready:
                receive(connection: connection)
            case .failed( _):
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: echoQ)
    }

    listener.service = NWListener.Service(name: "echo", type: type, domain: "local")

    listener.stateUpdateHandler = { newState in
        switch newState {
        case .setup:
            print("Setting up, yo!")
        case .waiting(_):
//            print("C'mon, brah… hit me!")
            echoQ.asyncAfter(deadline: .now() + 2.0, execute: killListener!)
        case .ready:
            // Viva BADASS Army!
            print("What up Twitter sluts!\n\(listener.service!) is listening on port \(listener.port!)\nType \"^+D\" to exit")
            killListener?.cancel()
        case .failed(let err):
            print("Oh noes! We died due to dysen^h^h^h^h^h \(err)")
            listener.cancel()
        case .cancelled:
            print("Some dirtbag cancelled us.")
            dispatchGroup.leave()
        @unknown default:
            print("Iunno?")
            listener.cancel()
        }
    }
    listener.start(queue: echoQ)
} catch {
    print("Unexpected error: \(error)")
    exit(1)
}

defer {
    dispatchGroup.enter()
    listener?.cancel()
    dispatchGroup.wait()
    print("Bye, bye ...")
    killListener = nil
    listener = nil
    // It would be also nice to disable raw input when exiting the app.
//    restoreRawMode(fileHandle: FileHandle.standardInput, originalTerm: originalTerm)
}


var char: UInt8 = 0
// This is a blocking idle loop that reads from stdin looking for a local ^D to kill the server process
// As it turns out one need not actively look for the ^D in the input to kill the process
while read(FileHandle.standardInput.fileDescriptor, &char, 1) == 1 {
//    if char == 0x04 { // detect EOF (Ctrl+D)
//        break
//    }
    // don't echo stdin, just ignore the rest
}
