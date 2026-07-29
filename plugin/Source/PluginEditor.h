#pragma once
#include <juce_audio_processors/juce_audio_processors.h>
#include "PluginProcessor.h"
#include "EQComponent.h"

// Soft, fluid, translucent look: rounded arcs, low-opacity fills, glow.
class SoftLNF : public juce::LookAndFeel_V4
{
public:
    SoftLNF();
    void drawRotarySlider (juce::Graphics&, int x, int y, int w, int h,
                           float pos, float startAngle, float endAngle, juce::Slider&) override;
    void drawLinearSlider (juce::Graphics&, int x, int y, int w, int h,
                           float pos, float minPos, float maxPos,
                           juce::Slider::SliderStyle, juce::Slider&) override;
    void drawComboBox (juce::Graphics&, int w, int h, bool down,
                       int bx, int by, int bw, int bh, juce::ComboBox&) override;
    void positionComboBoxText (juce::ComboBox&, juce::Label&) override;
    void drawToggleButton (juce::Graphics&, juce::ToggleButton&, bool, bool) override;
    void drawPopupMenuBackground (juce::Graphics&, int w, int h) override;
};

class ResonanceAudioProcessorEditor : public juce::AudioProcessorEditor,
                                      private juce::Timer
{
public:
    explicit ResonanceAudioProcessorEditor (ResonanceAudioProcessor&);
    ~ResonanceAudioProcessorEditor() override;

    void paint (juce::Graphics&) override;
    void resized() override;

private:
    void timerCallback() override;
    void styleKnob (juce::Slider&);
    void addLabel (juce::Label&, const juce::String&);
    void bindBand (int band);
    void applyInstrument (int presetIndex);

    using SA = juce::AudioProcessorValueTreeState::SliderAttachment;
    using BA = juce::AudioProcessorValueTreeState::ButtonAttachment;
    using CA = juce::AudioProcessorValueTreeState::ComboBoxAttachment;

    ResonanceAudioProcessor& proc;
    SoftLNF lnf;
    EQComponent eqComp;

    // instrument presets bar
    juce::ComboBox instrumentBox;
    juce::Label instrumentL;

    // selected node controls (precision row)
    juce::Label bandTitle;
    juce::ToggleButton bandOn { "Active" };
    juce::ComboBox bandTypeBox;
    juce::Slider bandFreq, bandQ, bandGain;
    juce::Label freqL, qL, gainL;

    // logic row
    juce::ComboBox masterLogicBox, mixLogicBox;
    juce::Slider amount, trim, ceiling, mix, outGain;
    juce::Label amountL, trimL, ceilL, mixL, outL;

    juce::Label readout;

    juce::Rectangle<int> panelGraph, panelPresets, panelNode, panelLogic;

    std::unique_ptr<BA> bandOnAtt;
    std::unique_ptr<CA> bandTypeAtt, masterLogicAtt, mixLogicAtt;
    std::unique_ptr<SA> bandFreqAtt, bandQAtt, bandGainAtt,
                        amountAtt, trimAtt, ceilAtt, mixAtt, outAtt;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ResonanceAudioProcessorEditor)
};
