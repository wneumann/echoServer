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
    print("Got port: \(portNo)")
    if let iPort = UInt16(portNo) {
            portNumber = iPort
    } else {
        die("invalid port number (\(portNo))\n\n\(usage)")
    }
}
print("portNumber = \(portNumber)")
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
        print("Hadling state: \(newState)!")
        switch newState {
        case .setup:
            print("Setting up, yo!")
        case .waiting(_):
            print("C'mon, brah… hit me!")
            echoQ.asyncAfter(deadline: .now() + 2.0, execute: killListener!)
        case .ready:
            print("What up Twitter sluts!\n\(listener.service!) is listening on port \(listener.port!)\nType \"^+D\" to exit")
            killListener?.cancel()
        case .failed(let err):
            print("Oh noes! We died due to dysen^h^h^h^h^h \(err)")
            listener.cancel()
        case .cancelled:
            print("Some dirtbad cancelled us.")
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
while read(FileHandle.standardInput.fileDescriptor, &char, 1) == 1 {
    if char == 0x04 { // detect EOF (Ctrl+D)
        break
    }
    // don't echo stdin, just ignore the rest
}

//struct CommandOpts {
//    var isUdp = false
//    var psk: UnsafeMutablePointer<Int8>?
//    var timeout = 10.0
//    var port: UInt16
//
//    private let usage = """
//Usage:
//echod [-uh?] [-k key] [port]
//-u          use udp instead of tcp
//-h, -?      help
//-k key      TLS/DTLS with TLS_PSK key
//-w timeout  cancel raw udp connection silently
//            when receiveloop is idle for more
//            then timeout seconds (default 10)
//port        port number (default 7)
//            if 0, port will be assign by the system
//"""
//
//    init?() {
//        guard CommandLine.argc > 1 else { fputs(usage, stderr); return nil }
//
//        while case let opt = getopt(CommandLine.argc, CommandLine.unsafeArgv, "uh?k:w:"), opt != -1 {
//            switch UnicodeScalar(CUnsignedChar(opt)) {
//            case "u": isUdp = true
//            case "h", "?": fputs(usage, stderr); return nil
//            case "k": psk = optarg
//            case "w": timeout = Double(String(cString: optarg))!
//            default: fputs("Unknown option: -\(UnicodeScalar(CUnsignedChar(opt)))\n\n\(usage)", stderr); return nil
//            }
//        }
//        let dropOpts = CommandLine.arguments.suffix(from: Int(optind))
//        if let portNo = dropOpts.first {
//            if let iPort = UInt16(portNo) {
//                    port = iPort
//            } else {
//                fputs("invalid port number (\(portNo))\n\n\(usage)", stderr)
//                return nil
//            }
//        } else {
//            port = 7
//        }
//        guard !(1...1024 ~= port) || NSUserName() == "root" else {
//            fputs("Port number (\(port)) requires root to use.\n\n\(usage)", stderr)
//            return nil
//        }
//    }
//}
//
//guard let opts = CommandOpts() else { exit(1) }
//
//var nwParams = opts.isUdp ? NWParameters.udp : NWParameters.tcp
//if let psk = opts.psk {
//    let dd = DispatchData(bytes: UnsafeRawBufferPointer(start: psk, count: strlen(psk))) as __DispatchData
//    let tlsOptions = NWProtocolTLS.Options()
//    sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, dd, dd)
//    sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
//    nwParams = opts.isUdp ? NWParameters(dtls: tlsOptions) : NWParameters(tls: tlsOptions)
//}
//
//let echoQ = DispatchQueue(label: "echoQ", qos: .default)
//let dispatchGroup = DispatchGroup()
//var waitCancel: DispatchWorkItem?
//

//
//func receive(conn: NWConnection) {
//
//    if opts.isUdp /*&& psk == nil*/ { // udp (conection-less) connection timeout
//        waitCancel = DispatchWorkItem(block: { [weak conn] in
//            guard let c = conn else { return }
//            print(c.endpoint, "timeout, cancel()")
//            c.cancel()
//        })
//        echoQ.asyncAfter(deadline: .now() + opts.timeout, execute: waitCancel!)
//    }
//    print(conn.endpoint, "start receive")
//    conn.receive(minimumIncompleteLength: 0, maximumLength: Int(UInt16.max)) { [unowned conn] (d, c, f, e) in
//
//        waitCancel?.cancel()
//        waitCancel = nil
//        print(conn.endpoint, "received", d)
//        if let d = d, d.isEmpty == false {
//            print(conn.endpoint, "send", d)
//            conn.send(content: d, completion: .contentProcessed({ (e) in
//                print(conn.endpoint, "sent")
//                if let e = e {
//                    print(conn.endpoint, "send error:", e, ", cancel()")
//                    conn.cancel()
//                } else {
//                    receive(conn: conn)
//                }
//            }))
//        } else {
//            print(conn.endpoint, "nil or empty data received:", d, ", cancel()")
//            conn.cancel()
//        }
//        if e != nil {
//            print(conn.endpoint, "receive error:", e, ", cancel()")
//            conn.cancel()
//        }
//    }
//}
//
//let type = opts.isUdp ? "_echo._udp" : "_echo._tcp"
//
//var listner: NWListener?
//let originalTerm = enableRawMode(fileHandle: FileHandle.standardInput)
//var killListener: DispatchWorkItem?
//killListener = DispatchWorkItem {
//    print("Error: \(type) port \(opts.port) already in use")
//    restoreRawMode(fileHandle: FileHandle.standardInput, originalTerm:  originalTerm)
//    killListener = nil
//    listner = nil
//    exit(0)
//}
//
//
//
//
////import Network
////import Foundation
////import Security
////
////// see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
////func enableRawMode(fileHandle: FileHandle) -> termios {
////    var raw = termios()
////    tcgetattr(fileHandle.fileDescriptor, &raw)
////    let original = raw
////    raw.c_lflag &= ~(UInt(ECHO | ICANON))
////    tcsetattr(fileHandle.fileDescriptor, TCSAFLUSH, &raw);
////    return original
////}
////
////func restoreRawMode(fileHandle: FileHandle, originalTerm: termios) {
////    var term = originalTerm
////    tcsetattr(fileHandle.fileDescriptor, TCSAFLUSH, &term);
////}
////
////let stdIn = FileHandle.standardInput
////
////var char: UInt8 = 0
////
////let usage = """
////Usage:
////echod [-uh] [-k key] [port]
////-u          use udp instead of tcp
////-h          help
////-k key      TLS/DTLS with TLS_PSK key
////-w timeout  cancel raw udp connection silently
////            when receiveloop is idle for more
////            then timeout seconds (default 10)
////port        port number (default 7)
////            if 0, port will be assign by the system
////"""
////
////let user = NSUserName()
////
////// defaults
////var nwparam = NWParameters.tcp
////var isTCP = true
////var type = "_echo._tcp"
////var portNumber: UInt16 = 7
////var psk: UnsafeMutablePointer<Int8>?
////var wait = 10.0
////
////var argc = CommandLine.argc
////
////while case let option = getopt(CommandLine.argc, CommandLine.unsafeArgv, "uhk:w:"), option != -1 {
////    let o = UnicodeScalar(CUnsignedChar(option))
////    switch o {
////    case "u":
////        nwparam = NWParameters.udp
////        type = "_echo._udp"
////        isTCP = false
////    case "k":
////        psk = optarg
////    case "h":
////        print(usage)
////        exit(0)
////    case "w":
////        guard let timeout = Double(String(cString: optarg)) else {
////            print(usage)
////            exit(0)
////        }
////        wait = timeout
////    case "?":
////        print(usage)
////        exit(0)
////    default:
////        print(usage)
////        exit(0)
////    }
////}
////argc -= optind
////if argc > 1 {
////    print(usage)
////    exit(0)
////}
////if argc == 1, let pn = UInt16(CommandLine.arguments[Int(optind)]) {
////    portNumber = pn
////}
////guard let port = NWEndpoint.Port(rawValue: portNumber) else {
////    print(usage)
////    exit(0)
////}
////guard portNumber == 0 || portNumber > 1024 || user == "root" else {
////    print(usage)
////    print("Port:", portNumber, "requires special permission.")
////    exit(0)
////}
////
////
////if let psk = psk {
////    let dd = DispatchData(bytes: UnsafeRawBufferPointer(start: psk, count: strlen(psk)))
////    let tlsOptions = NWProtocolTLS.Options()
////    sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, dd as __DispatchData, dd as __DispatchData)
////    sec_protocol_options_add_tls_ciphersuite(tlsOptions.securityProtocolOptions, SSLCipherSuite(TLS_PSK_WITH_AES_128_GCM_SHA256))
////    if isTCP {
////        nwparam = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
////    } else {
////        nwparam = NWParameters(dtls: tlsOptions, udp: NWProtocolUDP.Options())
////    }
////}
////
////let sq = DispatchQueue(label: "sq", qos: .default)
////let dg = DispatchGroup()
////
////var w: DispatchWorkItem?
////
////func receive(conn: NWConnection) {
////
////    if isTCP == false /*&& psk == nil*/ { // udp (conection-less) connection timeout
////        w = DispatchWorkItem(block: { [weak conn] in
////            guard let c = conn else { return }
////            print(c.endpoint, "timeout, cancel()")
////            c.cancel()
////        })
////        sq.asyncAfter(deadline: .now() + wait, execute: w!)
////    }
////    print(conn.endpoint, "start receive")
////    conn.receive(minimumIncompleteLength: 0, maximumLength: Int(UInt16.max)) { [unowned conn] (d, c, f, e) in
////
////        w?.cancel()
////        w = nil
////        print(conn.endpoint, "received", d)
////        if let d = d, d.isEmpty == false {
////            print(conn.endpoint, "send", d)
////            conn.send(content: d, completion: .contentProcessed({ (e) in
////                print(conn.endpoint, "sent")
////                if let e = e {
////                    print(conn.endpoint, "send error:", e, ", cancel()")
////                    conn.cancel()
////                } else {
////                    receive(conn: conn)
////                }
////            }))
////        } else {
////            print(conn.endpoint, "nil or empty data received:", d, ", cancel()")
////            conn.cancel()
////        }
////        if e != nil {
////            print(conn.endpoint, "receive error:", e, ", cancel()")
////            conn.cancel()
////        }
////    }
////}
////
////var listener: NWListener? = nil
////let originalTerm = enableRawMode(fileHandle: stdIn)
////
////var wi: DispatchWorkItem?
////wi = DispatchWorkItem {
////    print("Error: \(type) port \(portNumber) already in use")
////    restoreRawMode(fileHandle: stdIn, originalTerm: originalTerm)
////    wi = nil
////    listener = nil
////    exit(0)
////}
////
////do {
////    listener = try NWListener(using: nwparam, on: port)
////    if let l = listener {
////        l.newConnectionHandler = { connection in
////            connection.stateUpdateHandler = { [unowned connection] state in
////                print("\(connection.endpoint)", state)
////                switch state {
////                case .ready:
////                    receive(conn: connection)
////                case .failed( _):
////                    connection.cancel()
////                default:
////                    break
////                }
////            }
////            connection.start(queue: sq)
////        }
////        l.service = NWListener.Service(name: "echo", type: type, domain: "local")
////        l.stateUpdateHandler = { state in
////            switch state {
////            case .ready:
////                let info =
////                """
////                Hello world!
////                \(l.service!) is listening on port: \(l.port!)
////                Press CTRL+D to exit
////
////                """
////                print(info)
////                wi?.cancel()
////            case .cancelled:
////                print("cancelled")
////                dg.leave()
////            case .failed(let e):
////                print("failed", e)
////                l.cancel()
////            case .waiting( _):
////                print("waiting ...")
////                sq.asyncAfter(deadline: .now() + 2.0, execute: wi!)
////            case .setup:
////                print("seting up ...")
////            }
////        }
////        l.start(queue: sq)
////    }
////} catch let e {
////    print(e)
////    exit(0)
////}
////
////defer {
////    dg.enter()
////    listener?.cancel()
////    print()
////    print("By, by ...")
////    dg.wait()
////    wi = nil
////    listener = nil
////    // It would be also nice to disable raw input when exiting the app.
////    restoreRawMode(fileHandle: stdIn, originalTerm: originalTerm)
////}
////
////while read(stdIn.fileDescriptor, &char, 1) == 1 {
////    if char == 0x04 { // detect EOF (Ctrl+D)
////        break
////    }
////    // don't echo stdin, just ignore the rest
////}
