import AppKit
import CoreGraphics
let a=CommandLine.arguments
let string=a[1], size=CGFloat(Double(a[2])!), hex=UInt32(a[3],radix:16)!, bold=a[4]=="1", latin=a[5]=="1", tracking=CGFloat(Double(a[6])!)
let font: NSFont = a[5] == "2" ? .monospacedSystemFont(ofSize:size,weight:bold ? .semibold:.regular) : latin ? .systemFont(ofSize:size,weight:bold ? .semibold:.regular) : NSFont(name:bold ? "PingFangSC-Semibold":"PingFangSC-Regular",size:size)!
let color=NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)
let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=size*0.12
let text=NSAttributedString(string:string,attributes:[.font:font,.foregroundColor:color,.kern:tracking,.paragraphStyle:paragraph])
let rect=text.boundingRect(with:NSSize(width:5000,height:3000),options:[.usesLineFragmentOrigin,.usesFontLeading])
let w=Int(ceil(rect.width))+10,h=Int(ceil(rect.height))+10
let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
text.draw(in:NSRect(x:5,y:5,width:w-10,height:h-10));NSGraphicsContext.restoreGraphicsState()
let rep=NSBitmapImageRep(cgImage:context.makeImage()!);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:a[7]))
