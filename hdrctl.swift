/*
 * Experimental HDR toggle attempt via private symbols, with safe fallback.
 *
 * Build:
 *
 *      swiftc hdrctl-private.swift -o hdrctl-private
 *
 * Execution:
 *
 *      ./hdrctl-private on --display "LG TV SSCR2"
 *      ./hdrctl-private off --display "LG TV SSCR2"
 *      ./hdrctl-private toggle --display "LG TV SSCR2"
 *
 * Notes:
 *  - This binary logs private symbol/service availability.
 *  - It *attempts* a private HDR toggle in a subprocess to avoid crashing the parent.
 *  - If the private attempt fails (missing symbol, non-zero return, or child crash),
 *    it falls back to the public CoreGraphics mode switch (10-bit vs 8-bit) used by hdrctl.swift.
 */
import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics
import Darwin
import MachO

struct IOKitDisplayInfo
{
    let vendorID: UInt32
    let productID: UInt32
    let serial: UInt32
    let names: [String]
}

enum Mode: String
{
    case on, off, toggle
}

enum Command: String
{
    case on, off, toggle, list
}

struct Options
{
    var command: Command
    var displayName: String?
    var displayID: CGDirectDisplayID?
    var serial: UInt32?
}

func die(_ message: String, code: Int32 = 1) -> Never
{
    fputs(message + "\n", stderr)
    exit(code)
}

func usage() -> Never
{
    die(
      """
    Usage:
      hdrctl-private list
      hdrctl-private --list

      hdrctl-private on (--display "<name>" | --display-id <id> | -id <id> | --serial <serial>)
      hdrctl-private off (--display "<name>" | --display-id <id> | -id <id> | --serial <serial>)
      hdrctl-private toggle (--display "<name>" | --display-id <id> | -id <id> | --serial <serial>)

    Notes:
      - Selection precedence if you pass multiple: --display-id, then --serial, then --display.
      - This tool tries a private HDR toggle first and logs what it finds.
      - On failure it falls back to the public 10-bit/8-bit mode switch.
    """,
      code: 2
    )
}

func parseUInt32(_ s: String) -> UInt32?
{
    // Accept decimal or 0x... hex
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("0x")
    {
        return UInt32(trimmed.dropFirst(2), radix: 16)
    }
    return UInt32(trimmed, radix: 10)
}

func parseArgs() -> Options
{
    var args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first else { usage() }

    // Allow `--list` as a "switch" alias for `list`.
    if first == "--list"
    {
        args.removeFirst()
        return Options(command: .list, displayName: nil, displayID: nil, serial: nil)
    }

    guard let command = Command(rawValue: first) else { usage() }
    args.removeFirst()

    // Want to default to "LG OLED SSC 5" - if cables/ports change, ID may change
    let defaultDisplayId: UInt32 = 5

    var displayName: String?
    var display_id: UInt32?
    var serial: UInt32?
    var i = 0
    while i < args.count
    {
        switch args[i]
        {
        case "--display":
            i += 1
            guard i < args.count else
              { usage() }
            displayName = args[i]
        case "--display-id", "-id":
            i += 1
            guard i < args.count else { usage() }
            guard let id = parseUInt32(args[i]) else
            {
                die("Invalid --display-id/-id: \(args[i])", code: 2)
            }
            display_id = id
        case "--serial":
            i += 1
            guard i < args.count else { usage() }
            guard let v = parseUInt32(args[i]) else
            {
                die("Invalid --serial: \(args[i])", code: 2)
            }
            serial = v
        case "--list":
            // Allow `hdrctl-private on --list` (but `list` ignores other options anyway).
            return Options(command: .list, displayName: nil, displayID: nil, serial: nil)
        case "--help", "-h":
            usage()
        default:
            die("Unknown arg: \(args[i])", code: 2)
        }
        i += 1
    }
    let displayID: CGDirectDisplayID = CGDirectDisplayID(display_id ?? defaultDisplayId)

    return Options(command: command, displayName: displayName, displayID: displayID, serial: serial)
}

func getOnlineDisplays() -> [CGDirectDisplayID]
{
    var onlineCount: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &onlineCount) == .success else { return [] }

    var displays = Array<CGDirectDisplayID>(repeating: 0, count: Int(onlineCount))
    guard CGGetOnlineDisplayList(onlineCount, &displays, &onlineCount) == .success else { return [] }
    return displays
}

