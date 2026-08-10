import AppKit; import Vision; import Foundation
func mk(_ w:Int,_ h:Int,_ tp:CGFloat)->CGImage{
    let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray:0.13,alpha:1)); c.fill(CGRect(x:0,y:0,width:w,height:h))
    let n=NSGraphicsContext(cgContext:c,flipped:false); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=n
    let f=NSFont(name:"Menlo",size:tp)!; var y=CGFloat(h)-tp*2; var k=0
    while y>tp { NSAttributedString(string:"\(k): 订单支付回调幂等 orderId=2606\(String(format:"%08d",k)) status=PAID 金额 \(k*37).50 元 trackID=tr-\(k)",
        attributes:[.font:f,.foregroundColor:NSColor(calibratedWhite:0.92,alpha:1)]).draw(at:NSPoint(x:24,y:y)); y-=tp*1.7; k+=1 }
    NSGraphicsContext.restoreGraphicsState(); return c.makeImage()!
}
func ocr(_ c:CGImage,_ l:VNRequestTextRecognitionLevel)->(Int,Int,Double){
    let r=VNRecognizeTextRequest(); r.recognitionLevel=l; r.recognitionLanguages=["zh-Hans","en-US"]; r.usesLanguageCorrection=true
    let t=CFAbsoluteTimeGetCurrent(); try? VNImageRequestHandler(cgImage:c,options:[:]).perform([r])
    let o=r.results ?? []
    return (o.count,o.compactMap{$0.topCandidates(1).first?.string}.joined().count,(CFAbsoluteTimeGetCurrent()-t)*1000)
}
@main struct M { static func main() {
    _ = ocr(mk(400,300,26), .accurate)   // 吃掉冷启动
    print("=== 安全区边界：固定高 2000，只变宽（文字 30px）===")
    for w in [2000,2400,2700,2800,2900,3000,3200] {
        let a=ocr(mk(w,2000,30), .accurate)
        print("   \(w)×2000 (\(String(format:"%.1f",Double(w*2000)/1e6))MP)  \(a.0)块 \(a.1)字" + (a.0==0 ? "  ← 空!" : "  ✅"))
    }
    print("\n=== 竖条切块能否救回 30.9MP 全屏图 ===")
    let big = mk(6912,4468,30)
    let direct = ocr(big, .accurate)
    print("   直出 accurate: \(direct.0)块 \(direct.1)字")
    // 3列×2行 = 6 块，每块 2304×2234 = 5.1MP，宽 2304 在安全区内
    var blocks=0, chars=0; let t0=CFAbsoluteTimeGetCurrent()
    for cx in 0..<3 { for cy in 0..<2 {
        let r=CGRect(x:cx*2304,y:cy*2234,width:2304,height:2234)
        if let sub=big.cropping(to:r){ let o=ocr(sub, .accurate); blocks+=o.0; chars+=o.1 }
    }}
    print("   3×2 竖条切块: \(blocks)块 \(chars)字  总耗时 \(String(format:"%.0f",(CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
    let fastr = ocr(big, .fast)
    print("   对照 fast 直出: \(fastr.0)块 \(fastr.1)字 \(String(format:"%.0f",fastr.2))ms")
}}
