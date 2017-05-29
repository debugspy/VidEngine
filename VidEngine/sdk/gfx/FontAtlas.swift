//
//  FontAtlas.swift
//  VidEngine
//
//  Created by David Gavilan on 2017/05/29.
//  Swift port of http://metalbyexample.com/rendering-text-in-metal-with-signed-distance-fields/
//

import Foundation
import CoreGraphics
import UIKit
import MetalKit
import simd

enum FontAtlasError : Error {
    case UnsupportedTextureSize, AtlasNotProperlyInitialized
}

class GlyphDescriptor: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { get { return true } }
    
    let glyphIndex: CGGlyph
    let topLeftTexCoord: CGPoint
    let bottomRightTexCoord: CGPoint
    
    init(glyphIndex: CGGlyph, topLeftTexCoord: CGPoint, bottomRightTexCoord: CGPoint) {
        self.glyphIndex = glyphIndex
        self.topLeftTexCoord = topLeftTexCoord
        self.bottomRightTexCoord = bottomRightTexCoord
    }
    required init(coder aDecoder: NSCoder) {
        glyphIndex = CGGlyph(aDecoder.decodeInteger(forKey: "GlyphIndex"))
        topLeftTexCoord = aDecoder.decodeCGPoint(forKey: "TopLeftTexCoord")
        bottomRightTexCoord = aDecoder.decodeCGPoint(forKey: "BottomRightTexCoord")
    }
    func encode(with aCoder: NSCoder) {
        aCoder.encode(Int(glyphIndex), forKey: "GlyphIndex")
        aCoder.encode(topLeftTexCoord, forKey: "TopLeftTexCoord")
        aCoder.encode(bottomRightTexCoord, forKey: "BottomRightTexCoord")
    }
}

