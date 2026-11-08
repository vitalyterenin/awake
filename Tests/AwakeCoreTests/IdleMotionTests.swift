import Testing
import CoreGraphics
@testable import AwakeCore

@Test func fiveMinuteBoundaryAndSyntheticEvents() {
    var motion = IdleMotion(now: 10)
    #expect(!motion.isReady(at: 309.999))
    #expect(motion.isReady(at: 310))
    motion.activity(at: 311, marker: IdleMotion.eventMarker)
    #expect(motion.isReady(at: 311))
    motion.activity(at: 312)
    #expect(!motion.isReady(at: 611.999))
    #expect(motion.isReady(at: 612))
}

@Test func oneMinuteBoundaryAndDelayChangeReset() {
    var motion = IdleMotion(now: 10, delay: .oneMinute)
    #expect(!motion.isReady(at: 69.999))
    #expect(motion.isReady(at: 70))
    motion.begin(at: 70, pointer: CGPoint(x: 600, y: 400),
                 display: CGRect(x: 0, y: 0, width: 1440, height: 900))
    motion.setDelay(.fiveMinutes, at: 75)
    #expect(motion.point(at: 75) == nil)
    #expect(!motion.isReady(at: 374.999))
    #expect(motion.isReady(at: 375))
    motion.setDelay(.oneMinute, at: 80)
    motion.activity(at: 100, marker: IdleMotion.eventMarker)
    #expect(!motion.isReady(at: 139.999))
    #expect(motion.isReady(at: 140))
    #expect(MotionDelay.allCases.map(\.rawValue) == [1, 5])
    #expect(MotionDelay(rawValue: 0) == nil)
}

@Test func smoothCircleAndImmediateInputStop() {
    var motion = IdleMotion(now: 0)
    let pointer = CGPoint(x: 600, y: 400)
    motion.begin(at: 300, pointer: pointer, display: CGRect(x: 0, y: 0, width: 1440, height: 900))
    #expect(abs(motion.point(at: 300)!.x - pointer.x) < 0.0001)
    #expect(abs(motion.point(at: 300)!.y - pointer.y) < 0.0001)
    #expect(abs(motion.point(at: 300 + IdleMotion.period)!.x - pointer.x) < 0.0001)
    #expect(hypot(motion.point(at: 300.033)!.x - pointer.x,
                  motion.point(at: 300.033)!.y - pointer.y) < 0.1)
    motion.activity(at: 305)
    #expect(motion.point(at: 305) == nil)
}

@Test func displayEdgesAndNegativeCoordinates() {
    for display in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                    CGRect(x: -1920, y: -1080, width: 1920, height: 1080)] {
        for p in [CGPoint(x: display.minX, y: display.minY),
                  CGPoint(x: display.maxX - 1, y: display.maxY - 1),
                  CGPoint(x: display.midX, y: display.minY),
                  CGPoint(x: display.minX, y: display.midY)] {
            var motion = IdleMotion(now: 0)
            motion.begin(at: 300, pointer: p, display: display)
            #expect(hypot(motion.point(at: 300)!.x - p.x, motion.point(at: 300)!.y - p.y) < 0.001)
            for i in 0...720 {
                let point = motion.point(at: 300 + Double(i) / 30)!
                #expect(display.contains(point))
                #expect(hypot(point.x - p.x, point.y - p.y) <= 35)
            }
        }
    }
}

@Test func completeCircleAtCornerWithoutFlatClippedSegments() {
    var motion = IdleMotion(now: 0)
    motion.begin(at: 60, pointer: .zero, display: CGRect(x: 0, y: 0, width: 1440, height: 900))
    let start = 60 + IdleMotion.entranceDuration
    let points = (0..<240).map { motion.point(at: start + Double($0) * IdleMotion.period / 240)! }
    for i in 1..<points.count {
        let step = hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
        #expect(step > 0.3 && step < 0.32)
    }
}
