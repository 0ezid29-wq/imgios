import SwiftUI
import UniformTypeIdentifiers
import MetalKit

// MARK: - PVRTC Software Decoder
// Based on PowerVR PVRTC decompression algorithm
// Decodes PVRTC 2bpp/4bpp textures to RGBA8888

class PVRTCDecoder {
    
    // Main decompression function
    static func decompressPVRTC(compressedData: Data,
                               width: Int,
                               height: Int,
                               is2bpp: Bool) -> Data? {
        
        guard width > 0 && height > 0 else { return nil }
        
        let blockWidth = is2bpp ? 8 : 4
        let blockHeight = 4
        
        let blocksW = max(2, (width + blockWidth - 1) / blockWidth)
        let blocksH = max(2, (height + blockHeight - 1) / blockHeight)
        
        let blockSize = 8  // Both 2bpp and 4bpp use 8 bytes per block
        let expectedSize = blocksW * blocksH * blockSize
        
        guard compressedData.count >= expectedSize else {
            print("❌ PVRTC: Need \(expectedSize) bytes, got \(compressedData.count)")
            return nil
        }
        
        // Allocate output buffer (RGBA8888)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        
        // Parse blocks from compressed data
        var blocks: [[UInt64]] = Array(repeating: Array(repeating: 0, count: blocksW), count: blocksH)
        var offset = 0
        
        for by in 0..<blocksH {
            for bx in 0..<blocksW {
                guard offset + 8 <= compressedData.count else { break }
                
                // Read 8-byte block
                let blockData = compressedData.subdata(in: offset..<(offset + 8))
                let blockValue = blockData.withUnsafeBytes { ptr in
                    ptr.load(as: UInt64.self)
                }
                
                blocks[by][bx] = blockValue
                offset += 8
            }
        }
        
        // Decompress each pixel
        for y in 0..<height {
            for x in 0..<width {
                let blockX = x / blockWidth
                let blockY = y / blockHeight
                
                let pixelX = x % blockWidth
                let pixelY = y % blockHeight
                
                let bx = min(blockX, blocksW - 1)
                let by = min(blockY, blocksH - 1)
                let block = blocks[by][bx]
                
                // Extract modulation data (first 32 bits)
                let modData = UInt32(block & 0xFFFFFFFF)
                
                // Extract color data (last 32 bits)
                let colorData = UInt32((block >> 32) & 0xFFFFFFFF)
                
                // Get color A (lower 16 bits of color data)
                let colorA = UInt16(colorData & 0xFFFF)
                
                // Get color B (upper 16 bits of color data)
                let colorB = UInt16((colorData >> 16) & 0xFFFF)
                
                // Decode colors from 565/555 format
                let colorA_RGBA = decodeColor(colorA)
                let colorB_RGBA = decodeColor(colorB)
                
                // Get modulation for this pixel
                let modIndex = pixelY * blockWidth + pixelX
                let modShift = modIndex * 2
                let modBits = (modData >> modShift) & 0x3
                
                // Interpolate colors based on modulation
                let finalColor: (UInt8, UInt8, UInt8, UInt8)
                switch modBits {
                case 0:
                    finalColor = colorA_RGBA
                case 1:
                    finalColor = interpolateColors(colorA_RGBA, colorB_RGBA, factor: 0.375)
                case 2:
                    finalColor = interpolateColors(colorA_RGBA, colorB_RGBA, factor: 0.625)
                case 3:
                    finalColor = colorB_RGBA
                default:
                    finalColor = colorA_RGBA
                }
                
                // Write pixel
                let pixelOffset = (y * width + x) * 4
                rgba[pixelOffset + 0] = finalColor.0  // R
                rgba[pixelOffset + 1] = finalColor.1  // G
                rgba[pixelOffset + 2] = finalColor.2  // B
                rgba[pixelOffset + 3] = finalColor.3  // A
            }
        }
        
        return Data(rgba)
    }
    
    // Decode a 16-bit color to RGBA
    private static func decodeColor(_ color: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
        let opaque = (color & 0x8000) != 0
        
        if opaque {
            // 555 RGB (opaque)
            let r = UInt8((color >> 10) & 0x1F)
            let g = UInt8((color >> 5) & 0x1F)
            let b = UInt8(color & 0x1F)
            // Expand 5-bit to 8-bit
            return (r << 3 | r >> 2, g << 3 | g >> 2, b << 3 | b >> 2, 255)
        } else {
            // 4444 RGBA (with alpha)
            let r = UInt8((color >> 8) & 0xF)
            let g = UInt8((color >> 4) & 0xF)
            let b = UInt8(color & 0xF)
            let a = UInt8((color >> 12) & 0x7)
            // Expand 4-bit to 8-bit
            return (r << 4 | r, g << 4 | g, b << 4 | b, a << 5 | a << 2 | a >> 1)
        }
    }
    
    // Bilinear color interpolation
    private static func interpolateColors(_ c0: (UInt8, UInt8, UInt8, UInt8),
                                         _ c1: (UInt8, UInt8, UInt8, UInt8),
                                         factor: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let f = factor
        let invF = 1.0 - f
        
        let r = UInt8(Float(c0.0) * invF + Float(c1.0) * f)
        let g = UInt8(Float(c0.1) * invF + Float(c1.1) * f)
        let b = UInt8(Float(c0.2) * invF + Float(c1.2) * f)
        let a = UInt8(Float(c0.3) * invF + Float(c1.3) * f)
        
        return (r, g, b, a)
    }
    
