import AppKit
import Vision
import Foundation
import Darwin

func pad(_ s: String, _ n: Int) -> String {
    var w = 0
    for ch in s { w += (ch.unicodeScalars.first!.value > 0x2E80) ? 2 : 1 }
    return s + String(repeating: " ", count: max(0, n - w))
}
func f(_ v: Double, _ d: Int = 1, _ w: Int = 0) -> String {
    let s = String(format: "%.\(d)f", v)
    return String(repeating: " ", count: max(0, w - s.count)) + s
}
func i(_ v: Int, _ w: Int) -> String {
    let s = "\(v)"; return String(repeating: " ", count: max(0, w - s.count)) + s
}

func cpuTimeSec() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec)/1e6
         + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec)/1e6
}
func residentMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
}

func render(lines: [String], size: NSSize, fontSize: CGFloat) -> CGImage {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let fnt = NSFont(name: "Menlo", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    var y = size.height - 30
    for t in lines {
        y -= fontSize * 1.6
        if y < 0 { break }
        NSAttributedString(string: t, attributes: [.font: fnt, .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1)])
            .draw(at: NSPoint(x: 24, y: y))
    }
    img.unlockFocus()
    var r = NSRect(origin: .zero, size: size)
    return img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
}

func ocr(_ c: CGImage, level: VNRequestTextRecognitionLevel) -> (blocks: Int, chars: Int) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: c, options: [:]).perform([req])
    let obs = req.results ?? []
    return (obs.count, obs.compactMap { $0.topCandidates(1).first?.string }.joined().count)
}
func mkLines(_ n: Int, seed: Int) -> [String] {
    (0..<n).map { k in
        "\(k): 订单支付回调幂等校验 orderId=2606\(String(format: "%08d", seed*1000+k)) status=PAID 金额 \((k*37)%9999).50 元 trackID=tr\(seed)-\(k)"
    }
}
func lvl(_ l: VNRequestTextRecognitionLevel) -> String { l == .accurate ? "accurate" : "fast" }

print("═══ Clipflow OCR 性能测试 ═══")
print("机器: \(ProcessInfo.processInfo.processorCount) 核 / \(ProcessInfo.processInfo.physicalMemory/1073741824) GB")
print("常驻基线: \(f(residentMB())) MB\n")

_ = ocr(render(lines: ["warmup 预热"], size: NSSize(width: 400, height: 100), fontSize: 20), level: .accurate)
_ = ocr(render(lines: ["warmup 预热"], size: NSSize(width: 400, height: 100), fontSize: 20), level: .fast)

print("── 1. 单张图：墙钟 / CPU 时间 / 内存增量（已预热）")
print("   " + pad("尺寸", 18) + pad("像素", 14) + pad("模式", 10)
      + pad("墙钟", 11) + pad("CPU时间", 11) + pad("CPU/墙钟", 10) + pad("内存增量", 11) + pad("块", 5) + "字")
for (name, sz, nl, fs) in [("小图 800×400", NSSize(width: 800, height: 400), 10, CGFloat(14)),
                           ("中图 1600×900", NSSize(width: 1600, height: 900), 22, CGFloat(14)),
                           ("全屏 3456×2234", NSSize(width: 3456, height: 2234), 45, CGFloat(15))] {
    let img = render(lines: mkLines(nl, seed: 1), size: sz, fontSize: fs)
    for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
        let m0 = residentMB(), c0 = cpuTimeSec(), t0 = CFAbsoluteTimeGetCurrent()
        let r = ocr(img, level: level)
        let wall = (CFAbsoluteTimeGetCurrent()-t0)*1000, cpu = (cpuTimeSec()-c0)*1000
        print("   " + pad(name, 18) + pad("\(img.width)×\(img.height)", 14) + pad(lvl(level), 10)
              + pad(f(wall,1)+"ms", 11) + pad(f(cpu,1)+"ms", 11) + pad(f(cpu/max(wall,0.001),2)+"x", 10)
              + pad(f(residentMB()-m0,1)+"MB", 11) + pad("\(r.blocks)", 5) + "\(r.chars)")
    }
}

print("\n── 2. 批量吞吐：30 张 1600×900 截图串行")
var imgs: [CGImage] = []
for s in 0..<30 { imgs.append(render(lines: mkLines(20, seed: s), size: NSSize(width: 1600, height: 900), fontSize: 14)) }
for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
    let m0 = residentMB(), c0 = cpuTimeSec(), t0 = CFAbsoluteTimeGetCurrent()
    var blocks = 0, chars = 0
    for im in imgs { let r = ocr(im, level: level); blocks += r.blocks; chars += r.chars }
    let wall = CFAbsoluteTimeGetCurrent()-t0, cpu = cpuTimeSec()-c0
    print("   " + pad(lvl(level), 10) + "总 " + f(wall,2,5) + "s   单张均 " + f(wall/30*1000,1,6)
          + "ms   吞吐 " + f(30/wall,1,5) + " 张/s   CPU " + f(cpu,2,5) + "s (" + f(cpu/wall,2) + " 核)   内存增 "
          + f(residentMB()-m0,1,6) + "MB   " + i(blocks,4) + " 块 " + i(chars,6) + " 字")
}

print("\n── 3. 并发收益（30 张 accurate）")
var baseWall = 0.0
for conc in [1, 2, 4, 8] {
    let m0 = residentMB(), c0 = cpuTimeSec(), t0 = CFAbsoluteTimeGetCurrent()
    let sem = DispatchSemaphore(value: conc), group = DispatchGroup()
    let q = DispatchQueue(label: "ocr", attributes: .concurrent)
    for im in imgs { group.enter(); sem.wait(); q.async { _ = ocr(im, level: .accurate); sem.signal(); group.leave() } }
    group.wait()
    let wall = CFAbsoluteTimeGetCurrent()-t0, cpu = cpuTimeSec()-c0
    if conc == 1 { baseWall = wall }
    print("   并发 " + i(conc,2) + "：总 " + f(wall,2,5) + "s   吞吐 " + f(30/wall,1,5)
          + " 张/s   加速 " + f(baseWall/wall,2) + "x   CPU " + f(cpu,2,5) + "s (" + f(cpu/wall,2)
          + " 核)   内存增 " + f(residentMB()-m0,1,6) + "MB")
}

print("\n── 4. 连续 10 张全屏大图，内存是否累积（泄漏检查）")
let base = residentMB()
print("   起始常驻 " + f(base) + " MB")
for k in 1...10 {
    let big = render(lines: mkLines(45, seed: 100+k), size: NSSize(width: 3456, height: 2234), fontSize: 15)
    _ = ocr(big, level: .fast)
    if k % 2 == 0 { print("   第 " + i(k,2) + " 张后：" + f(residentMB()) + " MB（净增 " + f(residentMB()-base) + " MB）") }
}
print("   结束常驻 " + f(residentMB()) + " MB，净增 " + f(residentMB()-base) + " MB")