func readIOKitDisplays() -> [IOKitDisplayInfo]
{
    var iterator: io_iterator_t = 0
    let match = IOServiceMatching("IODisplayConnect")
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
    guard kr == KERN_SUCCESS, iterator != 0 else { return [] }
    defer { IOObjectRelease(iterator) }

    var results: [IOKitDisplayInfo] = []

    while true
    {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }

        let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
            .takeRetainedValue() as NSDictionary

        let vendorID = (info[kDisplayVendorID] as? NSNumber)?.uint32Value ?? 0
        let productID = (info[kDisplayProductID] as? NSNumber)?.uint32Value ?? 0
        let serial = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0

        var names: [String] = []
        if let nameDict = info[kDisplayProductName] as? NSDictionary
        {
            for (_, v) in nameDict
            {
                if let s = v as? String { names.append(s) }
            }
        }

        results.append(.init(vendorID: vendorID, productID: productID, serial: serial, names: names))
    }

    return results
}

func findDisplayID(named target: String) -> CGDirectDisplayID?
{
    let displays = getOnlineDisplays()
    if displays.isEmpty { return nil }

    let iokit = readIOKitDisplays()

    func matches(_ io: IOKitDisplayInfo, _ id: CGDirectDisplayID) -> Bool
    {
        let v = CGDisplayVendorNumber(id)
        let m = CGDisplayModelNumber(id)
        let s = CGDisplaySerialNumber(id)

        guard io.vendorID == v, io.productID == m else { return false }
        // Serial is often 0 on one side; treat 0 as “unknown”
        if io.serial == 0 || s == 0 { return true }
        return io.serial == s
    }

    for id in displays
    {
        // Find the IOKit entry corresponding to this CG display ID
        guard let io = iokit.first(where: { matches($0, id) }) else { continue }
        if io.names.contains(target) { return id }
    }
    return nil
}

func resolveDisplayID(options: Options) -> (id: CGDirectDisplayID, label: String)
{
    let displays = getOnlineDisplays()
    if displays.isEmpty
    {
        die("No online displays found.")
    }

    let iokit = readIOKitDisplays()

    if let wantedID = options.displayID
    {
        if displays.contains(wantedID)
        {
            return (wantedID, "DisplayID \(wantedID)")
        }
        die("DisplayID not online: \(wantedID)")
    }

    if let wantedSerial = options.serial
    {
        var matches: [CGDirectDisplayID] = []
        for id in displays
        {
            let cgSerial = UInt32(CGDisplaySerialNumber(id))
            let ioSerial = iokitInfo(for: id, iokitDisplays: iokit)?.serial ?? 0
            if (cgSerial != 0 && cgSerial == wantedSerial) || (ioSerial != 0 && ioSerial == wantedSerial)
            {
                matches.append(id)
            }
        }

        if matches.count == 1
        {
            return (matches[0], "Serial \(wantedSerial)")
        }
        if matches.isEmpty
        {
            die("No online display matched serial \(wantedSerial). Run `hdrctl-private list` to see serials.")
        }

        let ids = matches.map { String($0) }.joined(separator: ", ")
        die("Serial \(wantedSerial) matched multiple displays (DisplayID: \(ids)). Use --display-id instead.")
    }

    if let name = options.displayName
    {
        if let id = findDisplayID(named: name)
        {
            return (id, "Display '\(name)'")
        }
        die("Display not found by name: \(name). Run `hdrctl-private list` to see names.")
    }

    die("Missing display selector. Use --display, --display-id, or --serial. (Run `hdrctl-private list`.)", code: 2)
}

func iokitInfo(for displayID: CGDirectDisplayID, iokitDisplays: [IOKitDisplayInfo]) -> IOKitDisplayInfo?
{
    let v = CGDisplayVendorNumber(displayID)
    let m = CGDisplayModelNumber(displayID)
    let s = CGDisplaySerialNumber(displayID)

    if s != 0,
       let exact = iokitDisplays.first(where: { $0.vendorID == v && $0.productID == m && $0.serial != 0 && $0.serial == s })
    {
        return exact
    }

    return iokitDisplays.first(where: { $0.vendorID == v && $0.productID == m })
}