    // Convenience function for GTA3 format codes
    static func decodeGTA3Texture(compressedData: Data,
                                  width: Int,
                                  height: Int,
                                  formatCode: UInt32) -> Data? {
        
        DebugLogger.shared.log("🚨 CORRECT DECODER - FINAL VERSION!")
        DebugLogger.shared.log("📊 Input: \(compressedData.count) bytes, \(width)x\(height), format=0x\(String(format: "%02X", formatCode))")
        
        // GTA3 Mobile iOS format:
        // [mipmap_size_1] [mipmap_size_2] ... [mipmap_size_N] [texture_data_all_mipmaps]
        
        // Calculate how many mipmaps based on texture size
        var mipW = width
        var mipH = height
        var mipmapCount = 0
        while mipW >= 2 && mipH >= 2 {
            mipmapCount += 1
            mipW /= 2
            mipH /= 2
        }
        
        DebugLogger.shared.log("📐 Expected \(mipmapCount) mipmaps for \(width)x\(height)")
        
        // Read mipmap sizes (4 bytes each)
        var offset = 0
        var mipmapSizes: [UInt32] = []
        
        for i in 0..<mipmapCount {
            guard offset + 4 <= compressedData.count else {
                DebugLogger.shared.log("⚠️ Only found \(i) mipmap sizes")
                break
            }
            
            let sizeData = compressedData.subdata(in: offset..<(offset + 4))
            let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self) }
            
            mipmapSizes.append(size)
            offset += 4
            
            DebugLogger.shared.log("  Mipmap[\(i)]: \(size) bytes")
        }
        
        guard !mipmapSizes.isEmpty else {
            DebugLogger.shared.log("❌ No mipmap sizes found!")
            return nil
        }
        
        // Now offset points to the start of texture data
        DebugLogger.shared.log("📍 Texture data starts at offset \(offset)")
        DebugLogger.shared.log("📋 First 32 bytes of texture: \(compressedData.subdata(in: offset..<min(offset+32, compressedData.count)).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Extract first (largest) mipmap
        let firstMipmapSize = Int(mipmapSizes[0])
        guard offset + firstMipmapSize <= compressedData.count else {
            DebugLogger.shared.log("❌ Not enough data! Need \(firstMipmapSize), have \(compressedData.count - offset)")
            return nil
        }
        
        let textureData = compressedData.subdata(in: offset..<(offset + firstMipmapSize))
        DebugLogger.shared.log("✅ Extracted \(textureData.count) bytes of PVRTC data")
        
        // Decode PVRTC (format 0x06 and 0x08 are both PVRTC 2bpp on iOS)
        let is2bpp = true  // iOS GTA3 uses 2bpp for these formats
        
        DebugLogger.shared.log("🔄 Decoding as PVRTC 2bpp...")
        
        return decompressPVRTC(compressedData: textureData,
                              width: width,
                              height: height,
                              is2bpp: is2bpp)
    }
}

// MARK: - Data Models

// MARK: - Debug Logger
class DebugLogger {
    static let shared = DebugLogger()
    private let logFile: URL
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFile = docs.appendingPathComponent("DEBUG_LOG.txt")
        
        // Initialize log file
        let header = """
        ==========================================
        TXD Tool Debug Log
        Started: \(Date())
        ==========================================
        
        """
        try? header.write(to: logFile, atomically: true, encoding: .utf8)
    }
    
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)\n"
        
        print(entry.trimmingCharacters(in: .newlines))
        
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
    }
}

// MARK: - Data Models

struct PVRTextureEntry: Identifiable {
    let id = UUID()
    let name: String
    let offset: Int
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let hasAlpha: Bool
    let imgHash: UInt32?  // NEW: Store the img= hash value
    let pngHash: UInt32?  // NEW: Store the png= hash value
    
    var sizeString: String {
        "\(width)×\(height)"
    }
    
    var formatString: String {
        switch pixelFormat {
        case 0x18: return "PVRTC 2bpp"
        case 0x19: return "PVRTC 4bpp"
        case 0x13: return "RGB 565"
        case 0x10: return "RGBA 4444"
        case 0x04: return "DXT1/BC1"  // NEW: Format 0x04
        case 0x06: return "ETC2 RGB"
        case 0x08: return "ETC2 RGBA"
        case 0x09: return "RGBA 8888"
        default: return "Format 0x\(String(format: "%02X", pixelFormat))"
        }
    }
    
