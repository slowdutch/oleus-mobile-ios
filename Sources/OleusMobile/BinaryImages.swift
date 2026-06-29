import Foundation
import MachO

/// Captures the dyld image list (name, LC_UUID, load address) and persists it
/// next to the crash report. Written at start() — a safe, normal context —
/// so the signal handler never has to touch dyld. On the next launch the
/// pending crash's raw addresses are paired with this list, giving the
/// platform everything dSYM symbolication needs (UUID + slid load address).
enum BinaryImages {
    struct Image: Codable {
        let name: String
        let path: String
        let uuid: String
        let load_address: String
    }

    static func capture() -> [Image] {
        var images: [Image] = []
        let count = _dyld_image_count()
        images.reserveCapacity(Int(count))

        for i in 0..<count {
            guard let header = _dyld_get_image_header(i) else { continue }
            let pathC = _dyld_get_image_name(i)
            let path = pathC != nil ? String(cString: pathC!) : "?"
            let name = (path as NSString).lastPathComponent

            guard let uuid = imageUUID(header: header) else { continue }
            let load = UInt(bitPattern: header)

            images.append(Image(
                name: name,
                path: path,
                uuid: uuid,
                load_address: String(format: "0x%lx", load)
            ))
        }
        return images
    }

    static func persist() {
        let images = capture()
        if let data = try? JSONEncoder().encode(images) {
            try? data.write(to: OleusPaths.binaryImages, options: .atomic)
        }
    }

    static func loadPersisted() -> String {
        (try? String(contentsOf: OleusPaths.binaryImages, encoding: .utf8)) ?? "[]"
    }

    /// Walk the Mach-O load commands for LC_UUID.
    private static func imageUUID(header: UnsafePointer<mach_header>) -> String? {
        var cursor: UnsafeRawPointer
        let ncmds: UInt32

        if header.pointee.magic == MH_MAGIC_64 {
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            ncmds = header64.pointee.ncmds
            cursor = UnsafeRawPointer(header64.advanced(by: 1))
        } else {
            ncmds = header.pointee.ncmds
            cursor = UnsafeRawPointer(header.advanced(by: 1))
        }

        for _ in 0..<ncmds {
            let cmd = cursor.assumingMemoryBound(to: load_command.self)
            if cmd.pointee.cmd == LC_UUID {
                let uuidCmd = cursor.assumingMemoryBound(to: uuid_command.self)
                let u = uuidCmd.pointee.uuid
                return String(
                    format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                    u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
                )
            }
            if cmd.pointee.cmdsize == 0 { break }
            cursor = cursor.advanced(by: Int(cmd.pointee.cmdsize))
        }
        return nil
    }
}
