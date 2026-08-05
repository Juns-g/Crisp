// Companion to ddc-probe.swift: sends Set VCP 0x10 (brightness) writes to the
// AOC Q27G3XMN's DDC channel, 3 seconds apart, to test whether writes reach
// the monitor while its read path is wedged. Values come from argv:
//   swift scripts/ddc-write-probe.swift 30 80
// Targets ONLY the channel whose nearest registry identity is vendor=1507
// model=45862 (the AOC); everything else is skipped.
import AppKit
import IOKit

typealias IOAVServiceRef = UnsafeMutableRawPointer
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> IOAVServiceRef?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVServiceRef, _ chip: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVServiceRef, _ chip: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

let targetVendor: UInt32 = 1507
let targetModel: UInt32 = 45862

func className(_ entry: io_service_t) -> String? {
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
    defer { buf.deallocate() }
    guard IOObjectGetClass(entry, buf) == KERN_SUCCESS else { return nil }
    return String(cString: buf)
}

func u32(_ value: Any?) -> UInt32? {
    if let v = value as? UInt32 { return v }
    if let v = value as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
    if let v = value as? NSNumber { return v.uint32Value }
    return nil
}

let values = CommandLine.arguments.dropFirst().compactMap { UInt16($0) }
guard !values.isEmpty else { print("usage: swift ddc-write-probe.swift <value> [value ...]"); exit(1) }

let root = IORegistryGetRootEntry(kIOMainPortDefault)
var iterator: io_iterator_t = 0
guard IORegistryEntryCreateIterator(root, kIOServicePlane,
        IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
    print("registry iterator failed"); exit(1)
}
var target: IOAVServiceRef?
var lastVendor: UInt32 = 0
var lastModel: UInt32 = 0
var entry = IOIteratorNext(iterator)
while entry != IO_OBJECT_NULL {
    if let da = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
       let pa = da["ProductAttributes"] as? [String: Any],
       let vendor = u32(pa["LegacyManufacturerID"]), let product = u32(pa["ProductID"]) {
        lastVendor = vendor
        lastModel = product
    }
    if className(entry) == "DCPAVServiceProxy",
       lastVendor == targetVendor, lastModel == targetModel, target == nil {
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if location == nil || location == "External" {
            target = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
        }
    }
    IOObjectRelease(entry)
    entry = IOIteratorNext(iterator)
}
IOObjectRelease(iterator)
IOObjectRelease(root)

guard let target else { print("AOC channel not found"); exit(1) }
print("AOC channel found; writing \(values.map(String.init).joined(separator: ", ")) with 3s pauses")

for (i, value) in values.enumerated() {
    var chk = UInt8(0x6E ^ 0x51)
    let payload: [UInt8] = [0x84, 0x03, 0x10, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    for b in payload { chk ^= b }
    var buf = payload + [chk]
    let ret = IOAVServiceWriteI2C(target, 0x37, 0x51, &buf, UInt32(buf.count))
    print("  write \(value): \(ret == kIOReturnSuccess ? "acked" : "FAILED 0x" + String(ret, radix: 16))")
    if i < values.count - 1 { Thread.sleep(forTimeInterval: 3.0) }
}
print("ddc-write-probe: done")