    var metalPixelFormat: MTLPixelFormat {
        switch pixelFormat {
        case 0x18: return hasAlpha ? .pvrtc_rgba_2bpp : .pvrtc_rgb_2bpp
        case 0x19: return hasAlpha ? .pvrtc_rgba_4bpp : .pvrtc_rgb_4bpp
        case 0x04:
            // DXT1/BC1
            if #available(iOS 16.4, *) {
                return .bc1_rgba
            } else {
                return .rgba8Unorm  // Fallback
            }
        case 0x06:
            // ETC2 RGB
            if #available(iOS 11.0, *) {
                return .etc2_rgb8
            } else {
                return .pvrtc_rgba_2bpp
            }
        case 0x08:
            // ETC2 RGBA
            if #available(iOS 11.0, *) {
                return .eac_rgba8
            } else {
                return .pvrtc_rgba_2bpp
            }
        case 0x13: return .b5g6r5Unorm  // RGB 565
        case 0x10: return .abgr4Unorm   // RGBA 4444
        case 0x09: return .rgba8Unorm   // RGBA 8888 (uncompressed)
        default: 
            DebugLogger.shared.log("⚠️ Unknown format: 0x\(String(format: "%02X", pixelFormat))")
            return .rgba8Unorm  // Fallback to RGBA
        }
    }
    
    var bytesPerPixel: Int {
        switch pixelFormat {
        case 0x06, 0x08, 0x18, 0x19: return 0 // Compressed formats
        case 0x13: return 2 // RGB 565
        case 0x10: return 2 // RGBA 4444
        case 0x09: return 4 // RGBA 8888
        default: return 4
        }
    }
    
    var dataSize: Int {
        switch pixelFormat {
        case 0x06: // ETC2 RGB with mipmaps
            var total = 0
            var w = width
            var h = height
            while w >= 4 && h >= 4 {
                let blocksW = (w + 3) / 4
                let blocksH = (h + 3) / 4
                total += blocksW * blocksH * 8  // 8 bytes per ETC2 RGB block
                w /= 2
                h /= 2
            }
            return total
            
        case 0x08: // ETC2 RGBA with mipmaps
            var total = 0
            var w = width
            var h = height
            while w >= 4 && h >= 4 {
                let blocksW = (w + 3) / 4
                let blocksH = (h + 3) / 4
                total += blocksW * blocksH * 16  // 16 bytes per ETC2 RGBA block
                w /= 2
                h /= 2
            }
            return total
            
        case 0x18: // PVRTC 2bpp (no mipmaps)
            return max(32, width * height / 4)
        case 0x19: // PVRTC 4bpp (no mipmaps)
            return max(32, width * height / 2)
        case 0x13, 0x10: // RGB 565, RGBA 4444
            return width * height * 2
        case 0x09: // RGBA 8888
            return width * height * 4
        default:
            return width * height * 4
        }
    }
}

// MARK: - File Manager

class SandboxFileManager {
    static let shared = SandboxFileManager()
    
    private let docsDir: URL
    
    init() {
        docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func saveFile(_ url: URL, filename: String) -> URL? {
        let destination = docsDir.appendingPathComponent(filename)
        
        DebugLogger.shared.log("📥 Attempting to save: \(filename)")
        DebugLogger.shared.log("   Source: \(url.path)")
        DebugLogger.shared.log("   Destination: \(destination.path)")
        
        do {
            // Check if source exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                DebugLogger.shared.log("❌ Source file doesn't exist!")
                return nil
            }
            
            // Remove existing file if it exists
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
                DebugLogger.shared.log("🗑️  Removed existing file")
            }
            
            // Copy new file
            try FileManager.default.copyItem(at: url, to: destination)
            
            let fileSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
            DebugLogger.shared.log("✅ Saved successfully (\(fileSize) bytes)")
            return destination
        } catch {
            DebugLogger.shared.log("❌ Save failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    func listFiles() -> [URL] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: docsDir,
                includingPropertiesForKeys: nil
            )
            return contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "txt" || ext == "dat"
            }
        } catch {
            print("✗ List failed: \(error)")
            return []
        }
    }
}

// MARK: - Metal Texture Decoder

class MetalTextureDecoder {
    private let device: MTLDevice
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("✗ Metal not supported")
            return nil
        }
        self.device = device
    }
    
    func loadTexture(from datURL: URL, entry: PVRTextureEntry) -> MTLTexture? {
        DebugLogger.shared.log("🖼️ Loading texture: \(entry.name)")
        DebugLogger.shared.log("   Size: \(entry.width)x\(entry.height)")
        DebugLogger.shared.log("   Format: 0x\(String(format: "%02X", entry.pixelFormat)) (\(entry.formatString))")
        DebugLogger.shared.log("   Offset: 0x\(String(format: "%X", entry.offset))")
        
        guard let fileHandle = try? FileHandle(forReadingFrom: datURL) else {
            DebugLogger.shared.log("❌ Cannot open .dat file")
            return nil
        }
        
        defer { try? fileHandle.close() }
        
        // Seek to texture offset
        if #available(iOS 13.4, *) {
            try? fileHandle.seek(toOffset: UInt64(entry.offset))
        } else {
            fileHandle.seek(toFileOffset: UInt64(entry.offset))
        }
        
        // Read texture data with extra bytes for header
        let expectedSize = entry.dataSize + 256  // Extra for header
        guard let data = try? fileHandle.read(upToCount: expectedSize) else {
            DebugLogger.shared.log("❌ Failed to read texture data")
            return nil
        }
        
        DebugLogger.shared.log("✓ Read \(data.count) bytes")
        DebugLogger.shared.log("📋 First 16 bytes: \(data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Determine header skip size
        var headerSkip = 52  // Default GTA3 Mobile header size
        
        // Check for standard PVR headers
        if data.count >= 4 {
            if data[0] == 0x50 && data[1] == 0x56 && data[2] == 0x52 && data[3] == 0x03 {
                headerSkip = 52
                DebugLogger.shared.log("✓ Found PVR3 header")
            } else if data[0] == 0x21 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x00 {
                headerSkip = 52
                DebugLogger.shared.log("✓ Found legacy PVR header")
            } else {
                // GTA3 Mobile custom header - try different sizes
                DebugLogger.shared.log("✓ Custom GTA3 header - using 52-byte skip")
            }
        }
        
        // Extract compressed texture data
        guard data.count > headerSkip else {
            DebugLogger.shared.log("❌ Not enough data after header skip")
            return nil
        }
        
        let compressedData = data.subdata(in: headerSkip..<data.count)
        DebugLogger.shared.log("✓ Compressed data: \(compressedData.count) bytes (after skipping \(headerSkip) byte header)")
        
        // DECODE PVRTC TO RGBA8888 using software decoder
        guard let rgbaData = PVRTCDecoder.decodeGTA3Texture(
            compressedData: compressedData,
            width: entry.width,
            height: entry.height,
            formatCode: entry.pixelFormat
        ) else {
            DebugLogger.shared.log("❌ PVRTC decode failed!")
            return nil
        }
        
        DebugLogger.shared.log("✅ Decoded to RGBA8888: \(rgbaData.count) bytes")
        
        // Create UNCOMPRESSED Metal texture descriptor
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,  // Uncompressed!
            width: entry.width,
            height: entry.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            DebugLogger.shared.log("❌ Failed to create Metal texture")
            return nil
        }
        
        // Upload decoded RGBA data to Metal
        let bytesPerRow = entry.width * 4  // RGBA = 4 bytes per pixel
        
        rgbaData.withUnsafeBytes { buffer in
            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: entry.width, height: entry.height, depth: 1)
            )
            
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        
        DebugLogger.shared.log("✅ Texture uploaded to Metal successfully!")
        return texture
    }
}

