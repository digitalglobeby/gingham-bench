//
//  CrashCatcher.swift
//  Gingham Bench
//
//  A measuring run that crashes is reported as a failed run (status "crashed", with the crash's
//  kind and the crashed thread's top frames), and the process ends without macOS's "quit
//  unexpectedly" dialog, which would stop the rest of an unattended run. The process takes the
//  Mach exceptions of a crash itself (an exception port of the task, served by a thread of its
//  own: Swift's runtime traps, bad memory accesses, bad instructions) and catches `abort()`
//  (SIGABRT: uncaught Objective-C exceptions), writes the result and exits. `--crash-reports`
//  leaves crashes to macOS instead (its crash report and dialog), for debugging.
//

import Darwin
import Foundation

nonisolated enum CrashCatcher {
    /// Writes the run's result for a crash (set by the run) and exits.
    nonisolated(unsafe) static var report: ((String) -> Void)?

    static func install() {
        var port = mach_port_t(MACH_PORT_NULL)
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS,
              mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else { return }
        let mask = exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT)
        guard task_set_exception_ports(mach_task_self_, mask, port, EXCEPTION_DEFAULT, THREAD_STATE_NONE) == KERN_SUCCESS else { return }
        let receivePort = port
        let listener = Thread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let description: String = buffer.withUnsafeMutableBytes { raw in
                let header = raw.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
                guard mach_msg(header, MACH_RCV_MSG, 0, mach_msg_size_t(raw.count), receivePort, MACH_MSG_TIMEOUT_NONE,
                               mach_port_t(MACH_PORT_NULL)) == KERN_SUCCESS else { return "" }
                // An `exception_raise` request: the thread's port at byte 28, the exception at 60.
                let thread = raw.load(fromByteOffset: 28, as: mach_port_t.self)
                let exception = raw.load(fromByteOffset: 60, as: Int32.self)
                let names: [Int32: String] = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 6: "EXC_BREAKPOINT (a Swift runtime trap)"]
                return "\(names[exception] ?? "exception \(exception)") at " + frames(of: thread).joined(separator: " ← ")
            }
            guard !description.isEmpty else { return }
            FileHandle.standardError.write(Data("Gingham Bench crashed: \(description)\n".utf8))
            report?(description)
            _exit(4)
        }
        listener.name = "Crash catcher"
        listener.start()
        signal(SIGABRT) { _ in
            CrashCatcher.report?("abort() (an uncaught exception or a failed check)")
            _exit(4)
        }
    }

    /// The crashed thread's top frames, by symbol, from its registers and frame pointers (read
    /// with `vm_read`, so a broken stack can't crash this thread too).
    private static func frames(of thread: mach_port_t) -> [String] {
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return ["?"] }
        var addresses = [state.__pc, state.__lr]
        var frame = state.__fp
        for _ in 0..<12 {
            guard frame != 0, frame % 8 == 0, let saved = read(frame), let returnAddress = read(frame + 8), returnAddress != 0 else { break }
            addresses.append(returnAddress)
            guard saved > frame else { break }
            frame = saved
        }
        return addresses.prefix(8).map(symbol)
    }

    private static func read(_ address: UInt64) -> UInt64? {
        var value: UInt64 = 0
        var size = mach_vm_size_t(0)
        let result = withUnsafeMutablePointer(to: &value) {
            mach_vm_read_overwrite(mach_task_self_, address, 8, mach_vm_address_t(UInt(bitPattern: $0)), &size)
        }
        return result == KERN_SUCCESS && size == 8 ? value : nil
    }

    @_silgen_name("swift_demangle")
    private static func demangle(_ mangled: UnsafePointer<CChar>?, _ length: UInt, _ output: UnsafeMutablePointer<CChar>?,
                                 _ outputSize: UnsafeMutablePointer<UInt>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    private static func symbol(_ address: UInt64) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0, let name = info.dli_sname else {
            return String(format: "0x%llx", address)
        }
        let length = UInt(strlen(name))
        if let readable = demangle(name, length, nil, nil, 0) {
            defer { free(readable) }
            return String(cString: readable)
        }
        return String(cString: name)
    }
}