func listDisplays()
{
    let displays = getOnlineDisplays()
    if displays.isEmpty { die("No online displays found.") }

    let iokit = readIOKitDisplays()

    for id in displays
    {
        let v = CGDisplayVendorNumber(id)
        let m = CGDisplayModelNumber(id)
        let s = CGDisplaySerialNumber(id)

        let isMain = (CGDisplayIsMain(id) != 0)
        let isBuiltin = (CGDisplayIsBuiltin(id) != 0)

        let io = iokitInfo(for: id, iokitDisplays: iokit)
        let names = io?.names ?? []
        let ioSerial = io?.serial ?? 0

        let current = CGDisplayCopyDisplayMode(id)
        let curDesc: String
        if let current
        {
            let rr = refreshRateHz(of: current)
            let enc = pixelEncoding(of: current)
            let rrStr = rr > 0 ? String(format: "%.2f", rr) : "?"
            curDesc = "\(current.width)x\(current.height) @ \(rrStr)Hz, pixelEncoding=\(enc)"
        }
        else
        {
            curDesc = "<unknown>"
        }

        let allModes = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? []
        let supports10Bit = allModes.contains(where: { pixelComponentBits(of: $0) == 10 })

        print("DisplayID: \(id)  \(isMain ? "[main]" : "")\(isBuiltin ? "[builtin]" : "")")
        print("  Product names: \(names.isEmpty ? "<unknown>" : names.joined(separator: " | "))")
        print("  Vendor/Model/Serial(CG): \(v)/\(m)/\(s)")
        print("  Serial(IOKit): \(ioSerial)")
        print("  Current mode: \(curDesc)")
        print("  10-bit mode available: \(supports10Bit ? "yes" : "no")")
        print("")
    }
}

private typealias CGDisplayModeCopyPixelEncodingFn = @convention(c) (CGDisplayMode?) -> Unmanaged<CFString>?

private let _cgDisplayModeCopyPixelEncoding: CGDisplayModeCopyPixelEncodingFn? = {
    // Swift marks `CGDisplayModeCopyPixelEncoding` as unavailable/obsoleted, but on newer
    // macOS it can still be present and useful for getting IOKit-style encoding strings.
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    guard let p = dlsym(rtldDefault, "CGDisplayModeCopyPixelEncoding") else { return nil }
    return unsafeBitCast(p, to: CGDisplayModeCopyPixelEncodingFn.self)
}()

func pixelEncoding(of mode: CGDisplayMode) -> String
{
    // On newer macOS versions, `mode.pixelEncoding` may return a "layout string"
    // (e.g. "--------RRRR...") rather than the IOKit-style constants we key off of.
    // Prefer the CoreGraphics C entrypoint (via shim) when it returns something useful.
    if let fn = _cgDisplayModeCopyPixelEncoding, let u = fn(mode)
    {
        return u.takeRetainedValue() as String
    }
    return (mode.pixelEncoding as String?) ?? ""
}

func pixelComponentBits(from encoding: String) -> Int?
{
    // Older macOS versions returned IOKit-style constants.
    switch encoding
    {
    case "IO30BitDirectPixels": return 10
    case "IO32BitDirectPixels": return 8
    default: break
    }

    // Newer macOS versions may return a layout string like:
    //   "--------RRRRRRRRGGGGGGGGBBBBBBBB" (8bpc RGBX)
    //   "--RRRRRRRRRRGGGGGGGGGGBBBBBBBBBB" (10bpc RGB, expected style)
    let r = encoding.reduce(0) { $0 + ($1 == "R" ? 1 : 0) }
    let g = encoding.reduce(0) { $0 + ($1 == "G" ? 1 : 0) }
    let b = encoding.reduce(0) { $0 + ($1 == "B" ? 1 : 0) }
    if r > 0, r == g, g == b
    {
        return r
    }
    return nil
}

func pixelComponentBits(of mode: CGDisplayMode) -> Int?
{
    return pixelComponentBits(from: pixelEncoding(of: mode))
}

func refreshRateHz(of mode: CGDisplayMode) -> Double
{
    let rr = mode.refreshRate
    return rr > 0 ? rr : 0
}

func pickMode(for displayID: CGDirectDisplayID, want10Bit: Bool) -> CGDisplayMode?
{
    guard let current = CGDisplayCopyDisplayMode(displayID) else { return nil }
    let curW = current.width
    let curH = current.height
    let curRR = refreshRateHz(of: current)

    let all = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]) ?? []
    let targetBits = want10Bit ? 10 : 8

    // Prefer exact match: same resolution + refresh + desired pixel encoding.
    let exact = all.first(
      where: { m in
               m.width == curW &&
                 m.height == curH &&
                 (curRR == 0 || abs(refreshRateHz(of: m) - curRR) < 0.01) &&
                 pixelComponentBits(of: m) == targetBits
           }
    )
    if let exact { return exact }

    // Fallback: same resolution + desired pixel encoding (refresh may change).
    let sameRes = all.first(
      where: { m in
               m.width == curW &&
                 m.height == curH &&
                 pixelComponentBits(of: m) == targetBits
           }
    )
    return sameRes
}