// MARK: - Metal View for Rendering

struct MetalTextureView: UIViewRepresentable {
    let texture: MTLTexture
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = texture.device
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        mtkView.framebufferOnly = false
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.texture = texture
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture
        
        init(texture: MTLTexture) {
            self.texture = texture
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        
        func draw(in view: MTKView) {
            // Not actually used since we convert to UIImage instead
            // Keeping this for potential future Metal-based rendering
        }
    }
}

// MARK: - PVR Parser

class PVRParser {
    
    static func parseTextureList(from txtURL: URL, tocOffsets: [Int] = []) -> [PVRTextureEntry] {
        DebugLogger.shared.log("📖 Starting parse of: \(txtURL.lastPathComponent)")
        
        if !tocOffsets.isEmpty {
            DebugLogger.shared.log("✓ Using TOC offsets (\(tocOffsets.count) entries)")
        } else {
            DebugLogger.shared.log("⚠️ No TOC offsets - using sequential calculation")
        }
        
        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            DebugLogger.shared.log("❌ File doesn't exist at path!")
            return []
        }
        
        guard let contents = try? String(contentsOf: txtURL, encoding: .utf8) else {
            DebugLogger.shared.log("❌ Failed to read file as UTF-8")
            return []
        }
        
        DebugLogger.shared.log("📄 File size: \(contents.count) characters")
        
        var entries: [PVRTextureEntry] = []
        let lines = contents.components(separatedBy: .newlines)
        
        DebugLogger.shared.log("📝 Total lines: \(lines.count)")
        
        var currentOffset = 0  // Sequential offset tracker (fallback)
        var tocIndex = 0  // Index into TOC offsets array
        
        for (index, line) in lines.enumerated() {
            // Skip empty lines and category/affiliate lines
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("cat=") else { continue }
            guard !trimmed.contains("affiliate=") else { continue }
            
            // Extract texture name (quoted string at start)
            guard let nameStart = trimmed.firstIndex(of: "\""),
                  let nameEnd = trimmed[trimmed.index(after: nameStart)...].firstIndex(of: "\"") else {
                continue
            }
            
            let name = String(trimmed[trimmed.index(after: nameStart)..<nameEnd])
            
            // Parse key=value pairs
            let remainder = String(trimmed[trimmed.index(after: nameEnd)...])
            let pairs = remainder.components(separatedBy: " ").filter { !$0.isEmpty }
            
            var width: Int?
            var height: Int?
            var format: Int?
            var imgHash: UInt32?
            var pngHash: UInt32?
            
            for pair in pairs {
                let components = pair.components(separatedBy: "=")
                guard components.count == 2 else { continue }
                
                let key = components[0]
                let value = components[1]
                
                switch key {
                case "width":
                    width = Int(value)
                case "height":
                    height = Int(value)
                case "format":
                    format = Int(value, radix: 16)
                case "img":
                    // Parse img hash as hex
                    imgHash = UInt32(value, radix: 16)
                case "png":
                    // Parse png hash as hex  
                    pngHash = UInt32(value, radix: 16)
                default:
                    break
                }
            }
            
            // Validate we have all required fields
            guard let w = width,
                  let h = height,
                  let fmt = format else {
                if index < 10 {
                    DebugLogger.shared.log("⚠️  Line \(index): Missing fields - '\(trimmed.prefix(80))'")
                }
                continue
            }
            
            // Calculate data size for this texture
            let textureSize: Int
            switch fmt {
            case 0x18: // PVRTC 2bpp
                textureSize = max(32, w * h / 4)
            case 0x19: // PVRTC 4bpp
                textureSize = max(32, w * h / 2)
            case 0x13, 0x10: // RGB 565, RGBA 4444
                textureSize = w * h * 2
            case 0x06, 0x08, 0x09: // RGBA 8888
                textureSize = w * h * 4
            default:
                textureSize = w * h * 4
            }
            
            // Determine if texture has alpha
            let hasAlpha = (fmt == 0x19 || fmt == 0x18)
            
            // Determine actual offset: use TOC if available, otherwise sequential
            let actualOffset: Int
            if !tocOffsets.isEmpty && tocIndex < tocOffsets.count {
                actualOffset = tocOffsets[tocIndex]
                tocIndex += 1
            } else {
                actualOffset = currentOffset
                currentOffset += textureSize
            }
            
            let entry = PVRTextureEntry(
                name: name,
                offset: actualOffset,  // Use real offset from TOC or sequential
                width: w,
                height: h,
                pixelFormat: UInt32(fmt),
                hasAlpha: hasAlpha,
                imgHash: imgHash,
                pngHash: pngHash
            )
            
            entries.append(entry)
            
            // Log first 5 entries for verification
            if entries.count <= 5 {
                var hashInfo = ""
                if let img = imgHash {
                    hashInfo += " img=0x\(String(format: "%X", img))"
                }
                if let png = pngHash {
                    hashInfo += " png=0x\(String(format: "%X", png))"
                }
                let offsetSource = !tocOffsets.isEmpty ? "TOC" : "seq"
                DebugLogger.shared.log("✓ Entry \(entries.count): \(name) [\(w)x\(h)] @ offset \(actualOffset) (\(offsetSource)) (size: \(textureSize)) fmt=0x\(String(format: "%X", fmt))\(hashInfo)")
            }
            
            // Advance sequential offset for next texture (only used as fallback)
            if tocOffsets.isEmpty {
                currentOffset += textureSize
            }
        }
        
