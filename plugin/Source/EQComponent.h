#pragma once
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_dsp/juce_dsp.h>
#include "PluginProcessor.h"

// Interactive EQ surface in the Tidal envelope idiom: glowing cyan response
// curve over a faint grid, draggable node dots, double-click adds, right-click
// removes, wheel shapes Q. Selection feeds the precision fader row below.
class EQComponent : public juce::Component
{
public:
    explicit EQComponent (ResonanceAudioProcessor&);

    void paint (juce::Graphics&) override;
    void mouseDown (const juce::MouseEvent&) override;
    void mouseDrag (const juce::MouseEvent&) override;
    void mouseUp (const juce::MouseEvent&) override;
    void mouseDoubleClick (const juce::MouseEvent&) override;
    void mouseWheelMove (const juce::MouseEvent&, const juce::MouseWheelDetails&) override;

    void refreshIfChanged();               // editor timer: repaint on parameter movement
    int  getSelectedBand() const noexcept  { return selected; }
    void setSelectedBand (int band);

    std::function<void (int)> onSelectBand;

private:
    static constexpr float kMinFreq = 20.0f, kMaxFreq = 20000.0f, kDbSpan = 18.0f;

    juce::Rectangle<float> graphArea() const;
    float freqToX (float hz) const;
    float xToFreq (float px) const;
    float gainToY (float db) const;
    float yToGain (float py) const;
    bool  bandUsesGain (int type) const noexcept { return type == ResonanceEngine::LowShelf
                                                       || type == ResonanceEngine::Bell
                                                       || type == ResonanceEngine::HighShelf; }

    float bandValue (int band, const char* suffix) const;
    void  setBandValue (int band, const char* suffix, float value);
    void  beginGesture (int band, const char* suffix);
    void  endGesture (int band, const char* suffix);

    juce::Point<float> nodeCentre (int band) const;
    int hitNode (juce::Point<float>) const;

    void rebuildCurve();
    double magnitudeAt (double freq) const;
    juce::uint64 paramFingerprint() const;

    ResonanceAudioProcessor& proc;
    int selected = 2;
    int dragBand = -1;
    juce::Path curve;
    juce::uint64 lastFingerprint = 0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (EQComponent)
};