public class FontAtlas: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { get { return true } }
    
    static let atlasSize: Int = 2048 //Texture.maxSize
    var glyphs : [GlyphDescriptor] = []
    let parentFont: UIFont
    var fontPointSize: CGFloat
    let textureSize: Int
    var textureData: [UInt8] = []
    private var _fontTexture: MTLTexture!
    public var fontTexture: MTLTexture {
        get {
            return _fontTexture
        }
    }
    
    /// If the FontAtlas has been created before, it will attempt to load it from disk
    public static func createFontAtlas(font: UIFont, textureSize: Int) throws -> FontAtlas {
        let candidates = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        if let documentsPath = candidates.first {
            let dirUrl = URL(fileURLWithPath: documentsPath, isDirectory: true)
            let fontUrl = dirUrl.appendingPathComponent(font.fontName).appendingPathExtension("sdff")
            print(fontUrl)
            if let fontAtlas = NSKeyedUnarchiver.unarchiveObject(withFile: fontUrl.path) as? FontAtlas {
                return fontAtlas
            }
            // cache miss
            let fontAtlas = try FontAtlas(font: font, textureSize: textureSize)
            // @todo archive! At the moment, it runs out of memory...
            //NSKeyedArchiver.archiveRootObject(fontAtlas, toFile: fontUrl.path)
            return fontAtlas
        } else {
            NSLog("Failed to get documentsPath. Can't cache the texture.")
            return try FontAtlas(font: font, textureSize: textureSize)
        }
    }
    
    public init(font: UIFont, textureSize: Int) throws {
        self.parentFont = font
        self.textureSize = textureSize
        if textureSize > FontAtlas.atlasSize {
            throw TextureError.ExceededMaxTextureSize
        }
        if (FontAtlas.atlasSize % textureSize) != 0 {
            throw TextureError.UnsupportedSize
        }
        fontPointSize = font.pointSize
        super.init()
        createTextureData()
        do {
            _fontTexture = try createTexture(device: RenderManager.sharedInstance.device)
        }
    }
    
    required public init?(coder aDecoder: NSCoder) {
        guard let fontName = aDecoder.decodeObject(forKey: "FontName") as? String else {
            NSLog("Invalid font name")
            return nil
        }
        fontPointSize = CGFloat(aDecoder.decodeFloat(forKey: "FontSize"))
        if fontPointSize <= 0 {
            NSLog("Invalid font size")
            return nil
        }
        guard let font = UIFont(name: fontName, size: fontPointSize) else {
            NSLog("Invalid font: \(fontName):\(fontPointSize)")
            return nil
        }
        parentFont = font
        textureSize = aDecoder.decodeInteger(forKey: "TextureSize")
        if textureSize <= 0 {
            NSLog("Invalid texture size")
            return nil
        }
        guard let gd = aDecoder.decodeObject(forKey: "GlyphDescriptors") as? [GlyphDescriptor] else {
            NSLog("Invalid glyph descriptors")
            return nil
        }
        glyphs = gd
        guard let td = aDecoder.decodeObject(forKey: "TextureData") as? [UInt8] else {
            NSLog("Texture data is empty")
            return nil
        }
        textureData = td
        super.init()
        do {
            guard let texture = try? createTexture(device: RenderManager.sharedInstance.device) else {
                NSLog("Failed to create texture")
                return nil
            }
            _fontTexture = texture
        }
    }
    public func encode(with aCoder: NSCoder) {
        aCoder.encode(parentFont.fontName, forKey: "FontName")
        aCoder.encode(fontPointSize, forKey: "FontSize")
        aCoder.encode(textureData, forKey: "TextureData")
        aCoder.encode(textureSize, forKey: "TextureSize")
        aCoder.encode(glyphs, forKey: "GlyphDescriptors")
    }
    
    func createTexture(device: MTLDevice) throws -> MTLTexture {
        if textureData.count != textureSize * textureSize {
            throw FontAtlasError.AtlasNotProperlyInitialized
        }
        let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: textureSize, height: textureSize, mipmapped: false)
        let texture = device.makeTexture(descriptor: texDescriptor)
        let region = MTLRegionMake2D(0, 0, textureSize, textureSize)
        texture.replace(region: region, mipmapLevel: 0, withBytes: textureData, bytesPerRow: textureSize)
        return texture
    }
    
    private func createTextureData() {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: 0) //[CGBitmapInfo.alphaInfoMask, CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)]
        guard let context = CGContext(data: nil,
                                      width: FontAtlas.atlasSize, height: FontAtlas.atlasSize, bitsPerComponent: 8,
                                      bytesPerRow: FontAtlas.atlasSize, space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue) else {
                                        return
        }
        // Generate an atlas image for the font, resizing if necessary to fit in the specified size.
        createAtlasForFont(context: context, font: parentFont, width:FontAtlas.atlasSize, height:FontAtlas.atlasSize)
        guard let atlasData = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        // Create the signed-distance field representation of the font atlas from the rasterized glyph image.
        let distanceField = createSignedDistanceFieldForGrayscaleImage(imageData: atlasData, width: FontAtlas.atlasSize, height: FontAtlas.atlasSize)
        //let distanceField = [Float](repeating: 1.0, count: FontAtlas.atlasSize * FontAtlas.atlasSize)
        // Downsample the signed-distance field to the expected texture resolution
        let scaleFactor = FontAtlas.atlasSize / self.textureSize
        guard let scaledField = try? createResampledData(distanceField, width: FontAtlas.atlasSize, height: FontAtlas.atlasSize, scaleFactor: scaleFactor) else {
            return
        }
        let spread = Float(estimatedLineWidthForFont(parentFont) * 0.5)
        // Quantize the downsampled distance field into an 8-bit grayscale array suitable for use as a texture
        textureData = createQuantizedDistanceField(scaledField, width: textureSize, height: textureSize, normalizationFactor: spread)
    }
    
    private func createAtlasForFont(context: CGContext, font: UIFont, width: Int, height: Int) {
        // Turn off antialiasing so we only get fully-on or fully-off pixels.
        // This implicitly disables subpixel antialiasing and hinting.
        context.setAllowsAntialiasing(false)
        // Flip context coordinate space so y increases downward
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // Fill the context with an opaque black color
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.fill(fullRect)
        
        fontPointSize = pointSizeThatFitsForFont(font, rect:CGRect(x: 0, y: 0, width: width, height: height))
        let ctFont = CTFontCreateWithName(font.fontName as CFString, fontPointSize, nil)
        guard let parentFont = UIFont(name: font.fontName, size: fontPointSize) else {
            // should throw an exception
            return
        }
        let fontGlyphCount = CTFontGetGlyphCount(ctFont)
        let glyphMargin = estimatedLineWidthForFont(parentFont)
        // Set fill color so that glyphs are solid white
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        glyphs.removeAll()
        let fontAscent = CTFontGetAscent(ctFont)
        let fontDescent = CTFontGetDescent(ctFont)
        var origin = CGPoint(x: 0, y: fontAscent)
        var maxYCoordForLine :CGFloat = -1
        for i in 0..<fontGlyphCount {
            var glyph = CGGlyph(i)
            var boundingRect = CGRect()
            CTFontGetBoundingRectsForGlyphs(ctFont, CTFontOrientation.horizontal, &glyph, &boundingRect, 1)
            if origin.x + boundingRect.maxX + glyphMargin > CGFloat(width) {
                origin.x = 0
                origin.y = maxYCoordForLine + glyphMargin + fontDescent
                maxYCoordForLine = -1
            }
            if origin.y + boundingRect.maxY > maxYCoordForLine {
                maxYCoordForLine = origin.y + boundingRect.maxY
            }
            let glyphOriginX = origin.x - boundingRect.origin.x + 0.5 * glyphMargin
            let glyphOriginY = origin.y + glyphMargin * 0.5
            var glyphTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: glyphOriginX, ty: glyphOriginY)
            guard let path = CTFontCreatePathForGlyph(ctFont, glyph, &glyphTransform) else {
                continue
            }
            context.addPath(path)
            context.fillPath()
            var glyphPathBoundingRect = path.boundingBox
            // The null rect (i.e., the bounding rect of an empty path) is problematic
            // because it has its origin at (+inf, +inf); we fix that up here
            if glyphPathBoundingRect.equalTo(CGRect.null) {
                glyphPathBoundingRect = CGRect.zero
            }
            let texCoordLeft = glyphPathBoundingRect.origin.x / CGFloat(width)
            let texCoordRight = (glyphPathBoundingRect.origin.x + glyphPathBoundingRect.size.width) / CGFloat(width)
            let texCoordTop = (glyphPathBoundingRect.origin.y) / CGFloat(height)
            let texCoordBottom = (glyphPathBoundingRect.origin.y + glyphPathBoundingRect.size.height) / CGFloat(height)
            let descriptor = GlyphDescriptor(
                glyphIndex: glyph,
                topLeftTexCoord: CGPoint(x: texCoordLeft, y: texCoordTop),
                bottomRightTexCoord: CGPoint(x: texCoordRight, y: texCoordBottom))
            glyphs.append(descriptor)
            origin.x += boundingRect.width + glyphMargin
        }
    }
    
    private func pointSizeThatFitsForFont(_ font: UIFont, rect: CGRect) -> CGFloat {
        var fittedSize = font.pointSize
        while isLikelyToFit(font: font, size: fittedSize, rect: rect) {
            fittedSize += 1
        }
        while !isLikelyToFit(font: font, size: fittedSize, rect: rect) {
            fittedSize -= 1
        }
        return fittedSize
    }
    
    private func isLikelyToFit(font: UIFont, size: CGFloat, rect: CGRect) -> Bool {
        let textureArea = rect.size.width * rect.size.height
        guard let trialFont = UIFont(name: font.fontName, size: size) else {
            return false
        }
        let trialCTFont = CTFontCreateWithName(font.fontName as CFString, size, nil)
        let fontGlyphCount = CTFontGetGlyphCount(trialCTFont)
        let glyphMargin = self.estimatedLineWidthForFont(trialFont)
        let averageGlyphSize = self.estimatedGlyphSizeForFont(trialFont)
        let estimatedGlyphTotalArea = (averageGlyphSize.width + glyphMargin) * (averageGlyphSize.height + glyphMargin) * CGFloat(fontGlyphCount)
        return (estimatedGlyphTotalArea < textureArea)
    }
    
    private func estimatedLineWidthForFont(_ font: UIFont) -> CGFloat {
        let myString = "!" as NSString
        let size: CGSize = myString.size(attributes: [NSFontAttributeName: font])
        let estimatedStrokeWidth = Float(size.width)
        return CGFloat(ceilf(estimatedStrokeWidth))
    }
    
    private func estimatedGlyphSizeForFont(_ font: UIFont) -> CGSize {
        let exemplarString = "{ǺOJMQYZa@jmqyw" as NSString
        let exemplarStringSize = exemplarString.size(attributes: [NSFontAttributeName: font ])
        let averageGlyphWidth = ceilf(Float(exemplarStringSize.width) / Float(exemplarString.length))
        let maxGlyphHeight = ceilf(Float(exemplarStringSize.height))
        return CGSize(width: CGFloat(averageGlyphWidth), height: CGFloat(maxGlyphHeight))
    }
    
    /// Compute signed-distance field for an 8-bpp grayscale image (values greater than 127 are considered "on")
    /// For details of this algorithm, see "The 'dead reckoning' signed distance transform" [Grevera 2004]
    private func createSignedDistanceFieldForGrayscaleImage(imageData: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> [Float] {
        let maxDist = hypot(Float(width), Float(height))
        // Initialization phase
        // distance to nearest boundary point map - set all distances to "infinity"
        var distanceMap = [Float](repeating: maxDist, count: width * height)
        // nearest boundary point map - zero out nearest boundary point map
        var boundaryPointMap = [int2](repeating: int2(0,0), count: width * height)
        let distUnit :Float = 1
        let distDiag :Float = sqrtf(2)
        // Immediate interior/exterior phase: mark all points along the boundary as such
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let inside = imageData[y * width + x] > 0x7f
                if (imageData[y * width + x - 1] > 0x7f) != inside
                    || (imageData[y * width + x + 1] > 0x7f) != inside
                    || (imageData[(y - 1) * width + x] > 0x7f) != inside
                    || (imageData[(y + 1) * width + x] > 0x7f) != inside {
                    distanceMap[y * width + x] = 0
                    boundaryPointMap[y * width + x].x = Int32(x)
                    boundaryPointMap[y * width + x].y = Int32(y)
                }
            }
        }
        // Forward dead-reckoning pass
        for y in 1..<(height-2) {
            for x in 1..<(width-2) {
                let d = distanceMap[y * width + x]
                let n = boundaryPointMap[y * width + x]
                let h = hypot(Float(x) - Float(n.x), Float(y) - Float(n.y))
                if distanceMap[(y - 1) * width + x - 1] + distDiag < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[(y - 1) * width + (x - 1)]
                    distanceMap[y * width + x] = h
                }
                if distanceMap[(y - 1) * width + x] + distUnit < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[(y - 1) * width + x]
                    distanceMap[y * width + x] = h
                }
                if distanceMap[(y - 1) * width + x + 1] + distDiag < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[(y - 1) * width + (x + 1)]
                    distanceMap[y * width + x] = h
                }
                if distanceMap[y * width + x - 1] + distUnit < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[y * width + (x - 1)]
                    distanceMap[y * width + x] = h
                }
            }
        }
        // Backward dead-reckoning pass
        for y in (1...(height-2)).reversed() {
            for x in (1...(width-2)).reversed() {
                let d = distanceMap[y * width + x]
                let n = boundaryPointMap[y * width + x]
                let h = hypot(Float(x) - Float(n.x), Float(y) - Float(n.y))
                if distanceMap[y * width + x + 1] + distUnit < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[y * width + x + 1]
                    distanceMap[y * width + x] = h
                }
                if distanceMap[(y + 1) * width + x - 1] + distDiag < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[(y + 1) * width + x - 1]
                    distanceMap[y * width + x] = h
                }
                if distanceMap[(y + 1) * width + x] + distUnit < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[(y + 1) * width + x]
                    distanceMap[y * width + x] = h
                }
                if distanceMap[(y + 1) * width + x + 1] + distDiag < d {
                    boundaryPointMap[y * width + x] = boundaryPointMap[(y + 1) * width + x + 1]
                    distanceMap[y * width + x] = h
                }
            }
        }
        // Interior distance negation pass; distances outside the figure are considered negative
        for y in 0..<height {
            for x in 0..<width {
                if imageData[y * width + x] <= 0x7f {
                    distanceMap[y * width + x] = -distanceMap[y * width + x]
                }
            }
        }
        return distanceMap
    }
    
    private func createResampledData(_ inData: [Float], width: Int, height: Int, scaleFactor: Int) throws -> [Float] {
        if width % scaleFactor != 0 || height % scaleFactor != 0 {
            // Scale factor does not evenly divide width and height of source distance field
            throw FontAtlasError.UnsupportedTextureSize
        }
        let scaledWidth = width / scaleFactor
        let scaledHeight = height / scaleFactor
        var outData = [Float](repeating: 0, count: scaledWidth * scaledHeight)
        for y in stride(from: 0, to: height, by: scaleFactor) {
            for x in stride(from: 0, to: width, by: scaleFactor) {
                var accum :Float = 0
                for ky in 0..<scaleFactor {
                    for kx in 0..<scaleFactor {
                        accum += inData[(y + ky) * width + (x + kx)]
                    }
                }
                accum = accum / Float(scaleFactor * scaleFactor)
                outData[(y / scaleFactor) * scaledWidth + (x / scaleFactor)] = accum
            }
        }
        return outData
    }
    
    private func createQuantizedDistanceField(_ inData: [Float], width: Int, height: Int, normalizationFactor: Float) -> [UInt8] {
        var outData = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dist = inData[y * width + x]
                let clampDist = fmaxf(-normalizationFactor, fminf(dist, normalizationFactor))
                let scaledDist = clampDist / normalizationFactor
                let value = ((scaledDist + 1) / 2) * Float(UInt8.max)
                outData[y * width + x] = UInt8(value)
            }
        }
        return outData
    }
}