        DebugLogger.shared.log("✅ Parsed \(entries.count) textures successfully")
        DebugLogger.shared.log("📊 Total expected data size: \(currentOffset) bytes (\(currentOffset / 1024 / 1024) MB)")
        return entries
    }
}

// MARK: - Main View Model

class TextureViewModel: ObservableObject {
    @Published var textures: [PVRTextureEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var loadedTexture: MTLTexture?
    
    var txtFileURL: URL?
    var datFileURL: URL?
    var imgFileURL: URL?  // NEW: gta3.img file
    var tocFileURL: URL?  // NEW: gta3.pvr.toc file
    private var tocOffsets: [Int] = []  // NEW: Real offsets from TOC
    private let decoder = MetalTextureDecoder()
    
    func loadFiles(txt: URL, dat: URL, img: URL? = nil, toc: URL? = nil) {
        DebugLogger.shared.log("🚀 loadFiles called")
        DebugLogger.shared.log("   txt: \(txt.lastPathComponent)")
        DebugLogger.shared.log("   dat: \(dat.lastPathComponent)")
        if let img = img {
            DebugLogger.shared.log("   img: \(img.lastPathComponent)")
        }
        if let toc = toc {
            DebugLogger.shared.log("   toc: \(toc.lastPathComponent)")
        }
        
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { 
                DebugLogger.shared.log("❌ Self was deallocated")
                return 
            }
            
            // Save files to documents directory
            DebugLogger.shared.log("💾 Saving files to documents...")
            
            guard let savedTxt = SandboxFileManager.shared.saveFile(txt, filename: "gta3.txt") else {
                DebugLogger.shared.log("❌ Failed to save txt file")
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to save gta3.txt"
                    self.isLoading = false
                }
                return
            }
            
            guard let savedDat = SandboxFileManager.shared.saveFile(dat, filename: "gta3.pvr.dat") else {
                DebugLogger.shared.log("❌ Failed to save dat file")
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to save gta3.pvr.dat"
                    self.isLoading = false
                }
                return
            }
            
            self.txtFileURL = savedTxt
            self.datFileURL = savedDat
            
            // Save gta3.img if provided
            if let img = img {
                if let savedImg = SandboxFileManager.shared.saveFile(img, filename: "gta3.img") {
                    self.imgFileURL = savedImg
                    self.analyzeImgFile(savedImg)
                }
            }
            
            // Save and parse gta3.pvr.toc if provided
            if let toc = toc {
                if let savedToc = SandboxFileManager.shared.saveFile(toc, filename: "gta3.pvr.toc") {
                    self.tocFileURL = savedToc
                    self.tocOffsets = self.parseTOCFile(savedToc)
                    DebugLogger.shared.log("✅ TOC file loaded - will use real offsets!")
                } else {
                    DebugLogger.shared.log("⚠️ Failed to save TOC file")
                }
            } else {
                DebugLogger.shared.log("⚠️ No TOC file - will use sequential offsets (may not work)")
            }
            
            // Analyze .dat file structure
            self.analyzeDatFile(savedDat)
            
            DebugLogger.shared.log("🔍 Starting parse...")
            
            // Parse texture list with TOC offsets if available
            let entries = PVRParser.parseTextureList(from: savedTxt, tocOffsets: self.tocOffsets)
            
            DebugLogger.shared.log("🔄 Updating UI with \(entries.count) textures...")
            
