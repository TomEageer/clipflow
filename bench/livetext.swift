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
func vn(_ c:CGImage,_ l:VNRequestTextRecognitionLevel)->(Int,Int,Double){
    let r=VNRecognizeTextRequest(); r.recognitionLevel=l; r.recognitionLanguages=["zh-Hans","en-US"]; r.usesLanguageCorrection=true
    let t=CFAbsoluteTimeGetCurrent(); try? VNImageRequestHandler(cgImage:c,options:[:]).perform([r])
    let o=r.results ?? []
    return (o.count,o.compactMap{$0.topCandidates(1).first?.string}.joined().count,(CFAbsoluteTimeGetCurrent()-t)*1000)
}

@main struct M { static func main() async {
    print("=== VisionKit ImageAnalyzer（Live Text · 预览用的那套）可用性 ===")
    print("   ImageAnalyzer.isSupported = \(ImageAnalyzer.isSupported)")
    print("   支持语言数 = \(ImageAnalyzer.supportedTextRecognitionLanguages.count)")
    print("   含 zh-Hans = \(ImageAnalyzer.supportedTextRecognitionLanguages.contains("zh-Hans"))")

    let analyzer = ImageAnalyzer()
    var cfg = ImageAnalyzer.Configuration([.text])
    cfg.locales = ["zh-Hans", "en-US"]

    for (w,h,tp,name) in [(1600,900,CGFloat(30),"中图 1.4MP"),
                          (6912,4468,CGFloat(30),"全屏 30.9MP ← VN accurate 在此为 0 块")] {
        let img = mk(w,h,tp)
        print("\n── \(name)  \(w)×\(h)")
        let a = vn(img, .accurate), f = vn(img, .fast)
        print("   VN accurate      \(a.0)块 \(a.1)字 \(String(format:"%.0f",a.2))ms")
        print("   VN fast          \(f.0)块 \(f.1)字 \(String(format:"%.0f",f.2))ms")
        do {
            let t0=CFAbsoluteTimeGetCurrent()
            let an = try await analyzer.analyze(img, orientation: .up, configuration: cfg)
            let ms=(CFAbsoluteTimeGetCurrent()-t0)*1000
            let t = an.transcript
            print("   ImageAnalyzer    \(t.split(separator:"\n").count)行 \(t.count)字 \(String(format:"%.0f",ms))ms  hasResults=\(an.hasResults(for:[.text]))")
            if !t.isEmpty { print("   首行: \(String(t.split(separator:"\n").first ?? "").prefix(64))") }
        } catch { print("   ImageAnalyzer 失败: \(error)") }
    }

    print("\n=== ImageAnalyzer 冷启动/重复调用 ===")
    let small = mk(800,400,28)
    for i in 1...3 {
        let t0=CFAbsoluteTimeGetCurrent()
        if let an = try? await analyzer.analyze(small, orientation:.up, configuration:cfg) {
            print("   第\(i)次 \(String(format:"%.0f",(CFAbsoluteTimeGetCurrent()-t0)*1000))ms  \(an.transcript.count)字")
        }
    }
}}
