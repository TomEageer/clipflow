import AppKit; import Vision; import Foundation
func mk(_ w:Int,_ h:Int,_ tp:CGFloat)->CGImage{
    let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray:0.13,alpha:1)); c.fill(CGRect(x:0,y:0,width:w,height:h))
    let n=NSGraphicsContext(cgContext:c,flipped:false); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=n
    let f=NSFont(name:"Menlo",size:tp)!; var y=CGFloat(h)-tp*2; var k=0
    while y>tp { NSAttributedString(string:"\(k): 订单支付回调幂等 orderId=2606\(String(format:"%08d",k)) status=PAID",
        attributes:[.font:f,.foregroundColor:NSColor(calibratedWhite:0.92,alpha:1)]).draw(at:NSPoint(x:24,y:y)); y-=tp*1.7; k+=1 }
    NSGraphicsContext.restoreGraphicsState(); return c.makeImage()!
}
func ocr(_ c:CGImage,_ l:VNRequestTextRecognitionLevel)->(Int,Double){
    let r=VNRecognizeTextRequest(); r.recognitionLevel=l; r.recognitionLanguages=["zh-Hans","en-US"]; r.usesLanguageCorrection=true
    let t=CFAbsoluteTimeGetCurrent(); try? VNImageRequestHandler(cgImage:c,options:[:]).perform([r])
    return (r.results?.count ?? 0,(CFAbsoluteTimeGetCurrent()-t)*1000)
}
@main struct M { static func main() {
    print("=== 冷启动：全新进程的首次 accurate 调用 ===")
    let t0=CFAbsoluteTimeGetCurrent(); let w=ocr(mk(600,200,26), .accurate)
    print("   首次: \(String(format:"%.0f",(CFAbsoluteTimeGetCurrent()-t0)*1000))ms  \(w.0)块")
    for i in 2...3 { let r=ocr(mk(600,200,26), .accurate); print("   第\(i)次: \(String(format:"%.0f",r.1))ms  \(r.0)块") }

    print("\n=== 第三条约束：同样 5.4MP，只变长宽比 ===")
    print("   尺寸           宽高比   accurate      fast")
    for (w,h) in [(6912,782),(4800,1125),(3600,1500),(2700,2000),(2325,2325),(2000,2700),(1500,3600)] {
        let img=mk(w,h,30); let a=ocr(img, .accurate); let b=ocr(img, .fast)
        let mp=Double(w*h)/1e6
        print("   \(w)×\(h)".padding(toLength:15,withPad:" ",startingAt:0)
            + String(format:"%.1f:1",Double(w)/Double(h)).padding(toLength:9,withPad:" ",startingAt:0)
            + "\(a.0)块 \(String(format:"%.0f",a.1))ms".padding(toLength:14,withPad:" ",startingAt:0)
            + "\(b.0)块 \(String(format:"%.0f",b.1))ms"
            + (a.0==0 ? "  ← 空! (\(String(format:"%.1f",mp))MP)" : ""))
    }
    print("\n=== 单边长度上限？固定高 1000，只变宽 ===")
    for w in [3000,3500,4000,4096,4200,5000,6000] {
        let a=ocr(mk(w,1000,30), .accurate)
        print("   \(w)×1000  (\(String(format:"%.1f",Double(w)/1000.0))MP)  accurate \(a.0)块" + (a.0==0 ? "  ← 空!" : ""))
    }
}}