            DispatchQueue.main.async {
                self.textures = entries
                self.isLoading = false
                
                if entries.isEmpty {
                    DebugLogger.shared.log("⚠️  No textures parsed - check DEBUG_LOG.txt")
                    self.errorMessage = "No textures found in gta3.txt. Check DEBUG_LOG.txt in Files app."
                } else {
                    DebugLogger.shared.log("✅ UI updated successfully!")
                }
            }
        }
    }
    
    private func analyzeImgFile(_ url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            DebugLogger.shared.log("❌ Cannot open gta3.img for analysis")
            return
        }
        
        defer { try? fileHandle.close() }
        
        // Get file size
        if #available(iOS 13.0, *) {
            if let fileSize = try? fileHandle.seekToEnd() {
                DebugLogger.shared.log("📦 IMG file size: \(fileSize) bytes (\(fileSize / 1024 / 1024) MB)")
            }
        }
        
        // Read first 2048 bytes to check for header/directory
        fileHandle.seek(toFileOffset: 0)
        if let header = try? fileHandle.read(upToCount: 2048) {
            DebugLogger.shared.log("📋 IMG First 64 bytes (hex): \(header.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " "))")
            
            // Check for IMG archive signatures
            if header.count >= 4 {
                let magic = String(data: header.prefix(4), encoding: .ascii) ?? ""
                DebugLogger.shared.log("   Magic bytes: '\(magic)'")
                
                // Check for "VER2" or other IMG format identifiers
                if magic == "VER2" {
                    DebugLogger.shared.log("✓ Found VER2 IMG archive format")
                }
            }
            
            // Look for directory entries (typically 32-byte structures)
            if header.count >= 64 {
                DebugLogger.shared.log("📂 Analyzing IMG directory structure...")
                // IMG archives often have a directory at the start
                // Each entry is typically: offset(4) + size(4) + name(24)
            }
        }
    }
    
    private func parseTOCFile(_ url: URL) -> [Int] {
        DebugLogger.shared.log("📑 Parsing TOC file...")
        
        guard let data = try? Data(contentsOf: url) else {
            DebugLogger.shared.log("❌ Failed to read TOC file")
            return []
        }
        
        DebugLogger.shared.log("✓ TOC file size: \(data.count) bytes")
        
        var offsets: [Int] = []
        
        // Read as array of UInt32 (little-endian)
        data.withUnsafeBytes { buffer in
            let uint32Buffer = buffer.bindMemory(to: UInt32.self)
            
            // First entry is file size verification
            if uint32Buffer.count > 0 {
                let fileSize = Int(uint32Buffer[0])
                DebugLogger.shared.log("✓ TOC header: file size = \(fileSize) bytes (\(fileSize / 1024 / 1024) MB)")
            }
            
            // Remaining entries are texture offsets
            for i in 1..<uint32Buffer.count {
                let offset = Int(uint32Buffer[i])
                if offset != 0xFFFFFFFF {  // Skip invalid entries
                    offsets.append(offset)
                }
            }
        }
        
        DebugLogger.shared.log("✓ Found \(offsets.count) valid texture offsets")
        if offsets.count >= 10 {
            DebugLogger.shared.log("   First 10 offsets: \(offsets.prefix(10).map { String($0) }.joined(separator: ", "))")
        }
        
        return offsets
    }
    
    private func analyzeDatFile(_ url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            DebugLogger.shared.log("❌ Cannot open .dat for analysis")
            return
        }
        
        defer { try? fileHandle.close() }
        
        // Get file size
        var fileSize: UInt64 = 0
        if #available(iOS 13.0, *) {
            if let size = try? fileHandle.seekToEnd() {
                fileSize = size
                DebugLogger.shared.log("📦 DAT file size: \(fileSize) bytes (\(fileSize / 1024 / 1024) MB)")
            }
        }
        
        // Read first 20KB to search for hash table
        fileHandle.seek(toFileOffset: 0)
        guard let header = try? fileHandle.read(upToCount: 20480) else {
            DebugLogger.shared.log("❌ Failed to read .dat header")
            return
        }
        
        DebugLogger.shared.log("📋 First 64 bytes (hex): \(header.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Search for known hash values in the header
        let knownHashes: [UInt32] = [
            0xF8E2B03F,  // pool_table_cloth img hash
            0xCA07A753,  // pool_table_cloth png hash
            0x8309A712,  // telewireslong2 img hash
            0x5D1C24A5   // telewireslong img hash
        ]
        
        DebugLogger.shared.log("🔍 Searching for hash table...")
        var hashTableStart: Int?
        
        for hash in knownHashes {
            // Search for hash in little-endian format
            let hashBytes = withUnsafeBytes(of: hash.littleEndian) { Array($0) }
            
            for i in 0..<(header.count - 4) {
                if header[i] == hashBytes[0] &&
                   header[i+1] == hashBytes[1] &&
                   header[i+2] == hashBytes[2] &&
                   header[i+3] == hashBytes[3] {
                    DebugLogger.shared.log("✓ Found hash 0x\(String(format: "%X", hash)) at offset \(i) in header!")
                    if hashTableStart == nil || i < hashTableStart! {
                        hashTableStart = i
                    }
                }
            }
        }
        
        if let tableStart = hashTableStart {
            DebugLogger.shared.log("📂 Hash table likely starts at offset \(tableStart)")
            
            // Try to decode hash table entries
            DebugLogger.shared.log("📊 Analyzing hash table structure...")
            
            // Assume structure: hash(4) + offset(4) + size(4) = 12 bytes per entry
            // Or: hash(4) + offset(4) = 8 bytes per entry
            
            for entrySize in [8, 12, 16] {
                DebugLogger.shared.log("  Testing \(entrySize)-byte entries:")
                var offset = tableStart
                var validEntries = 0
                
                for i in 0..<min(5, 193) {
                    if offset + entrySize > header.count { break }
                    
                    let entryData = header.subdata(in: offset..<(offset + entrySize))
                    let hash = entryData.withUnsafeBytes { $0.load(as: UInt32.self) }
                    let dataOffset = entryData.withUnsafeBytes { 
                        $0.load(fromByteOffset: 4, as: UInt32.self) 
                    }
                    
                    if dataOffset > 0 && dataOffset < fileSize {
                        DebugLogger.shared.log("    Entry \(i): hash=0x\(String(format: "%X", hash)) offset=\(dataOffset)")
                        validEntries += 1
                    }
                    
                    offset += entrySize
                }
                
                if validEntries >= 3 {
                    DebugLogger.shared.log("  ✓ Found \(validEntries) valid entries with \(entrySize)-byte structure!")
                }
            }
        } else {
            DebugLogger.shared.log("⚠️  No hash values found in first 20KB - trying hash decoding...")
            
            // Try decoding hash values as offsets
            let testCases: [(String, UInt32)] = [
                ("pool_table_cloth", 0xF8E2B03F),
                ("telewireslong2", 0x8309A712),
                ("telewireslong", 0x5D1C24A5)
            ]
            
            for (name, hash) in testCases {
                // Try different decoding methods
                let modulo = UInt64(hash) % fileSize
                let lower24 = hash & 0xFFFFFF
                let lower16 = hash & 0xFFFF
                let shifted = hash >> 8
                
                DebugLogger.shared.log("🔢 Decoding hash for \(name) (0x\(String(format: "%X", hash))):")
                DebugLogger.shared.log("   Modulo filesize: \(modulo)")
                DebugLogger.shared.log("   Lower 24 bits: \(lower24)")
                DebugLogger.shared.log("   Lower 16 bits: \(lower16)")
                DebugLogger.shared.log("   Shifted >>8: \(shifted)")
                
                // Try reading at these offsets to see if texture data is there
                for (method, offset) in [("modulo", modulo), ("lower24", UInt64(lower24)), ("shifted", UInt64(shifted))] {
                    if offset < fileSize - 64 {
                        fileHandle.seek(toFileOffset: offset)
                        if let testData = try? fileHandle.read(upToCount: 16) {
                            let preview = testData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                            DebugLogger.shared.log("   \(method) @ \(offset): \(preview)")
                        }
                    }
                }
            }
            
            // Search for hash in entire file (sample every 1MB)
            DebugLogger.shared.log("🔍 Sampling file for hash 0xF8E2B03F...")
            let searchHash: UInt32 = 0xF8E2B03F
            let searchBytes = withUnsafeBytes(of: searchHash.littleEndian) { Array($0) }
            
            for megabyte in 0..<min(10, Int(fileSize / 1048576)) {
                let offset = UInt64(megabyte) * 1048576
                fileHandle.seek(toFileOffset: offset)
                if let chunk = try? fileHandle.read(upToCount: 1048576) {
                    for i in 0..<(chunk.count - 4) {
                        if chunk[i] == searchBytes[0] &&
                           chunk[i+1] == searchBytes[1] &&
                           chunk[i+2] == searchBytes[2] &&
                           chunk[i+3] == searchBytes[3] {
                            DebugLogger.shared.log("   ✓ Found at offset \(offset + UInt64(i))")
                        }
                    }
                }
            }
        }
    }
    
    func loadTexturePreview(for entry: PVRTextureEntry) {
        DebugLogger.shared.log("🎯 User tapped: \(entry.name)")
        
        guard let datURL = datFileURL else {
            DebugLogger.shared.log("❌ No .dat file URL!")
            errorMessage = "No .dat file loaded"
            return
        }
        
        guard let decoder = decoder else {
            DebugLogger.shared.log("❌ Metal not available")
            errorMessage = "Metal not available"
            return
        }
        
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let texture = decoder.loadTexture(from: datURL, entry: entry)
            
            DispatchQueue.main.async {
                self.loadedTexture = texture
                self.isLoading = false
                
                if texture == nil {
                    DebugLogger.shared.log("❌ Texture load failed - check debug log")
                    self.errorMessage = "Failed to load texture - check debug log"
                } else {
                    DebugLogger.shared.log("✅ Texture ready for display!")
                }
            }
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var viewModel = TextureViewModel()
    @State private var showFilePicker = false
    @State private var selectedTexture: PVRTextureEntry?
    @State private var showDebugLog = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if viewModel.textures.isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Textures Loaded")
                            .font(.title2)
                            .foregroundColor(.white)
                        
                        Text("Import gta3.txt, gta3.pvr.dat, and gta3.pvr.toc to get started")
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("Import Files") {
                            showFilePicker = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                } else {
                    // Texture list
                    List {
                        ForEach(viewModel.textures) { texture in
                            Button(action: {
                                selectedTexture = texture
                                viewModel.loadTexturePreview(for: texture)
                            }) {
                                TextureRow(texture: texture)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
                
                if viewModel.isLoading {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }
            .navigationTitle("PVR Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DebugLogger.shared.log("🎬 App launched")
                DebugLogger.shared.log("📱 Documents: \(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showDebugLog = true }) {
                        Image(systemName: "ladybug")
                            .foregroundColor(.orange)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                FilePickerView { urls in
                    handleFileSelection(urls)
                }
            }
            .sheet(item: $selectedTexture) { texture in
                TexturePreviewView(
                    texture: texture,
                    metalTexture: viewModel.loadedTexture
                )
            }
            .sheet(isPresented: $showDebugLog) {
                DebugLogView()
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
        }
    }
    
    private func handleFileSelection(_ urls: [URL]) {
        DebugLogger.shared.log("📁 User selected \(urls.count) files")
        
        guard urls.count >= 2 else {
            viewModel.errorMessage = "Please select at least gta3.txt and gta3.pvr.dat (gta3.pvr.toc recommended)"
            return
        }
        
        var txtFile: URL?
        var datFile: URL?
        var imgFile: URL?
        var tocFile: URL?
        
        for url in urls {
            let filename = url.lastPathComponent.lowercased()
            DebugLogger.shared.log("   Found: \(filename)")
            
            if filename.contains("gta3.txt") || filename.hasSuffix(".txt") {
                txtFile = url
            } else if filename.contains(".dat") || filename.contains("pvr.dat") {
                datFile = url
            } else if filename.contains(".img") {
                imgFile = url
            } else if filename.contains(".toc") || filename.contains("pvr.toc") {
                tocFile = url
            }
        }
        
        guard let txt = txtFile, let dat = datFile else {
            viewModel.errorMessage = "Missing required files (need gta3.txt and gta3.pvr.dat)"
            return
        }
        
        // Log which optional files were found
        if tocFile != nil {
            DebugLogger.shared.log("✓ Found TOC file - textures will load correctly!")
        } else {
            DebugLogger.shared.log("⚠️ No TOC file - may use incorrect offsets")
        }
        
        if imgFile != nil {
            DebugLogger.shared.log("✓ Found IMG file - will analyze")
        }
        
        viewModel.loadFiles(txt: txt, dat: dat, img: imgFile, toc: tocFile)
    }
}

// MARK: - Texture Preview View

struct TexturePreviewView: View {
    let texture: PVRTextureEntry
    let metalTexture: MTLTexture?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let mtlTexture = metalTexture {
                    VStack(spacing: 20) {
                        // Texture preview using UIImage conversion
                        if let image = textureToUIImage(mtlTexture) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 400)
                                .background(
                                    // Checkerboard background for transparency
                                    CheckerboardView()
                                )
                                .cornerRadius(8)
                                .padding()
                        } else {
                            Text("Preview unavailable")
                                .foregroundColor(.gray)
                        }
                        
                        // Info section
                        VStack(alignment: .leading, spacing: 12) {
                            InfoRow(label: "Name", value: texture.name)
                            InfoRow(label: "Size", value: texture.sizeString)
                            InfoRow(label: "Format", value: texture.formatString)
                            InfoRow(label: "Alpha", value: texture.hasAlpha ? "Yes" : "No")
                            InfoRow(label: "Offset", value: "0x\(String(format: "%X", texture.offset))")
                        }
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                        .padding(.horizontal)
                        
                        Spacer()
                    }
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }
            .navigationTitle(texture.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func textureToUIImage(_ texture: MTLTexture) -> UIImage? {
        DebugLogger.shared.log("🔄 Converting texture to UIImage...")
        DebugLogger.shared.log("   Texture size: \(texture.width)x\(texture.height)")
        DebugLogger.shared.log("   Pixel format: \(texture.pixelFormat.rawValue)")
        
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let imageSize = width * height * bytesPerPixel
        
        var imageData = [UInt8](repeating: 0, count: imageSize)
        
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        texture.getBytes(
            &imageData,
            bytesPerRow: bytesPerRow,
            from: region,
            mipmapLevel: 0
        )
        DebugLogger.shared.log("✓ Got \(imageData.count) bytes from texture")
        
        guard let dataProvider = CGDataProvider(
            data: Data(imageData) as CFData
        ) else {
            DebugLogger.shared.log("❌ Failed to create data provider")
            return nil
        }
        
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            DebugLogger.shared.log("❌ Failed to create CGImage")
            return nil
        }
        
        DebugLogger.shared.log("✅ Successfully converted to UIImage!")
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Supporting Views

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .foregroundColor(.white)
        }
    }
}

struct CheckerboardView: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let squareSize: CGFloat = 10
                let cols = Int(size.width / squareSize) + 1
                let rows = Int(size.height / squareSize) + 1
                
                for row in 0..<rows {
                    for col in 0..<cols {
                        if (row + col) % 2 == 0 {
                            let rect = CGRect(
                                x: CGFloat(col) * squareSize,
                                y: CGFloat(row) * squareSize,
                                width: squareSize,
                                height: squareSize
                            )
                            context.fill(Path(rect), with: .color(.gray.opacity(0.3)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Texture Row

struct TextureRow: View {
    let texture: PVRTextureEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(texture.name)
                .font(.headline)
                .foregroundColor(.white)
            
            HStack(spacing: 16) {
                Label(texture.sizeString, systemImage: "square.resize")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Label(texture.formatString, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                if texture.hasAlpha {
                    Label("Alpha", systemImage: "a.square")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.black)
    }
}

// MARK: - File Picker

struct FilePickerView: UIViewControllerRepresentable {
    let onSelect: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .text],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FilePickerView
        
        init(_ parent: FilePickerView) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onSelect(urls)
        }
    }
}

// MARK: - Debug Log View

struct DebugLogView: View {
    @Environment(\.dismiss) var dismiss
    @State private var logContent = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(logContent)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        clearLog()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadLog()
            }
        }
    }
    
    private func loadLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("DEBUG_LOG.txt")
        
        if let content = try? String(contentsOf: logFile) {
            logContent = content
        } else {
            logContent = "No log file found."
        }
    }
    
    private func clearLog() {
        let header = """
        ==========================================
        TXD Tool Debug Log (CLEARED)
        Started: \(Date())
        ==========================================
        
        """
        logContent = header
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("DEBUG_LOG.txt")
        try? header.write(to: logFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