// MARK: - Private HDR probing / attempt

func logStderr(_ s: String)
{
    fputs(s + "\n", stderr)
}

struct PrivateProbe
{
    struct ImageResult
    {
        let label: String
        let attempt: String
        let loaded: Bool
    }

    struct SymbolResult
    {
        let imageLabel: String
        let symbol: String
        let found: Bool
    }

    struct ExportScanResult
    {
        let imageName: String
        let matchCount: Int
        let matchesSample: [String]
        let error: String?
    }

    let images: [ImageResult]
    let symbols: [SymbolResult]
    let exportScans: [ExportScanResult]
}

func dlopenIfPossible(_ pathOrName: String) -> UnsafeMutableRawPointer?
{
    // RTLD_NOLOAD isn't documented for Swift usage; keep it simple.
    return dlopen(pathOrName, RTLD_LAZY)
}

func dlsymMaybe(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> UnsafeMutableRawPointer?
{
    if let handle
    {
        return dlsym(handle, symbol)
    }
    // Fallback: search all loaded images.
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) // RTLD_DEFAULT
}

// MARK: - Export trie scanning (in-memory Mach-O)

private struct LinkeditInfo
{
    var vmaddr: UInt64 = 0
    var fileoff: UInt64 = 0
}

private struct ExportTrieInfo
{
    var fileoff: UInt64 = 0
    var size: UInt64 = 0
}

private func readULEB128(_ base: UnsafeRawPointer, _ offset: inout Int, _ end: Int) -> UInt64?
{
    var result: UInt64 = 0
    var bit: UInt64 = 0
    while offset < end
    {
        let byte = base.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        result |= UInt64(byte & 0x7f) << bit
        if (byte & 0x80) == 0
        {
            return result
        }
        bit += 7
        if bit > 63 { return nil }
    }
    return nil
}

private func readCString(_ base: UnsafeRawPointer, _ offset: inout Int, _ end: Int) -> String?
{
    if offset >= end { return nil }
    var bytes: [UInt8] = []
    while offset < end
    {
        let b = base.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        if b == 0 { break }
        bytes.append(b)
        if bytes.count > 4096 { return nil }
    }
    return String(bytes: bytes, encoding: .utf8)
}

private func exportTriePointer(for imageIndex: UInt32) -> (ptr: UnsafeRawPointer, size: Int)?
{
    guard let headerRaw = _dyld_get_image_header(imageIndex) else { return nil }
    let slide = _dyld_get_image_vmaddr_slide(imageIndex)

    // We only handle 64-bit Mach-O.
    let header = UnsafeRawPointer(headerRaw).assumingMemoryBound(to: mach_header_64.self)
    guard header.pointee.magic == MH_MAGIC_64 else { return nil }

    var linkedit = LinkeditInfo()
    var trie = ExportTrieInfo()

    var cmdPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds
    {
        let lc = cmdPtr.assumingMemoryBound(to: load_command.self).pointee
        switch lc.cmd
        {
        case UInt32(LC_SEGMENT_64):
            let seg = cmdPtr.assumingMemoryBound(to: segment_command_64.self).pointee
            let name = withUnsafeBytes(of: seg.segname) { raw -> String in
                let b = raw.prefix { $0 != 0 }
                return String(bytes: b, encoding: .utf8) ?? ""
            }
            if name == "__LINKEDIT"
            {
                linkedit.vmaddr = seg.vmaddr
                linkedit.fileoff = seg.fileoff
            }
        case UInt32(LC_DYLD_INFO_ONLY):
            let di = cmdPtr.assumingMemoryBound(to: dyld_info_command.self).pointee
            if di.export_off != 0 && di.export_size != 0
            {
                trie.fileoff = UInt64(di.export_off)
                trie.size = UInt64(di.export_size)
            }
        case UInt32(LC_DYLD_EXPORTS_TRIE):
            let le = cmdPtr.assumingMemoryBound(to: linkedit_data_command.self).pointee
            if le.dataoff != 0 && le.datasize != 0
            {
                trie.fileoff = UInt64(le.dataoff)
                trie.size = UInt64(le.datasize)
            }
        default:
            break
        }

        cmdPtr = cmdPtr.advanced(by: Int(lc.cmdsize))
    }

    guard linkedit.vmaddr != 0, trie.fileoff != 0, trie.size != 0 else { return nil }

    // Convert file offset in __LINKEDIT to in-memory address.
    let linkeditRuntime = UInt64(bitPattern: Int64(linkedit.vmaddr) + Int64(slide))
    let trieRuntime = linkeditRuntime + trie.fileoff - linkedit.fileoff
    guard let ptr = UnsafeRawPointer(bitPattern: UInt(trieRuntime)) else { return nil }
    return (ptr, Int(trie.size))
}

