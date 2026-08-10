import AppKit; import Vision; import VisionKit; import Foundation
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
@main struct M { static func main() async {
    let az = ImageAnalyzer(); var cfg = ImageAnalyzer.Configuration([.text]); cfg.locales=["zh-Hans","en-US"]
    func run(_ c:CGImage) async -> (Int,Double) {
        let t=CFAbsoluteTimeGetCurrent()
        let a = try? await az.analyze(c, orientation:.up, configuration:cfg)
        return (a?.transcript.count ?? 0,(CFAbsoluteTimeGetCurrent()-t)*1000)
    }
    _ = await run(mk(400,300,26))   // 预热

    print("=== ImageAnalyzer 的安全区（对照 VN accurate 的 <2:1 且 ≤6.4MP）===")
    print("   尺寸           MP    宽高比   ImageAnalyzer")
    for (w,h) in [(3200,2000),(4000,2250),(3600,1500),(4800,2700),(6912,782),(1500,3600),(5600,3150),(6912,4468)] {
        let r = await run(mk(w,h,30))
        print("   \(w)×\(h)".padding(toLength:15,withPad:" ",startingAt:0)
            + String(format:"%.1f",Double(w*h)/1e6).padding(toLength:6,withPad:" ",startingAt:0)
            + String(format:"%.1f:1",Double(w)/Double(h)).padding(toLength:9,withPad:" ",startingAt:0)
            + "\(r.0)字 \(String(format:"%.0f",r.1))ms" + (r.0==0 ? "  ← 空!" : ""))
    }

    print("\n=== 30.9MP 全屏图：三种方案对比 ===")
    let big = mk(6912,4468,30)
    let d = await run(big); print("   ImageAnalyzer 直出      \(d.0)字 \(String(format:"%.0f",d.1))ms")
    var chars=0; let t0=CFAbsoluteTimeGetCurrent()
    for cx in 0..<3 { for cy in 0..<2 {
        if let s = big.cropping(to: CGRect(x:cx*2304,y:cy*2234,width:2304,height:2234)) {
            let r = await run(s); chars += r.0 } } }
    print("   ImageAnalyzer 3×2 切块  \(chars)字 \(String(format:"%.0f",(CFAbsoluteTimeGetCurrent()-t0)*1000))ms")
    let vr=VNRecognizeTextRequest(); vr.recognitionLevel = .accurate; vr.recognitionLanguages=["zh-Hans","en-US"]
    var vc=0; let t1=CFAbsoluteTimeGetCurrent()
    for cx in 0..<3 { for cy in 0..<2 {
        if let s = big.cropping(to: CGRect(x:cx*2304,y:cy*2234,width:2304,height:2234)) {
            try? VNImageRequestHandler(cgImage:s,options:[:]).perform([vr])
            vc += (vr.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined().count } } }
    print("   VN accurate 3×2 切块    \(vc)字 \(String(format:"%.0f",(CFAbsoluteTimeGetCurrent()-t1)*1000))ms")
}}
