import OvertimeAppSupport
import Testing

struct MotionTests {
  @Test func theFourTransitionsHaveTheirDurations() {
    #expect(MotionTransition.allCases == [.rowHighlight, .statusGlyph, .onboardingStep, .panelClose])
    #expect(Motion.duration(.rowHighlight, reduceMotion: false) == 0.15)
    #expect(Motion.duration(.statusGlyph, reduceMotion: false) == 0.2)
    #expect(Motion.duration(.onboardingStep, reduceMotion: false) == 0.25)
    #expect(Motion.duration(.panelClose, reduceMotion: false) == 0.15)
  }

  @Test func reduceMotionRemovesEveryTransition() {
    #expect(MotionTransition.allCases.count == 4)
    for transition in MotionTransition.allCases {
      #expect(Motion.duration(transition, reduceMotion: true) == nil, "\(transition)")
    }
  }

  @Test func aCloseMayOrderOutWhenNothingHappenedSince() {
    var fade = PanelFade()
    let token = fade.beginClose()
    #expect(fade.mayOrderOut(token))
  }

  @Test func onlyTheLatestCloseMayOrderOut() {
    var fade = PanelFade()
    let first = fade.beginClose()
    let second = fade.beginClose()
    #expect(first != second)
    #expect(!fade.mayOrderOut(first))
    #expect(fade.mayOrderOut(second))
    fade.present()
    let third = fade.beginClose()
    #expect(third != second)
    #expect(!fade.mayOrderOut(second))
    #expect(fade.mayOrderOut(third))
  }

  @Test func aPresentDuringTheFadeCancelsTheOrderOut() {
    var fade = PanelFade()
    let token = fade.beginClose()
    fade.present()
    #expect(!fade.mayOrderOut(token))
    fade.present()
    #expect(!fade.mayOrderOut(token))
    #expect(!PanelFade().mayOrderOut(token))
  }
}