private func scanExportTrie(
    base: UnsafeRawPointer,
    size: Int,
    symbolNamePredicate: (String) -> Bool,
    maxMatches: Int
) -> [String]
{
    var matches: [String] = []
    var visited = Set<Int>()

    func walkNode(offset: Int, prefix: String, depth: Int)
    {
        if matches.count >= maxMatches { return }
        if depth > 64 { return }
        if offset < 0 || offset >= size { return }
        if visited.contains(offset) { return }
        visited.insert(offset)

        var cursor = offset
        guard let terminalSizeU = readULEB128(base, &cursor, size) else { return }
        let terminalSize = Int(terminalSizeU)
        if terminalSize < 0 || cursor + terminalSize > size { return }

        if terminalSize != 0
        {
            // This node exports the symbol named `prefix`.
            if !prefix.isEmpty, symbolNamePredicate(prefix)
            {
                matches.append(prefix)
                if matches.count >= maxMatches { return }
            }
        }

        cursor += terminalSize
        if cursor >= size { return }

        let childCount = Int(base.load(fromByteOffset: cursor, as: UInt8.self))
        cursor += 1
        if childCount <= 0 { return }

        for _ in 0..<childCount
        {
            if matches.count >= maxMatches { return }
            guard let edge = readCString(base, &cursor, size) else { return }
            guard let childOffU = readULEB128(base, &cursor, size) else { return }
            let childOff = Int(childOffU)
            walkNode(offset: childOff, prefix: prefix + edge, depth: depth + 1)
        }
    }

    walkNode(offset: 0, prefix: "", depth: 0)
    return matches
}

private func scanLoadedImagesForHDRishExports() -> [PrivateProbe.ExportScanResult]
{
    let wanted = ["CoreDisplay", "DisplayServices", "SkyLight"]

    func isRelevantImageName(_ name: String) -> Bool
    {
        return wanted.contains(where: { name.localizedCaseInsensitiveContains($0) })
    }

    func isHDRishSymbol(_ sym: String) -> Bool
    {
        // Avoid false positives like "PermittEDResize...".
        // Use the casing convention typically used in these symbols.
        let tokens = ["HDR", "EDR", "XDR", "DynamicRange", "ReferenceMode"]
        return tokens.contains(where: { sym.contains($0) })
    }

    var results: [PrivateProbe.ExportScanResult] = []
    let count = _dyld_image_count()
    for i in 0..<count
    {
        guard let cName = _dyld_get_image_name(i) else { continue }
        let name = String(cString: cName)
        guard isRelevantImageName(name) else { continue }

        guard let (ptr, size) = exportTriePointer(for: i) else
        {
            results.append(.init(imageName: name, matchCount: 0, matchesSample: [], error: "no export trie"))
            continue
        }

        let matches = scanExportTrie(base: ptr, size: size, symbolNamePredicate: isHDRishSymbol, maxMatches: 80)
        results.append(.init(imageName: name, matchCount: matches.count, matchesSample: Array(matches.prefix(40)), error: nil))
    }

    // Stable ordering for logs.
    return results.sorted(by: { $0.imageName < $1.imageName })
}

func probePrivateAvailability() -> PrivateProbe
{
    // Try both path-based and name-based loads; on some systems the on-disk framework binary
    // may not be directly readable but dyld may still resolve by install name.
    let imageAttempts: [(label: String, attempt: String)] = [
        ("CoreDisplay", "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"),
        ("CoreDisplay", "CoreDisplay"),
        ("DisplayServices", "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"),
        ("DisplayServices", "DisplayServices"),
        ("SkyLight", "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"),
        ("SkyLight", "SkyLight"),
    ]

    var handlesByLabel: [String: UnsafeMutableRawPointer] = [:]
    var images: [PrivateProbe.ImageResult] = []
    for (label, attempt) in imageAttempts
    {
        let h = dlopenIfPossible(attempt)
        let loaded = (h != nil)
        images.append(.init(label: label, attempt: attempt, loaded: loaded))
        if loaded, handlesByLabel[label] == nil, let h
        {
            handlesByLabel[label] = h
        }
    }

    let candidateSymbols: [(imageLabel: String, symbol: String)] = [
        ("CoreDisplay", "CoreDisplay_Display_SetHDRMode"),
        ("CoreDisplay", "CoreDisplay_Display_SetHDRMode_Server"),
        ("DisplayServices", "DisplayServicesSetHDRMode"),
        ("DisplayServices", "DisplayServicesSetHDRMode_"),
        ("SkyLight", "SLSDisplaySetHDRMode"),
        ("SkyLight", "SLSDisplaySetHDRMode_"),
    ]

    var symbols: [PrivateProbe.SymbolResult] = []
    for (imageLabel, symbol) in candidateSymbols
    {
        let ptr = dlsymMaybe(handlesByLabel[imageLabel], symbol)
        symbols.append(.init(imageLabel: imageLabel, symbol: symbol, found: ptr != nil))
    }

    let exportScans = scanLoadedImagesForHDRishExports()
    return PrivateProbe(images: images, symbols: symbols, exportScans: exportScans)
}

