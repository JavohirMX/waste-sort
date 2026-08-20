import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

@Suite("AprilTag range profile and quad validation Tests")
struct AprilTagRangeProfileTests {
    private func square(side: CGFloat, at origin: CGPoint = .zero) -> [CGPoint] {
        [
            origin,
            CGPoint(x: origin.x + side, y: origin.y),
            CGPoint(x: origin.x + side, y: origin.y + side),
            CGPoint(x: origin.x, y: origin.y + side)
        ]
    }

    @Test("Long-range profiles scan at full resolution")
    func longRangeProfilesDoNotDecimate() {
        // Decimation is what put the previous build below the decode floor: a tag spanning
        // 23 px at 720p became 11 px, under 2 px per tag16h5 cell.
        #expect(AprilTagRangeProfile.far.tuning.quadDecimate == 1.0)
        #expect(AprilTagRangeProfile.veryFar.tuning.quadDecimate == 1.0)
    }

    @Test("Long-range profiles never pre-blur the frame")
    func longRangeProfilesDoNotBlur() {
        #expect(AprilTagRangeProfile.far.tuning.quadSigma <= 0)
        #expect(AprilTagRangeProfile.veryFar.tuning.quadSigma <= 0)
    }

    @Test("Longer range trades margin for reach, never Hamming correction")
    func marginsRelaxWithRangeButHammingDoesNot() {
        let near = AprilTagRangeProfile.near.tuning
        let far = AprilTagRangeProfile.far.tuning
        let veryFar = AprilTagRangeProfile.veryFar.tuning

        #expect(near.minDecisionMargin > far.minDecisionMargin)
        #expect(far.minDecisionMargin > veryFar.minDecisionMargin)

        // tag16h5 codes sit only 5 bits apart, so a corrected decode is never trustworthy.
        for tuning in [near, far, veryFar] {
            #expect(tuning.maxHamming == 0)
            #expect(tuning.strongMargin > tuning.minDecisionMargin)
            #expect(tuning.instantTrustMargin > tuning.strongMargin)
        }
    }

    @Test("Every profile offers a fallback preset chain")
    func presetChainsHaveFallbacks() {
        for profile in AprilTagRangeProfile.allCases {
            #expect(profile.captureSessionPresets.count >= 2)
        }
        #expect(AprilTagRangeProfile.far.captureSessionPresets.first == .hd1920x1080)
        #expect(AprilTagRangeProfile.veryFar.captureSessionPresets.first == .hd4K3840x2160)
    }

    @Test("A clean square passes quad validation")
    func acceptsCleanSquare() {
        let tuning = AprilTagRangeProfile.far.tuning
        #expect(AprilTagDetector.isPlausibleQuad(square(side: 40), tuning: tuning))
    }

    @Test("Quads smaller than the decode floor are rejected")
    func rejectsSpecks() {
        let tuning = AprilTagRangeProfile.far.tuning
        #expect(!AprilTagDetector.isPlausibleQuad(square(side: 4), tuning: tuning))
    }

    @Test("Slivers are rejected")
    func rejectsSlivers() {
        let tuning = AprilTagRangeProfile.far.tuning
        let sliver = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 200, y: 0),
            CGPoint(x: 200, y: 12),
            CGPoint(x: 0, y: 12)
        ]
        #expect(!AprilTagDetector.isPlausibleQuad(sliver, tuning: tuning))
    }

    @Test("Self-intersecting quads are rejected")
    func rejectsBowtie() {
        let tuning = AprilTagRangeProfile.far.tuning
        let bowtie = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 40, y: 40),
            CGPoint(x: 40, y: 0),
            CGPoint(x: 0, y: 40)
        ]
        #expect(!AprilTagDetector.isPlausibleQuad(bowtie, tuning: tuning))
    }

    @Test("An obliquely viewed tag still passes")
    func acceptsPerspectiveSkew() {
        // Tags sit on bin lids and are routinely seen from a steep angle.
        let tuning = AprilTagRangeProfile.far.tuning
        let skewed = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 60, y: 8),
            CGPoint(x: 56, y: 34),
            CGPoint(x: 4, y: 26)
        ]
        #expect(AprilTagDetector.isPlausibleQuad(skewed, tuning: tuning))
    }

    @Test("Quads without exactly four corners are rejected")
    func rejectsWrongCornerCount() {
        let tuning = AprilTagRangeProfile.far.tuning
        #expect(!AprilTagDetector.isPlausibleQuad([], tuning: tuning))
        #expect(!AprilTagDetector.isPlausibleQuad(Array(square(side: 40).prefix(3)), tuning: tuning))
    }
}