typealias SetHDRModeFnBool = @convention(c) (UInt32, Bool) -> Int32
typealias SetHDRModeFnI32 = @convention(c) (UInt32, Int32) -> Int32
typealias SetHDRModeFnU32 = @convention(c) (UInt32, UInt32) -> Int32

typealias SetHDRModeVoidBool = @convention(c) (UInt32, Bool) -> Void
typealias SetHDRModeVoidI32 = @convention(c) (UInt32, Int32) -> Void

typealias GetHDRModeI32 = @convention(c) (UInt32) -> Int32

func getHDRModeEnabled(displayID: CGDirectDisplayID) -> Bool?
{
    let did = UInt32(displayID)
    let candidates = [
        "_CoreDisplay_Display_IsHDRModeEnabled",
        "_CoreDisplay_Display_IsHDRModeEnabled_Server",
        "_SLSDisplayIsHDRModeEnabled",
        "CoreDisplay_Display_IsHDRModeEnabled",
        "CoreDisplay_Display_IsHDRModeEnabled_Server",
        "SLSDisplayIsHDRModeEnabled",
    ]

    for sym in candidates
    {
        guard let p = dlsymMaybe(nil, sym) else { continue }
        let fn = unsafeBitCast(p, to: GetHDRModeI32.self)
        let rc = fn(did)
        return rc != 0
    }
    return nil
}

func attemptPrivateToggleOneSymbol(displayID: CGDirectDisplayID, enableHDR: Bool, symbol: String) -> Int32
{
    // Attempt to load a few images (best-effort). It's OK if these fail; dlsym(RTLD_DEFAULT)
    // can still find symbols that are already loaded in the process.
    _ = dlopenIfPossible("CoreDisplay")
    _ = dlopenIfPossible("DisplayServices")
    _ = dlopenIfPossible("SkyLight")
    _ = dlopenIfPossible("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")
    _ = dlopenIfPossible("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
    _ = dlopenIfPossible("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")

    let variants: [String] = symbol.hasPrefix("_") ? [symbol, String(symbol.dropFirst())] : [symbol, "_" + symbol]
    for sym in variants
    {
        guard let p = dlsymMaybe(nil, sym) else { continue }

        // Try a few plausible signatures.
        let did = UInt32(displayID)
        let b = enableHDR
        let i32: Int32 = enableHDR ? 1 : 0
        let u32: UInt32 = enableHDR ? 1 : 0

        let before = getHDRModeEnabled(displayID: displayID)

        // Prefer void signatures; verify by re-reading state.
        let vBool = unsafeBitCast(p, to: SetHDRModeVoidBool.self)
        vBool(did, b)

        let after1 = getHDRModeEnabled(displayID: displayID)
        if after1 == b { return 0 }

        let vI32 = unsafeBitCast(p, to: SetHDRModeVoidI32.self)
        vI32(did, i32)

        let after2 = getHDRModeEnabled(displayID: displayID)
        if after2 == b { return 0 }

        // If we couldn't read state, fall back to interpreting return codes.
        if before == nil || after2 == nil
        {
            let fnBool = unsafeBitCast(p, to: SetHDRModeFnBool.self)
            let rcBool = fnBool(did, b)
            if rcBool == 0 { return 0 }

            let fnI32 = unsafeBitCast(p, to: SetHDRModeFnI32.self)
            let rcI32 = fnI32(did, i32)
            if rcI32 == 0 { return 0 }

            let fnU32 = unsafeBitCast(p, to: SetHDRModeFnU32.self)
            let rcU32 = fnU32(did, u32)
            if rcU32 == 0 { return 0 }
        }

        return 1
    }

    return -9999 // "symbol not found"
}

func runPrivateAttemptInChild(displayID: CGDirectDisplayID, enableHDR: Bool, symbol: String) -> (ok: Bool, status: Int32, reason: Process.TerminationReason?)
{
    let exe = CommandLine.arguments[0]
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = [
        "--_private-child",
        "--symbol",
        symbol,
        enableHDR ? "on" : "off",
        "--display-id",
        String(displayID),
    ]
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError = FileHandle.standardError

    do
    {
        try proc.run()
    }
    catch
    {
        return (false, 127, nil)
    }

    proc.waitUntilExit()
    let ok = (proc.terminationReason == .exit && proc.terminationStatus == 0)
    return (ok, proc.terminationStatus, proc.terminationReason)
}

// MARK: - Main

// Hidden child mode: try private toggle only, then exit.
if CommandLine.arguments.dropFirst().first == "--_private-child"
{
    // argv: hdrctl-private --_private-child --symbol <sym> (on|off) --display-id <id> ...
    let args = Array(CommandLine.arguments.dropFirst(2))

    var symbol: String?
    var cmd: Command?
    var displayID: CGDirectDisplayID?

    var i = 0
    while i < args.count
    {
        switch args[i]
        {
        case "--symbol":
            i += 1
            if i >= args.count { exit(2) }
            symbol = args[i]
        case "on", "off":
            cmd = Command(rawValue: args[i])
        case "--display-id", "-id":
            i += 1
            if i >= args.count { exit(2) }
            guard let v = parseUInt32(args[i]) else { exit(2) }
            displayID = CGDirectDisplayID(v)
        default:
            break
        }
        i += 1
    }
    guard let did = displayID, let cmd, let symbol else { exit(2) }

    let enableHDR = (cmd == .on)
    logStderr("[private-child] trying symbol: \(symbol)")
    let rc = attemptPrivateToggleOneSymbol(displayID: did, enableHDR: enableHDR, symbol: symbol)
    // Convention: 0 success, anything else failure.
    exit(rc == 0 ? 0 : 1)
}

let opts = parseArgs()

if opts.command == .list
{
    // Still log probe data for convenience when debugging.
    let probe = probePrivateAvailability()
    logStderr("[private] Image load attempts:")
    for img in probe.images
    {
        logStderr("[private]   \(img.label): \(img.attempt) => \(img.loaded ? "loaded" : "not loaded")")
    }
    logStderr("[private] Symbol probe:")
    for sym in probe.symbols
    {
        logStderr("[private]   \(sym.imageLabel): \(sym.symbol) => \(sym.found ? "found" : "missing")")
    }
    if probe.exportScans.isEmpty
    {
        logStderr("[private] Export scan: no relevant images found in dyld list")
    }
    else
    {
        logStderr("[private] Export scan (HDR/EDR/XDR-ish):")
        for r in probe.exportScans
        {
            if let error = r.error
            {
                logStderr("[private]   \(r.imageName): error=\(error)")
                continue
            }
            logStderr("[private]   \(r.imageName): matches=\(r.matchCount)")
            if !r.matchesSample.isEmpty
            {
                for s in r.matchesSample.prefix(12)
                {
                    logStderr("[private]     \(s)")
                }
                if r.matchCount > r.matchesSample.count
                {
                    logStderr("[private]     ... (\(r.matchCount - r.matchesSample.count) more)")
                }
            }
        }
    }
    logStderr("")

    listDisplays()
    exit(0)
}

let resolved = resolveDisplayID(options: opts)
let displayID = resolved.id

guard let currentMode = CGDisplayCopyDisplayMode(displayID) else
{
    die("Could not read current mode for \(resolved.label)")
}

let curEnc = pixelEncoding(of: currentMode)
let curIs10Bit = (pixelComponentBits(from: curEnc) == 10)

let want10Bit: Bool = {
    switch opts.command
    {
    case .on: return true
    case .off: return false
    case .toggle: return !curIs10Bit
    case .list: return curIs10Bit
    }
}()

// Log private availability up front.
let probe = probePrivateAvailability()
let iokit = readIOKitDisplays()
let io = iokitInfo(for: displayID, iokitDisplays: iokit)
logStderr("[private] Target: \(resolved.label) (DisplayID=\(displayID), currentEncoding=\(curEnc))")
logStderr("[private] macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
logStderr("[private] IOKit: IODisplayConnect count=\(iokit.count), matchedEntry=\(io == nil ? "no" : "yes"), ioSerial=\(io?.serial ?? 0)")
if let names = io?.names, !names.isEmpty
{
    logStderr("[private] IOKit: productNames=\(names.joined(separator: " | "))")
}
logStderr("[private] Image load attempts:")
for img in probe.images
{
    logStderr("[private]   \(img.label): \(img.attempt) => \(img.loaded ? "loaded" : "not loaded")")
}
logStderr("[private] Symbol probe:")
for sym in probe.symbols
{
    logStderr("[private]   \(sym.imageLabel): \(sym.symbol) => \(sym.found ? "found" : "missing")")
}
if probe.exportScans.isEmpty
{
    logStderr("[private] Export scan: no relevant images found in dyld list")
}
else
{
    logStderr("[private] Export scan (HDR/EDR/XDR-ish):")
    for r in probe.exportScans
    {
        if let error = r.error
        {
            logStderr("[private]   \(r.imageName): error=\(error)")
            continue
        }
        logStderr("[private]   \(r.imageName): matches=\(r.matchCount)")
        if !r.matchesSample.isEmpty
        {
            for s in r.matchesSample.prefix(12)
            {
                logStderr("[private]     \(s)")
            }
            if r.matchCount > r.matchesSample.count
            {
                logStderr("[private]     ... (\(r.matchCount - r.matchesSample.count) more)")
            }
        }
    }
}
logStderr("")

// Attempt private toggle first. We try a small set of candidates, each in its own subprocess
// so a crash for one symbol doesn't prevent trying others.
var privateCandidates: [String] = []
privateCandidates.append(contentsOf: [
    "CoreDisplay_Display_SetHDRMode",
    "CoreDisplay_Display_SetHDRMode_Server",
    "DisplayServicesSetHDRMode",
    "SLSDisplaySetHDRMode",
])
for r in probe.exportScans
{
    privateCandidates.append(contentsOf: r.matchesSample)
}
// De-dupe, but keep ordering stable.
var seen = Set<String>()
privateCandidates = privateCandidates.filter { seen.insert($0).inserted }

func isLikelySetter(_ s: String) -> Bool
{
    // We only want setters/toggles here.
    let lower = s.lowercased()
    if lower.contains("set") && lower.contains("hdr") { return true }
    if lower.contains("enablehdr") { return true }
    if lower.contains("preferhdr10") { return true }
    return false
}

privateCandidates = privateCandidates.filter(isLikelySetter)

func candidateScore(_ s: String) -> Int
{
    // Higher is better.
    let lower = s.lowercased()
    if lower.contains("sethdrmodeenabled") { return 100 }
    if lower.contains("displaysethdrmodeenabled") { return 95 }
    if lower.contains("enablehdr") { return 90 }
    if lower.contains("sethdrmode") { return 80 }
    if lower.contains("preferhdr10") { return 60 }
    if lower.contains("sethdrscalingfactor") { return 40 }
    return 10
}

privateCandidates.sort { (a, b) in
    let sa = candidateScore(a)
    let sb = candidateScore(b)
    if sa != sb { return sa > sb }
    return a < b
}
privateCandidates = Array(privateCandidates.prefix(12))

var privateSucceeded = false
for sym in privateCandidates
{
    let attempt = runPrivateAttemptInChild(displayID: displayID, enableHDR: want10Bit, symbol: sym)
    if attempt.ok
    {
        print("Private HDR toggle attempt succeeded for \(resolved.label) (symbol=\(sym)).")
        privateSucceeded = true
        break
    }
    else
    {
        let reasonStr: String
        switch attempt.reason
        {
        case .exit: reasonStr = "exit status \(attempt.status)"
        case .uncaughtSignal: reasonStr = "uncaught signal"
        case .none: reasonStr = "failed to launch child"
        @unknown default: reasonStr = "unknown"
        }
        logStderr("[private] attempt failed (symbol=\(sym), \(reasonStr))")
    }
}

if privateSucceeded
{
    exit(0)
}
logStderr("[private] All private attempts failed; falling back to public mode switch.")

// Fallback: public mode switch (10-bit vs 8-bit).
if want10Bit == curIs10Bit
{
    print("No change needed. \(resolved.label) is already \(want10Bit ? "10-bit" : "8-bit") (encoding=\(curEnc)).")
    exit(0)
}

guard let targetMode = pickMode(for: displayID, want10Bit: want10Bit) else {
    die("No suitable \(want10Bit ? "10-bit" : "8-bit") mode found for \(resolved.label).")
}

let setErr = CGDisplaySetDisplayMode(displayID, targetMode, nil)
guard setErr == .success else {
    die("Failed to set display mode (CGError=\(setErr.rawValue)).")
}

print("Switched \(resolved.label) to \(want10Bit ? "10-bit" : "8-bit") mode (pixelEncoding=\(pixelEncoding(of: targetMode))).")
